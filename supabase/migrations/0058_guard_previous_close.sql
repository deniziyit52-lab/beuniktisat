-- Acilis fiyati (previous_close) korumasi ve teshis.
--
-- Sorun: her gece 24:00'te hisselerin acilis fiyati, eski ve artik kullanilmayan "price"
-- sutunundaki degerlerle eziliyor. Fiyatlar dogru kaliyor ama yuzdeler ve tavan/taban etiketleri
-- sabah acilisa kadar yanlis gorunuyor. Bunu yapan sey depodaki dosyalarda yok; veritabaninda
-- eskiden kalma bir kural ya da zamanlanmis gorev olmali.
--
-- Bu dosya:
--   1) Acilis fiyatini yalnizca mesru yoldan degistirilebilir yapar (yeni gun = guncel fiyat).
--      Baska her yazma geri alinir ve kimin yaptigi kaydedilir.
--   2) Su anki bozuk degerleri onarir.
--   3) Kapanisi, sonunda tamamen geri alinan bir denemede calistirip bozan seyi arar.
--   4) Bulgularin yalnizca ad ve sayi iceren ozetini 17 Ekim 2026'ya kadar okunabilir yapar.
--      (Ozet: kural, fonksiyon ve gorev adlari. Govde, komut ya da anahtar icermez.)

CREATE TABLE IF NOT EXISTS public.previous_close_audit (
    id              BIGSERIAL PRIMARY KEY,
    happened_at     TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    symbol          TEXT,
    old_value       NUMERIC,
    attempted_value NUMERIC,
    current_price   NUMERIC,
    call_stack      TEXT,
    top_query       TEXT,
    app_name        TEXT,
    cron_job        TEXT
);

CREATE TABLE IF NOT EXISTS public.engine_diagnostics (
    id         BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    topic      TEXT NOT NULL,
    summary    JSONB,
    detail     TEXT
);

ALTER TABLE public.previous_close_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engine_diagnostics ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.previous_close_audit, public.engine_diagnostics FROM anon, authenticated;

