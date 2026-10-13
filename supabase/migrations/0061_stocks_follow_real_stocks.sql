-- Her hisse, ayni sektorden gercek bir borsa hissesinin fiyat hareketini izler; oyuncu icin "Sirket Karnesi".
--
-- Neden: fiyatlar tamamen rastgele oldugu icin oyun sansa kaliyordu, analiz edilemiyordu.
-- Artik gercek borsa acikken (hafta ici 10:00-18:00) her hissenin yonu, bagli oldugu gercek hisseden gelir.
-- Rastgele kisim kisilir, ani soklar kapanir. Aksam ve hafta sonu fiyatlar kucuk oynar.
-- Oyuncu etkisi, haber etkisi, devre kesici ve tavan/taban aynen kalir. Hisse adlari degismez.
--
-- GIZLILIK: hangi hissenin hangi gercek hisseye bagli oldugu bu dosyada YOK; depoya girmeyen
-- supabase/gizli/0061b_eslesmeler.sql dosyasindadir ve bu dosyadan SONRA calistirilir.
-- Oyuncuya yalnizca sektor, aciklama, neye duyarli oldugu ve yuvarlanmis getiriler gider.

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS stock_link_enabled BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS quiet_vol_scale NUMERIC NOT NULL DEFAULT 0.15
        CHECK (quiet_vol_scale >= 0 AND quiet_vol_scale <= 1);

