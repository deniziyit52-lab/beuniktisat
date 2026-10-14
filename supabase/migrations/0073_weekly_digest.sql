-- Haftalik ozet e-postasi: her cuma piyasa kapaninca, e-posta bilgilendirmesine onay vermis oyunculara
-- kendi sonucunu (varlik, haftalik degisim, siralama) ve haftanin ozetini gonderir.
-- Gonderimi weekly-digest Edge Function'i yapar (SMTP, 465 portu); burada veri, kayit ve zamanlama durur.
-- Fonksiyon 10 dakikada bir 40'ar kisilik gruplar halinde cagrilir; her gonderim kayda gecer, kimseye iki kez gitmez.

-- Abonelikten cikma baglantisi icin oyuncuya ozel, tahmin edilemez anahtar.
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS digest_token UUID NOT NULL DEFAULT gen_random_uuid();
CREATE UNIQUE INDEX IF NOT EXISTS users_digest_token_unique ON public.users (digest_token);

-- Her oyuncunun son ozetteki durumu; bir sonraki hafta "gecen haftaya gore" kiyas icin.
CREATE TABLE IF NOT EXISTS public.weekly_digest_snapshots (
    user_id UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
    wealth NUMERIC NOT NULL,
    rank INTEGER,
    taken_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Hangi hafta kime gonderildi (basarili ya da basarisiz). Haftanin anahtari, Turkiye saatine gore o haftanin pazartesisi.
CREATE TABLE IF NOT EXISTS public.weekly_digest_log (
    week_start DATE NOT NULL,
    user_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    ok BOOLEAN NOT NULL,
    error TEXT,
    sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (week_start, user_id)
);

-- Haftanin gonderimi bitince (alici kalmayinca) bir satir yazilir ve o andaki durumlar saklanir.
CREATE TABLE IF NOT EXISTS public.weekly_digest_runs (
    week_start DATE PRIMARY KEY,
    finished_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent INTEGER NOT NULL DEFAULT 0,
    failed INTEGER NOT NULL DEFAULT 0
);

ALTER TABLE public.weekly_digest_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_digest_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.weekly_digest_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.weekly_digest_snapshots, public.weekly_digest_log, public.weekly_digest_runs FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.digest_week_start()
RETURNS DATE
LANGUAGE SQL
STABLE
AS $$
    SELECT date_trunc('week', now() AT TIME ZONE 'Europe/Istanbul')::DATE;
$$;

-- Siralama, liderlik tablosuyla ayni: en az bir islem yapmis oyuncular, getiri yuzdesine gore.
CREATE OR REPLACE FUNCTION public.digest_ranked()
RETURNS TABLE(user_id UUID, wealth NUMERIC, return_pct NUMERIC, rank BIGINT)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT r.user_id, r.wealth, r.return_pct,
           CASE WHEN a.active THEN ROW_NUMBER() OVER (PARTITION BY a.active ORDER BY r.return_pct DESC, r.user_id) END
    FROM public.user_returns() AS r
    CROSS JOIN LATERAL (
        SELECT EXISTS (SELECT 1 FROM public.transactions AS t WHERE t.user_id = r.user_id)
            OR EXISTS (SELECT 1 FROM public.asset_transactions AS t WHERE t.user_id = r.user_id) AS active
    ) AS a;
$$;

-- Gonderilecek veriler. p_only_user verilirse yalnizca o oyuncu (yonetici denemesi; onay ve kayit bakilmaz).
-- Yoksa onay vermis, e-postasini dogrulamis ve bu hafta henuz gonderilmemis en fazla p_limit oyuncu.
CREATE OR REPLACE FUNCTION public.weekly_digest_payload(p_limit INTEGER DEFAULT 40, p_only_user UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _week DATE := public.digest_week_start();
    _ranked JSONB;
    _active INTEGER;
    _top JSONB;
    _movers JSONB;
    _trades INTEGER;
    _recipients JSONB;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS _digest_rank ON COMMIT DROP AS SELECT * FROM public.digest_ranked();
    SELECT count(*) INTO _active FROM _digest_rank WHERE rank IS NOT NULL;

    SELECT coalesce(jsonb_agg(jsonb_build_object('name', coalesce(u.nickname, u.display_name, 'Oyuncu'), 'return_pct', round(k.return_pct, 2)) ORDER BY k.rank), '[]')
    INTO _top
    FROM _digest_rank AS k JOIN public.users AS u ON u.id = k.user_id
    WHERE k.rank <= 3;

    -- Haftalik hisse degisimi: simdiki fiyat, 7 gun onceki (yoksa en eski) saatlik kayda gore.
    WITH w AS (
        SELECT s.name, s.current_price AS now_price,
               coalesce(
                   (SELECT h.price FROM public.price_history_hourly AS h
                    WHERE h.symbol = s.symbol AND h.recorded_at <= now() - INTERVAL '7 days'
                    ORDER BY h.recorded_at DESC LIMIT 1),
                   (SELECT h.price FROM public.price_history_hourly AS h
                    WHERE h.symbol = s.symbol ORDER BY h.recorded_at LIMIT 1)) AS then_price
        FROM public.stocks AS s
    ), p AS (
        SELECT name, round((now_price / then_price - 1) * 100, 2) AS pct FROM w WHERE then_price > 0
    )
    SELECT jsonb_build_object(
        'up', (SELECT jsonb_build_object('name', name, 'pct', pct) FROM p ORDER BY pct DESC LIMIT 1),
        'down', (SELECT jsonb_build_object('name', name, 'pct', pct) FROM p ORDER BY pct ASC LIMIT 1))
    INTO _movers;

    SELECT (SELECT count(*) FROM public.transactions WHERE created_at > now() - INTERVAL '7 days')
         + (SELECT count(*) FROM public.asset_transactions WHERE created_at > now() - INTERVAL '7 days')
    INTO _trades;

    SELECT coalesce(jsonb_agg(x), '[]') INTO _recipients FROM (
        SELECT jsonb_build_object(
            'user_id', u.id,
            'email', coalesce(nullif(btrim(u.email), ''), au.email),
            'name', coalesce(nullif(split_part(btrim(u.display_name), ' ', 1), ''), u.nickname, 'Yatırımcı'),
            'wealth', round(k.wealth, 2),
            'return_pct', round(k.return_pct, 2),
            'rank', k.rank,
            'prev_wealth', round(sn.wealth, 2),
            'prev_rank', sn.rank,
            'trades_week', (SELECT count(*) FROM public.transactions AS t WHERE t.user_id = u.id AND t.created_at > now() - INTERVAL '7 days')
                         + (SELECT count(*) FROM public.asset_transactions AS t WHERE t.user_id = u.id AND t.created_at > now() - INTERVAL '7 days'),
            'token', u.digest_token) AS x
        FROM public.users AS u
        JOIN auth.users AS au ON au.id = u.id
        JOIN _digest_rank AS k ON k.user_id = u.id
        LEFT JOIN public.weekly_digest_snapshots AS sn ON sn.user_id = u.id
        WHERE CASE WHEN p_only_user IS NOT NULL THEN u.id = p_only_user
                   ELSE u.email_opt_in
                        AND au.email_confirmed_at IS NOT NULL
                        AND NOT EXISTS (SELECT 1 FROM public.weekly_digest_log AS l WHERE l.week_start = _week AND l.user_id = u.id)
              END
        ORDER BY u.id
        LIMIT CASE WHEN p_only_user IS NOT NULL THEN 1 ELSE GREATEST(coalesce(p_limit, 40), 1) END
    ) AS r;

    DROP TABLE IF EXISTS _digest_rank;
    RETURN jsonb_build_object('week_start', _week, 'active_players', _active, 'top', _top,
                              'movers', _movers, 'trades_week', _trades, 'recipients', _recipients);
END;
$$;

-- Bir oyuncuya gonderimin sonucu.
CREATE OR REPLACE FUNCTION public.weekly_digest_record(p_user UUID, p_ok BOOLEAN, p_error TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    INSERT INTO public.weekly_digest_log (week_start, user_id, ok, error)
    VALUES (public.digest_week_start(), p_user, coalesce(p_ok, false), left(p_error, 500))
    ON CONFLICT (week_start, user_id) DO NOTHING;
$$;

-- Alici kalmayinca cagrilir: haftayi kapatir ve herkesin durumunu bir sonraki kiyas icin saklar. Haftada bir kez calisir.
CREATE OR REPLACE FUNCTION public.weekly_digest_finish()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _week DATE := public.digest_week_start();
BEGIN
    IF EXISTS (SELECT 1 FROM public.weekly_digest_runs WHERE week_start = _week) THEN
        RETURN false;
    END IF;
    INSERT INTO public.weekly_digest_runs (week_start, sent, failed)
    SELECT _week, count(*) FILTER (WHERE ok), count(*) FILTER (WHERE NOT ok)
    FROM public.weekly_digest_log WHERE week_start = _week;

    INSERT INTO public.weekly_digest_snapshots (user_id, wealth, rank, taken_at)
    SELECT user_id, wealth, rank, now() FROM public.digest_ranked()
    ON CONFLICT (user_id) DO UPDATE SET wealth = EXCLUDED.wealth, rank = EXCLUDED.rank, taken_at = EXCLUDED.taken_at;
    RETURN true;
END;
$$;

-- E-postadaki "abonelikten cik" baglantisi. Yanlis anahtar hicbir seyi degistirmez.
CREATE OR REPLACE FUNCTION public.weekly_digest_unsubscribe(p_token UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.users SET email_opt_in = false, email_opt_in_at = NULL WHERE digest_token = p_token;
    RETURN FOUND;
END;
$$;

-- Bu fonksiyonlari yalnizca Edge Function (service_role) cagirir.
REVOKE ALL ON FUNCTION public.digest_ranked() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.weekly_digest_payload(INTEGER, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.weekly_digest_record(UUID, BOOLEAN, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.weekly_digest_finish() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.weekly_digest_unsubscribe(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.digest_ranked() TO service_role;
GRANT EXECUTE ON FUNCTION public.weekly_digest_payload(INTEGER, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION public.weekly_digest_record(UUID, BOOLEAN, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION public.weekly_digest_finish() TO service_role;
GRANT EXECUTE ON FUNCTION public.weekly_digest_unsubscribe(UUID) TO service_role;

-- Yonetici paneli: onay veren sayisi, bu haftanin ve son haftalarin gonderim durumu.
CREATE OR REPLACE FUNCTION public.admin_digest_status()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _week DATE := public.digest_week_start();
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    RETURN jsonb_build_object(
        'opted_in', (SELECT count(*) FROM public.users AS u JOIN auth.users AS au ON au.id = u.id
                     WHERE u.email_opt_in AND au.email_confirmed_at IS NOT NULL),
        'this_week_sent', (SELECT count(*) FROM public.weekly_digest_log WHERE week_start = _week AND ok),
        'this_week_failed', (SELECT count(*) FROM public.weekly_digest_log WHERE week_start = _week AND NOT ok),
        'last_error', (SELECT error FROM public.weekly_digest_log WHERE NOT ok ORDER BY sent_at DESC LIMIT 1),
        'runs', coalesce((SELECT jsonb_agg(jsonb_build_object('week_start', week_start, 'finished_at', finished_at, 'sent', sent, 'failed', failed) ORDER BY week_start DESC)
                          FROM (SELECT * FROM public.weekly_digest_runs ORDER BY week_start DESC LIMIT 5) AS r), '[]'));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_digest_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_digest_status() TO authenticated;

-- Yonetici paneli: ozetin bir ornegini yalnizca yoneticinin kendisine gonderir (kayda gecmez, haftayi kapatmaz).
CREATE OR REPLACE FUNCTION public.admin_send_digest_test()
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _secret TEXT;
    _request_id BIGINT;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    SELECT decrypted_secret INTO _secret FROM vault.decrypted_secrets WHERE name = 'borsa_news_cron_secret';
    IF _secret IS NULL THEN
        RAISE EXCEPTION 'Gizli anahtar (borsa_news_cron_secret) veritabanında bulunamadı.';
    END IF;
    SELECT net.http_post(
        url := 'https://zhjdbpokoyitvwlkncdd.supabase.co/functions/v1/weekly-digest',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', _secret),
        body := jsonb_build_object('test_user', auth.uid()),
        timeout_milliseconds := 30000
    ) INTO _request_id;
    RETURN _request_id;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_send_digest_test() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_send_digest_test() TO authenticated;

-- Deneme gonderiminin sonucu (Edge Function'in cevabi).
CREATE OR REPLACE FUNCTION public.admin_digest_test_result(p_request_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _r RECORD;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    SELECT status_code, content, error_msg, timed_out INTO _r FROM net._http_response WHERE id = p_request_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('done', false);
    END IF;
    RETURN jsonb_build_object('done', true, 'status', _r.status_code, 'body', left(_r.content, 500),
                              'error', coalesce(_r.error_msg, CASE WHEN _r.timed_out THEN 'zaman aşımı' END));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_digest_test_result(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_digest_test_result(BIGINT) TO authenticated;

-- Cuma 18:05-19:55 (Turkiye) arasi 10 dakikada bir; her seferde en fazla 40 kisi. Alici kalmayinca fonksiyon bos doner.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'borsa-weekly-digest';
SELECT cron.schedule(
    'borsa-weekly-digest',
    '5-55/10 15,16 * * 5',
    $$
    SELECT net.http_post(
        url := 'https://zhjdbpokoyitvwlkncdd.supabase.co/functions/v1/weekly-digest',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'borsa_news_cron_secret')
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 120000
    );
    $$
);

NOTIFY pgrst, 'reload schema';

SELECT 'Haftalık özet' AS konu,
       (SELECT count(*) FROM public.users AS u JOIN auth.users AS au ON au.id = u.id
        WHERE u.email_opt_in AND au.email_confirmed_at IS NOT NULL) AS onay_veren_uye,
       EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'borsa-weekly-digest') AS zamanlandi;