-- Cagri zincirinden yalnizca fonksiyon satirlarini birakir (SQL metinleri atilir).
CREATE OR REPLACE FUNCTION public.borsa_stack_functions(p_stack TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT string_agg(btrim(l.line), ' <- ' ORDER BY l.ord)
    FROM regexp_split_to_table(coalesce(p_stack, ''), E'\n') WITH ORDINALITY AS l(line, ord)
    WHERE btrim(l.line) ~ '^(PL/pgSQL|SQL) function ';
$$;

REVOKE ALL ON FUNCTION public.borsa_stack_functions(TEXT) FROM PUBLIC, anon, authenticated;

-- Koruma: acilis fiyati yalnizca guncel fiyata esitlenerek degisebilir (yeni seans / oyunu sifirlama).
-- Islem ici "borsa.prev_close_mode" ayari:
--   'repair' -> acilis fiyati, dogru duran gunluk farktan (change) yeniden kurulur
--   'allow'  -> bakim icin her degisiklige izin verilir
CREATE OR REPLACE FUNCTION public.guard_previous_close()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _mode   TEXT := coalesce(current_setting('borsa.prev_close_mode', true), '');
    _stack  TEXT;
    _query  TEXT;
    _job    TEXT;
    _recent INTEGER;
    _total  INTEGER;
BEGIN
    IF _mode = 'repair' THEN
        IF NEW.current_price - NEW.change > 0 THEN
            NEW.previous_close := ROUND((NEW.current_price - NEW.change)::NUMERIC, 4);
        END IF;
        RETURN NEW;
    END IF;

    IF NEW.previous_close IS NOT DISTINCT FROM OLD.previous_close
       OR _mode = 'allow'
       OR NEW.previous_close = NEW.current_price THEN
        RETURN NEW;
    END IF;

    -- Izinsiz degisiklik: kimin yaptigi kaydedilir (gunde en cok 120, toplam 3000 kayit).
    -- Kayit basarisiz olsa bile fiyat akisi durmaz.
    BEGIN
        SELECT count(*) FILTER (WHERE happened_at > now() - INTERVAL '1 day'), count(*)
        INTO _recent, _total
        FROM public.previous_close_audit;

        IF _recent < 120 AND _total < 3000 THEN
            GET DIAGNOSTICS _stack = PG_CONTEXT;
            _query := left(current_query(), 500);
            BEGIN
                SELECT coalesce(j.jobname::TEXT, 'adsiz#' || j.jobid) INTO _job
                FROM cron.job AS j
                WHERE btrim(j.command, E' \n\r\t;') = btrim(current_query(), E' \n\r\t;')
                LIMIT 1;
            EXCEPTION WHEN OTHERS THEN
                _job := NULL;
            END;

            INSERT INTO public.previous_close_audit
                (symbol, old_value, attempted_value, current_price, call_stack, top_query, app_name, cron_job)
            VALUES
                (OLD.symbol, OLD.previous_close, NEW.previous_close, NEW.current_price,
                 left(_stack, 4000), _query, left(current_setting('application_name', true), 80), _job);
        END IF;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    -- Gunluk fark sifirsa yeni seans baslamistir, acilis fiyati guncel fiyattir; degilse eski deger korunur.
    NEW.previous_close := CASE WHEN NEW.change = 0 THEN NEW.current_price ELSE OLD.previous_close END;
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_previous_close() FROM PUBLIC, anon, authenticated;

-- Ayni olaydaki kurallar ada gore sirayla calisir; "zzzz" ile baslayan ad en sona kalir,
-- boylece baska bir kuralin yaptigi degisikligi de yakalar.
CREATE OR REPLACE TRIGGER zzzz_stocks_guard_previous_close
    BEFORE UPDATE ON public.stocks
    FOR EACH ROW
    EXECUTE FUNCTION public.guard_previous_close();

-- Onarim: acilis fiyati, bozulmadan kalan gunluk farktan geri kurulur.
DO $$
BEGIN
    PERFORM set_config('borsa.prev_close_mode', 'repair', true);
    UPDATE public.stocks SET updated_at = now() WHERE symbol IS NOT NULL;
    PERFORM set_config('borsa.prev_close_mode', '', true);
END
$$;

-- Teshis. Buradaki hicbir hata, yukaridaki koruma ve onarimi geri almaz.
DO $$
DECLARE
    _was_open    BOOLEAN;
    _max_id      BIGINT := 0;
    _before      JSONB;
    _rows        JSONB := '[]'::jsonb;
    _attempts    INTEGER := 0;
    _changed     INTEGER := 0;
    _sim_error   TEXT;
    _stack       TEXT;
    _stmt        TEXT;
    _chain       TEXT;
    _late        INTEGER := 0;
    _triggers    TEXT;
    _unknown_trg TEXT;
    _trig_det    TEXT;
    _jobs        TEXT;
    _jobs_det    TEXT;
    _writers     TEXT;
    _detail      TEXT;
BEGIN
    -- A) Kapanis denemesi: sonunda tamamen geri alinan bir alt islemde yapilir.
    BEGIN
        SELECT is_market_open INTO _was_open FROM public.market_settings WHERE id = 1;
        SELECT coalesce(max(id), 0) INTO _max_id FROM public.previous_close_audit;

        IF NOT coalesce(_was_open, false) THEN
            PERFORM public.apply_market_open(true);
        END IF;

        SELECT jsonb_object_agg(symbol, previous_close) INTO _before FROM public.stocks;

        PERFORM public.apply_market_open(false);

        SELECT coalesce(jsonb_agg(to_jsonb(a) ORDER BY a.id), '[]'::jsonb)
        INTO _rows
        FROM public.previous_close_audit AS a
        WHERE a.id > _max_id;

        SELECT count(*) INTO _changed
        FROM public.stocks AS s
        WHERE s.previous_close IS DISTINCT FROM (_before ->> s.symbol)::NUMERIC;

        -- Denemenin yaptigi her sey (piyasa durumu, hisseler, kayitlar) geri alinir.
        RAISE EXCEPTION 'BORSA_SIM_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'BORSA_SIM_ROLLBACK' THEN
            _sim_error := left(regexp_replace(SQLERRM, '[A-Za-z0-9_.+/=-]{40,}', '[gizlendi]', 'g'), 300);
        END IF;
    END;

    BEGIN
        _attempts := jsonb_array_length(_rows);
        IF _attempts > 0 THEN
            _stack := _rows -> 0 ->> 'call_stack';
            _stmt  := coalesce(substring(_stack from 'SQL statement "([^"]*)"'), _rows -> 0 ->> 'top_query');
            _chain := public.borsa_stack_functions(_stack);
        END IF;

        -- B) Kurallar (tetikleyiciler). Depoda kaydi olmayanlar isaretlenir; fonksiyon govdesi yerine
        --    yalnizca icinde gecen bilinen sozcukler yazilir.
        BEGIN
            SELECT string_agg(x.short_txt, '; ' ORDER BY x.relname, x.tgname),
                   string_agg(x.short_txt, '; ' ORDER BY x.relname, x.tgname) FILTER (WHERE x.is_unknown),
                   string_agg(x.long_txt, E'\n' ORDER BY x.relname, x.tgname)
            INTO _triggers, _unknown_trg, _trig_det
            FROM (
                SELECT c.relname::TEXT AS relname,
                       t.tgname::TEXT AS tgname,
                       (k.tgname IS NULL) AS is_unknown,
                       format('%s%s.%s [%s] -> %s.%s%s%s',
                              CASE WHEN n.nspname = 'public' THEN '' ELSE n.nspname || '.' END,
                              c.relname,
                              t.tgname,
                              CASE WHEN (t.tgtype & 64) <> 0 THEN 'INSTEAD'
                                   WHEN (t.tgtype & 2) <> 0 THEN 'BEFORE'
                                   ELSE 'AFTER' END
                                || CASE WHEN (t.tgtype & 4) <> 0 THEN ' INS' ELSE '' END
                                || CASE WHEN (t.tgtype & 16) <> 0 THEN ' UPD' ELSE '' END
                                || CASE WHEN (t.tgtype & 8) <> 0 THEN ' DEL' ELSE '' END
                                || CASE WHEN (t.tgtype & 1) <> 0 THEN ' satir' ELSE ' ifade' END,
                              pn.nspname,
                              p.proname,
                              CASE WHEN t.tgenabled = 'D' THEN ' (kapali)' ELSE '' END,
                              CASE WHEN k.tgname IS NULL
                                   THEN ' [BILINMEYEN ' || coalesce(w.words, '{}') || ']'
                                   ELSE '' END) AS short_txt,
                       pg_get_triggerdef(t.oid)
                       || CASE WHEN k.tgname IS NULL
                               THEN E'\n   >>> fonksiyon govdesi: ' || left(p.prosrc, 1500)
                               ELSE '' END AS long_txt
                FROM pg_trigger AS t
                JOIN pg_class AS c ON c.oid = t.tgrelid
                JOIN pg_namespace AS n ON n.oid = c.relnamespace
                JOIN pg_proc AS p ON p.oid = t.tgfoid
                JOIN pg_namespace AS pn ON pn.oid = p.pronamespace
                LEFT JOIN (VALUES
                    ('stocks', 'trg_stocks_set_updated_at'),
                    ('stocks', 'trg_stocks_refresh_snapshot'),
                    ('stocks', 'trg_stocks_circuit_breaker'),
                    ('stocks', 'zzzz_stocks_guard_previous_close'),
                    ('app_settings', 'trg_app_settings_set_updated_at'),
                    ('price_history', 'trg_price_history_clamp'),
                    ('news_feed', 'news_feed_keep_latest')
                ) AS k(relname, tgname)
                  ON n.nspname = 'public' AND k.relname = c.relname::TEXT AND k.tgname = t.tgname::TEXT
                LEFT JOIN LATERAL (
                    SELECT '{' || string_agg(v.word, ',' ORDER BY v.ord) || '}' AS words
                    FROM unnest(ARRAY['previous_close', 'price', 'current_price', 'change', 'stocks',
                                      'market_settings', 'users', 'balance', 'portfolio',
                                      'insert', 'update', 'delete', 'http_post']) WITH ORDINALITY AS v(word, ord)
                    WHERE p.prosrc ~* ('\m' || v.word || '\M')
                ) AS w ON true
                WHERE NOT t.tgisinternal
                  AND (n.nspname = 'public' OR pn.nspname = 'public')
            ) AS x;
        EXCEPTION WHEN OTHERS THEN
            _triggers := 'okunamadi: ' || left(SQLERRM, 200);
        END;

        -- C) Zamanlanmis gorevler: ad ve saat; komutun kendisi ozete girmez.
        BEGIN
            SELECT string_agg(y.short_txt, '; ' ORDER BY y.jobid),
                   string_agg(y.long_txt, E'\n' ORDER BY y.jobid)
            INTO _jobs, _jobs_det
            FROM (
                SELECT j.jobid,
                       coalesce(j.jobname::TEXT, 'adsiz#' || j.jobid) || ' [' || j.schedule || ']'
                       || CASE WHEN j.active THEN '' ELSE ' (kapali)' END
                       || CASE WHEN e.pattern IS NULL THEN ' [BILINMEYEN]'
                               WHEN j.command !~* e.pattern THEN ' [KOMUT FARKLI]'
                               ELSE '' END
                       || CASE WHEN j.command ~* 'previous_close' THEN ' {previous_close}' ELSE '' END
                       || CASE WHEN j.command ~* '\mstocks\M' THEN ' {stocks}' ELSE '' END AS short_txt,
                       coalesce(j.jobname::TEXT, 'adsiz#' || j.jobid) || ' [' || j.schedule || ']: ' || j.command AS long_txt
                FROM cron.job AS j
                LEFT JOIN (VALUES
                    ('borsa-every-60s-price-tick', 'batch_tick_market_prices'),
                    ('borsa-every-10m-retention', 'purge_price_history_retention'),
                    ('borsa-fetch-economy-news', 'fetch-economy-news'),
                    ('borsa-refresh-asset-prices', 'refresh_asset_prices'),
                    ('borsa-market-open', 'apply_market_open\s*\(\s*true'),
                    ('borsa-market-close', 'apply_market_open\s*\(\s*false'),
                    ('borsa-hourly-prices', 'record_hourly_prices'),
                    ('borsa-resolve-columns', 'resolve_guest_columns'),
                    ('borsa-maintenance-auto-off', 'maintenance_auto_off')
                ) AS e(jobname, pattern) ON e.jobname = j.jobname::TEXT
            ) AS y;
        EXCEPTION WHEN OTHERS THEN
            _jobs := 'okunamadi: ' || left(SQLERRM, 200);
        END;

        -- D) Acilis fiyatina eski "price" sutununu yazan fonksiyonlar
        BEGIN
            SELECT string_agg(n.nspname || '.' || p.proname, ', ' ORDER BY n.nspname, p.proname)
            INTO _writers
            FROM pg_proc AS p
            JOIN pg_namespace AS n ON n.oid = p.pronamespace
            WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
              AND p.prosrc ~* 'previous_close\s*:?=[^;]{0,60}\mprice\M';
        EXCEPTION WHEN OTHERS THEN
            _writers := 'okunamadi: ' || left(SQLERRM, 200);
        END;

        -- E) Koruma gercekten en son mu calisiyor?
        SELECT count(*) INTO _late
        FROM pg_trigger AS t
        WHERE t.tgrelid = 'public.stocks'::regclass
          AND NOT t.tgisinternal
          AND (t.tgtype & 2) <> 0
          AND (t.tgtype & 16) <> 0
          AND (t.tgtype & 1) <> 0
          AND t.tgname::TEXT COLLATE "C" > 'zzzz_stocks_guard_previous_close';

        _detail := concat_ws(E'\n\n',
            'ILK KAYDIN CAGRI ZINCIRI:' || E'\n' || coalesce(_stack, '-'),
            'BOZAN IFADE:' || E'\n' || coalesce(_stmt, '-'),
            'KURALLAR (TAM):' || E'\n' || coalesce(_trig_det, '-'),
            'ZAMANLANMIS GOREVLER (TAM):' || E'\n' || coalesce(_jobs_det, '-')
        );
        -- Anahtar olabilecek dizgiler rapora yazilmadan gizlenir.
        _detail := regexp_replace(_detail, '[A-Za-z0-9_.+/=-]{40,}', '[gizlendi]', 'g');
        _detail := regexp_replace(
            _detail,
            '(bearer\s+|(secret|apikey|api_key|authorization|token|password)[^a-z0-9]{1,6})[A-Za-z0-9_.+/=-]{8,}',
            '\1[gizlendi]', 'gi');

        INSERT INTO public.engine_diagnostics (topic, summary, detail)
        VALUES (
            'previous_close',
            jsonb_build_object(
                'deneme', CASE
                    WHEN _sim_error IS NOT NULL THEN 'hata: ' || _sim_error
                    WHEN _attempts = 0 THEN 'kapanis yolunda izinsiz yazma yok'
                    ELSE _attempts || ' izinsiz yazma yakalandi'
                END,
                'deneme_aninda_piyasa', CASE WHEN coalesce(_was_open, false) THEN 'acik' ELSE 'kapali' END,
                'koruma', CASE
                    WHEN _sim_error IS NOT NULL THEN 'dogrulanamadi'
                    WHEN _changed = 0 THEN 'calisiyor'
                    ELSE 'CALISMIYOR (' || _changed || ' hisse degisti)'
                END,
                'koruma_sirasi', CASE WHEN _late = 0 THEN 'en sonda'
                                      ELSE _late || ' kural korumadan sonra calisiyor' END,
                'zincir', _chain,
                'ifade_basi', left(regexp_replace(
                                  regexp_replace(_stmt, '\s+', ' ', 'g'),
                                  '[A-Za-z0-9_.+/=-]{40,}', '[gizlendi]', 'g'), 90),
                'ifade_acilisi_eski_sutundan_yaziyor', _stmt ~* 'previous_close\s*:?=[^;]{0,60}\mprice\M',
                'eski_sutunu_yazan_fonksiyonlar', _writers,
                'bilinmeyen_kurallar', _unknown_trg,
                'kurallar', _triggers,
                'gorevler', _jobs
            ),
            _detail
        );
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO public.engine_diagnostics (topic, summary)
        VALUES ('previous_close', jsonb_build_object('teshis_hatasi', left(SQLERRM, 300)));
    END;