CREATE TABLE IF NOT EXISTS public.stock_links (
    symbol         VARCHAR(16) PRIMARY KEY REFERENCES public.stocks(symbol) ON UPDATE CASCADE ON DELETE CASCADE,
    yahoo_symbol   TEXT NOT NULL,
    sector         TEXT NOT NULL,
    summary        TEXT NOT NULL,
    sensitivities  JSONB NOT NULL DEFAULT '[]'::jsonb,
    last_price     NUMERIC,
    last_bar_at    TIMESTAMPTZ,
    pending_return DOUBLE PRECISION NOT NULL DEFAULT 0,
    ticks_left     INTEGER NOT NULL DEFAULT 0,
    fetched_at     TIMESTAMPTZ,
    stats          JSONB,
    stats_at       TIMESTAMPTZ
);
ALTER TABLE public.stock_links ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stock_links FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.stock_link_status (
    id         INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    checked_at TIMESTAMPTZ,
    ok         BOOLEAN,
    message    TEXT
);
INSERT INTO public.stock_link_status (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.stock_link_status ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stock_link_status FROM anon, authenticated;

-- Yahoo'dan birden cok hisseyi tek istekte okur.
CREATE OR REPLACE FUNCTION public.fetch_yahoo_spark(p_symbols TEXT[], p_range TEXT, p_interval TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _status INTEGER;
    _body TEXT;
BEGIN
    BEGIN
        PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    SELECT r.status, r.content
    INTO _status, _body
    FROM extensions.http((
        'GET',
        'https://query1.finance.yahoo.com/v8/finance/spark?symbols=' || array_to_string(p_symbols, ',')
            || '&range=' || p_range || '&interval=' || p_interval,
        ARRAY[extensions.http_header('User-Agent', 'Mozilla/5.0')],
        NULL,
        NULL
    )::extensions.http_request) AS r;

    IF _status IS DISTINCT FROM 200 THEN
        RAISE EXCEPTION 'Yahoo HTTP durumu: %', _status;
    END IF;
    RETURN _body::JSONB;
END;
$$;

REVOKE ALL ON FUNCTION public.fetch_yahoo_spark(TEXT[], TEXT, TEXT) FROM PUBLIC, anon, authenticated;

-- Bagli gercek hisselerin son fiyatlarini okur; yeni veri gelen her hisse icin aradaki degisimi motora birakir.
CREATE OR REPLACE FUNCTION public.refresh_stock_links()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _j JSONB;
    _link RECORD;
    _x JSONB;
    _last NUMERIC;
    _bar_at TIMESTAMPTZ;
    _r DOUBLE PRECISION;
    _updated INTEGER := 0;
    _skipped TEXT[] := '{}';
BEGIN
    BEGIN
        SELECT public.fetch_yahoo_spark(array_agg(DISTINCT yahoo_symbol), '1d', '5m') INTO _j FROM public.stock_links;
        IF _j IS NULL OR jsonb_typeof(_j) <> 'object' THEN
            RAISE EXCEPTION 'Yahoo cevabi bos.';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        UPDATE public.stock_link_status SET checked_at = now(), ok = false, message = left(SQLERRM, 300) WHERE id = 1;
        RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;

    FOR _link IN SELECT * FROM public.stock_links ORDER BY symbol FOR UPDATE LOOP
        BEGIN
            _x := _j -> _link.yahoo_symbol;
            _last := NULL;
            _bar_at := NULL;

            -- Fiyati dolu olan son veri noktasi ve zamani
            SELECT (c.val #>> '{}')::NUMERIC, to_timestamp((t.val #>> '{}')::DOUBLE PRECISION)
            INTO _last, _bar_at
            FROM jsonb_array_elements(_x -> 'close') WITH ORDINALITY AS c(val, ord)
            JOIN jsonb_array_elements(_x -> 'timestamp') WITH ORDINALITY AS t(val, ord) ON t.ord = c.ord
            WHERE jsonb_typeof(c.val) = 'number'
            ORDER BY c.ord DESC
            LIMIT 1;

            IF coalesce(_last, 0) <= 0 OR _bar_at IS NULL THEN
                RAISE EXCEPTION 'deger yok';
            END IF;
            IF _link.last_bar_at IS NOT NULL AND _bar_at <= _link.last_bar_at THEN
                CONTINUE;
            END IF;

            _r := 0;
            IF coalesce(_link.last_price, 0) > 0 THEN
                -- Bozuk veriye (ya da hisse bolunmesine) karsi: %25'ten buyuk sicrama hareket sayilmaz.
                IF abs(_last / _link.last_price - 1) <= 0.25 THEN
                    -- Gercek borsanin gunluk siniri %10'dur; acilis farki da en fazla bu kadar yansir.
                    _r := GREATEST(-0.10, LEAST(0.10, ln((_last / _link.last_price)::DOUBLE PRECISION)));
                END IF;
            END IF;

            UPDATE public.stock_links
            SET last_price = _last,
                last_bar_at = _bar_at,
                -- Eskiden kalmis, dagitilmamis hareket yeni veriyle birlikte tasinmaz.
                pending_return = CASE WHEN fetched_at > now() - INTERVAL '20 minutes' THEN pending_return ELSE 0 END + _r,
                ticks_left = 5,
                fetched_at = now()
            WHERE symbol = _link.symbol;
            _updated := _updated + 1;
        EXCEPTION WHEN OTHERS THEN
            _skipped := array_append(_skipped, _link.symbol::TEXT);
        END;
    END LOOP;

    UPDATE public.stock_link_status
    SET checked_at = now(), ok = true,
        message = _updated || ' hisse guncellendi'
                  || CASE WHEN cardinality(_skipped) > 0 THEN '; okunamayan: ' || array_to_string(_skipped, ', ') ELSE '' END
    WHERE id = 1;

    RETURN jsonb_build_object('ok', true, 'updated', _updated, 'skipped', to_jsonb(_skipped));
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_stock_links() FROM PUBLIC, anon, authenticated;

-- Karne icin gunluk kapanislardan ozet cikarir: 1 hafta / 1 ay / 3 ay getirisi, son bir yilin
-- en dusugu ile en yuksegi arasindaki yeri ve oynaklik. Getiriler tam sayiya yuvarlanir.
CREATE OR REPLACE FUNCTION public.refresh_stock_stats()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _j JSONB;
    _link RECORD;
    _c NUMERIC[];
    _n INTEGER;
    _sigma NUMERIC;
    _lo NUMERIC;
    _hi NUMERIC;
    _updated INTEGER := 0;
BEGIN
    BEGIN
        SELECT public.fetch_yahoo_spark(array_agg(DISTINCT yahoo_symbol), '1y', '1d') INTO _j FROM public.stock_links;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;

    FOR _link IN SELECT symbol, yahoo_symbol FROM public.stock_links ORDER BY symbol LOOP
        BEGIN
            SELECT array_agg((c.val #>> '{}')::NUMERIC ORDER BY c.ord)
            INTO _c
            FROM jsonb_array_elements(_j -> _link.yahoo_symbol -> 'close') WITH ORDINALITY AS c(val, ord)
            WHERE jsonb_typeof(c.val) = 'number' AND (c.val #>> '{}')::NUMERIC > 0;

            _n := coalesce(array_length(_c, 1), 0);
            IF _n < 70 THEN
                CONTINUE;
            END IF;

            SELECT stddev_pop(ln((_c[i] / _c[i - 1])::DOUBLE PRECISION))::NUMERIC
            INTO _sigma
            FROM generate_series(2, _n) AS i;
            SELECT min(v), max(v) INTO _lo, _hi FROM unnest(_c) AS v;

            UPDATE public.stock_links
            SET stats = jsonb_build_object(
                    'w1', ROUND((_c[_n] / _c[_n - 5] - 1) * 100),
                    'm1', ROUND((_c[_n] / _c[_n - 21] - 1) * 100),
                    'm3', ROUND((_c[_n] / _c[_n - 63] - 1) * 100),
                    'pos52', CASE WHEN _hi > _lo THEN ROUND((_c[_n] - _lo) / (_hi - _lo) * 100) END,
                    'vol', CASE WHEN _sigma < 0.025 THEN 'low' WHEN _sigma < 0.035 THEN 'mid' ELSE 'high' END
                ),
                stats_at = now()
            WHERE symbol = _link.symbol;
            _updated := _updated + 1;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'updated', _updated);
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_stock_stats() FROM PUBLIC, anon, authenticated;

-- Fiyat motoru: 0060'taki govde; hisse basina gercek hareket ve kisilmis rastgele kisim eklendi.
CREATE OR REPLACE FUNCTION public.batch_tick_market_prices()
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _market public.market_settings%ROWTYPE;
    _cfg public.engine_settings%ROWTYPE;
    _n DOUBLE PRECISION;
    _sigma_m DOUBLE PRECISION;
    _sigma_m_min DOUBLE PRECISION;
    _m DOUBLE PRECISION;
    _rate DOUBLE PRECISION;
    _updated_count INTEGER := 0;
    _index NUMERIC;
    _level RECORD;
    _idx public.market_index%ROWTYPE;
    _link_on BOOLEAN;
    _quiet DOUBLE PRECISION;
BEGIN
    SELECT *
    INTO _market
    FROM public.market_settings
    WHERE id = 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'market_settings row id=1 is missing.';
    END IF;

    IF NOT _market.is_market_open
       OR (_market.halt_until IS NOT NULL AND _market.halt_until > now()) THEN
        RETURN QUERY SELECT * FROM public.stocks ORDER BY symbol;
        RETURN;
    END IF;

    SELECT * INTO _cfg FROM public.engine_settings WHERE id = 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'engine_settings row id=1 is missing.';
    END IF;

    _n := _cfg.minutes_per_day;
    _sigma_m := _cfg.market_daily_sigma;
    _sigma_m_min := _sigma_m / sqrt(_n);
    _rate := coalesce(_cfg.impact_revert_rate, 0.20);
    -- Hisseler gercek hisselere bagliyken rastgele kisim kisilir ve ani soklar kapatilir;
    -- fiyati asil oynatan, bagli gercek hissenin hareketi olur.
    _link_on := coalesce(_cfg.stock_link_enabled, false);
    _quiet := CASE WHEN _link_on THEN coalesce(_cfg.quiet_vol_scale, 0.15)::DOUBLE PRECISION ELSE 1 END;
    -- Piyasa faktoru: bu dakika butun hisseler icin ortak tek cekilis.
    _m := _sigma_m_min * sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random());

    -- Gercek borsa acikken ortak yon rastgele cekilis yerine BIST 100'un son hareketinden gelir:
    -- son okunan degisim, sonraki dakikalara esit paylarla dagitilir. Veri yoksa ya da eskiyse
    -- (aksam, hafta sonu, tatil, baglanti sorunu) yukaridaki rastgele cekilis gecerli kalir.
    IF coalesce(_cfg.real_market_enabled, false) THEN
        SELECT * INTO _idx FROM public.market_index WHERE id = 1 FOR UPDATE;
        IF FOUND AND _idx.ticks_left > 0 AND _idx.fetched_at > now() - INTERVAL '20 minutes' THEN
            _m := _idx.pending_return / _idx.ticks_left * coalesce(_cfg.real_market_scale, 1);
            UPDATE public.market_index
            SET pending_return = pending_return - pending_return / ticks_left,
                ticks_left = ticks_left - 1
            WHERE id = 1;
        END IF;
    END IF;

    WITH draws AS MATERIALIZED (
        SELECT
            s.symbol,
            s.current_price::DOUBLE PRECISION AS price,
            s.vol_mult::DOUBLE PRECISION AS vol_mult,
            s.impact_pending::DOUBLE PRECISION AS impact_pending,
            t.beta::DOUBLE PRECISION AS beta,
            t.drift_daily::DOUBLE PRECISION AS drift_daily,
            -- Hissenin kendi oynakligi: toplam gunluk sigma hedefinden piyasa payi dusulur.
            sqrt(GREATEST(
                t.daily_sigma::DOUBLE PRECISION ^ 2 - (t.beta::DOUBLE PRECISION * _sigma_m) ^ 2,
                0
            )) / sqrt(_n) AS vol_min,
            sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random()) AS gauss,
            (NOT _link_on AND random() < t.shock_per_day::DOUBLE PRECISION / _n) AS shocked,
            (CASE WHEN random() < 0.5 THEN -1 ELSE 1 END)
                * (t.shock_min::DOUBLE PRECISION
                   + random() * (t.shock_max - t.shock_min)::DOUBLE PRECISION) AS shock,
            -- Bagli gercek hisseden taze veri varsa bu dakikaya dusen payi.
            coalesce(_link_on AND l.ticks_left > 0 AND l.fetched_at > now() - INTERVAL '20 minutes', false) AS linked,
            CASE WHEN l.ticks_left > 0 THEN l.pending_return / l.ticks_left ELSE 0 END AS real_piece
        FROM public.stocks AS s
        JOIN public.stock_types AS t ON t.risk_type = s.risk_type
        LEFT JOIN public.stock_links AS l ON l.symbol = s.symbol
        WHERE s.halt_until IS NULL OR s.halt_until <= now()
    ),
    moves AS MATERIALIZED (
        SELECT
            symbol,
            shocked,
            impact_pending,
            GREATEST(
                _cfg.price_floor,
                ROUND((price * exp(
                    drift_daily / _n
                    + vol_min * vol_mult * _quiet * gauss
                    -- Gercek veri varken yon bagli hisseden gelir (piyasanin genel yonu onun icindedir);
                    -- yokken (aksam, hafta sonu) kisilmis ortak yon kullanilir.
                    + CASE WHEN linked THEN real_piece ELSE beta * _m * _quiet END
                    - 0.5 * ((vol_min * vol_mult * _quiet) ^ 2
                             + CASE WHEN linked THEN 0 ELSE (beta * _sigma_m_min * _quiet) ^ 2 END)
                    + CASE WHEN shocked THEN shock ELSE 0 END
                    -- Islem etkisinin geri donecek kisminin bu dakikaki payi.
                    - impact_pending * _rate
                ))::NUMERIC, 4)
            ) AS new_price
        FROM draws
    ),
    updated AS (
        UPDATE public.stocks AS s
        SET current_price = n.new_price,
            change = ROUND(n.new_price - s.previous_close, 4),
            change_pct = ROUND(
                CASE WHEN s.previous_close = 0 THEN 0
                     ELSE ((n.new_price - s.previous_close) / s.previous_close) * 100
                END,
                4
            ),
            -- Sok sonrasi oynaklik yukselir, sonra her dakika 1'e dogru geri doner.
            vol_mult = CASE
                WHEN n.shocked THEN GREATEST(s.vol_mult, _cfg.shock_vol_mult)
                ELSE ROUND(1 + (s.vol_mult - 1) * _cfg.vol_mult_decay, 4)
            END,
            impact_pending = CASE
                WHEN abs(n.impact_pending * (1 - _rate)) < 0.0002 THEN 0
                ELSE ROUND((n.impact_pending * (1 - _rate))::NUMERIC, 6)
            END,
            updated_at = now()
        FROM moves AS n
        WHERE s.symbol = n.symbol
        RETURNING s.symbol, s.current_price
    ),
    consumed AS (
        -- Kullanilan pay bagli hissenin bekleyen hareketinden dusulur (durdurulmus hisseninki bekler).
        UPDATE public.stock_links AS l
        SET pending_return = l.pending_return - l.pending_return / l.ticks_left,
            ticks_left = l.ticks_left - 1
        FROM draws AS d
        WHERE d.symbol = l.symbol AND d.linked
        RETURNING 1
    ),
    inserted AS (
        INSERT INTO public.price_history (symbol, price, recorded_at)
        SELECT symbol, current_price, now()
        FROM updated
        RETURNING id
    )
    SELECT count(*) INTO _updated_count FROM inserted;

    DELETE FROM public.price_history
    WHERE recorded_at < now() - INTERVAL '48 hours';

    -- Piyasa geneli devre kesici: hisselerin gunluk degisim ortalamasina bakilir.
    -- Her basamak gunde bir kez calisir; en agir uyan basamak gecerlidir.
    SELECT coalesce(avg(change_pct), 0) / 100 INTO _index FROM public.stocks;

    FOR _level IN
        SELECT e.ord::INTEGER AS ord,
               (e.item ->> 'drop')::NUMERIC AS drop_pct,
               coalesce((e.item ->> 'minutes')::INTEGER, 0) AS minutes
        FROM jsonb_array_elements(_cfg.market_breaker_levels) WITH ORDINALITY AS e(item, ord)
        ORDER BY e.ord DESC
    LOOP
        IF _level.drop_pct > 0 AND _index <= -_level.drop_pct AND _level.ord > _market.halt_level THEN
            INSERT INTO public.news_feed (id, title, summary, stock_symbol, impact_pct, created_at)
            VALUES (
                floor(extract(epoch FROM clock_timestamp()) * 1000000)::BIGINT,
                '⚡ Piyasa geneli devre kesici devreye girdi',
                'Hisselerin ortalaması gün içinde %' || ROUND(abs(_index) * 100, 1)
                    || ' düştü. Hisse işlemleri '
                    || CASE WHEN _level.minutes > 0
                            THEN _level.minutes || ' dakika durduruldu.'
                            ELSE 'gün sonuna kadar durduruldu; piyasa yarın 09:00''da açılacak.'
                       END,
                NULL,
                0,
                now()
            );

            IF _level.minutes > 0 THEN
                UPDATE public.market_settings
                SET halt_level = _level.ord,
                    halt_until = now() + make_interval(mins => _level.minutes)
                WHERE id = 1;
            ELSE
                UPDATE public.market_settings
                SET halt_level = _level.ord, halt_until = NULL
                WHERE id = 1;
                PERFORM public.apply_market_open(false);
            END IF;
            EXIT;
        END IF;
    END LOOP;

    RETURN QUERY SELECT * FROM public.stocks ORDER BY symbol;
END;
$$;

REVOKE ALL ON FUNCTION public.batch_tick_market_prices()
    FROM PUBLIC, anon, authenticated;

-- Oyuncunun gordugu sirket karneleri. Gercek hisse kodu ve fiyati DONMEZ.
CREATE OR REPLACE FUNCTION public.get_stock_reports()
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_build_object(
        'enabled', (SELECT stock_link_enabled FROM public.engine_settings WHERE id = 1),
        'reports', coalesce((
            SELECT jsonb_object_agg(l.symbol, jsonb_build_object(
                'sector', l.sector,
                'summary', l.summary,
                'sensitivities', l.sensitivities,
                'stats', l.stats,
                'live', l.fetched_at > now() - INTERVAL '20 minutes'
            ))
            FROM public.stock_links AS l
        ), '{}'::jsonb)
    );
$$;

REVOKE ALL ON FUNCTION public.get_stock_reports() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_stock_reports() TO anon, authenticated;

-- Yonetici: baglamayi ac/kapat ve rastgele kismin ne kadar kisilacagini belirle (0 = hic, 1 = eskisi gibi).
CREATE OR REPLACE FUNCTION public.admin_set_stock_links(p_enabled BOOLEAN, p_quiet NUMERIC DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF p_enabled IS NULL THEN
        RAISE EXCEPTION 'Açık ya da kapalı seçilmeli.';
    END IF;
    IF p_quiet IS NOT NULL AND (p_quiet < 0 OR p_quiet > 1) THEN
        RAISE EXCEPTION 'Rastgele kısmın payı %%0 ile %%100 arasında olmalı.';
    END IF;

    UPDATE public.engine_settings
    SET stock_link_enabled = p_enabled,
        quiet_vol_scale = coalesce(p_quiet, quiet_vol_scale)
    WHERE id = 1;

    RETURN (SELECT jsonb_build_object('enabled', stock_link_enabled, 'quiet', quiet_vol_scale)
            FROM public.engine_settings WHERE id = 1);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_stock_links(BOOLEAN, NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_stock_links(BOOLEAN, NUMERIC) TO authenticated;

-- Yonetici: gizli eslesme listesi ve son okuma durumu.
CREATE OR REPLACE FUNCTION public.admin_list_stock_links()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    RETURN jsonb_build_object(
        'status', (SELECT to_jsonb(s) FROM public.stock_link_status AS s WHERE s.id = 1),
        'links', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                      'symbol', l.symbol, 'real', l.yahoo_symbol, 'sector', l.sector,
                      'last_price', l.last_price, 'fetched_at', l.fetched_at) ORDER BY l.symbol), '[]'::jsonb)
                  FROM public.stock_links AS l)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_stock_links() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_stock_links() TO authenticated;

-- Hafta ici 10:00-18:55 (Turkiye) arasi 5 dakikada bir fiyat; her aksam 19:20'de karne ozeti.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('borsa-refresh-stock-links', 'borsa-refresh-stock-stats');

SELECT cron.schedule('borsa-refresh-stock-links', '*/5 7-15 * * 1-5', $$ SELECT public.refresh_stock_links(); $$);
SELECT cron.schedule('borsa-refresh-stock-stats', '20 16 * * 1-5', $$ SELECT public.refresh_stock_stats(); $$);

NOTIFY pgrst, 'reload schema';