END
$$;

-- Gecici teshis kapisi: yalnizca ozeti ve korumanin engelledigi yazmalarin
-- (saat, adet, fonksiyon adlari) dokumunu verir. 17 Ekim 2026'dan sonra hicbir sey dondurmez.
CREATE OR REPLACE FUNCTION public.get_engine_diagnosis()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF now() >= TIMESTAMPTZ '2026-10-17 00:00:00+03' THEN
        RETURN NULL;
    END IF;

    RETURN jsonb_build_object(
        'now', now(),
        'reports', (
            SELECT coalesce(
                jsonb_agg(jsonb_build_object('at', d.created_at, 'summary', d.summary) ORDER BY d.id DESC),
                '[]'::jsonb)
            FROM (SELECT * FROM public.engine_diagnostics ORDER BY id DESC LIMIT 3) AS d
        ),
        'blocked', (
            SELECT coalesce(jsonb_agg(to_jsonb(b) ORDER BY b.zaman DESC, b.adet DESC), '[]'::jsonb)
            FROM (
                SELECT date_trunc('second', q.happened_at) AS zaman,
                       count(*) AS adet,
                       q.gorev,
                       q.uygulama,
                       q.zincir,
                       q.ifade_basi,
                       q.ifade_acilisi_eski_sutundan_yaziyor
                FROM (
                    SELECT a.happened_at,
                           a.cron_job AS gorev,
                           a.app_name AS uygulama,
                           public.borsa_stack_functions(a.call_stack) AS zincir,
                           left(regexp_replace(
                                    regexp_replace(s.stmt, '\s+', ' ', 'g'),
                                    '[A-Za-z0-9_.+/=-]{40,}', '[gizlendi]', 'g'), 90) AS ifade_basi,
                           s.stmt ~* 'previous_close\s*:?=[^;]{0,60}\mprice\M' AS ifade_acilisi_eski_sutundan_yaziyor
                    FROM public.previous_close_audit AS a
                    CROSS JOIN LATERAL (
                        SELECT coalesce(substring(a.call_stack from 'SQL statement "([^"]*)"'), a.top_query) AS stmt
                    ) AS s
                ) AS q
                GROUP BY date_trunc('second', q.happened_at), q.gorev, q.uygulama, q.zincir,
                         q.ifade_basi, q.ifade_acilisi_eski_sutundan_yaziyor
                ORDER BY date_trunc('second', q.happened_at) DESC
                LIMIT 12
            ) AS b
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_engine_diagnosis() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_engine_diagnosis() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Sonuc
SELECT r.konu, r.sonuc
FROM (
    SELECT 1 AS sira,
           'Acilis fiyatlari' AS konu,
           (SELECT count(*) FILTER (WHERE abs(previous_close - (current_price - change)) <= 0.01)::TEXT
                   || ' / ' || count(*)::TEXT || ' hissede dogru'
            FROM public.stocks) AS sonuc
    UNION ALL
    SELECT 2, 'Koruma',
           (SELECT d.summary ->> 'koruma' FROM public.engine_diagnostics AS d ORDER BY d.id DESC LIMIT 1)
    UNION ALL
    SELECT 3, 'Kapanis denemesi',
           (SELECT coalesce(d.summary ->> 'deneme', d.summary ->> 'teshis_hatasi')
            FROM public.engine_diagnostics AS d ORDER BY d.id DESC LIMIT 1)
    UNION ALL
    SELECT 4, 'Depoda olmayan kurallar',
           (SELECT coalesce(d.summary ->> 'bilinmeyen_kurallar', 'yok')
            FROM public.engine_diagnostics AS d ORDER BY d.id DESC LIMIT 1)
) AS r
ORDER BY r.sira;
