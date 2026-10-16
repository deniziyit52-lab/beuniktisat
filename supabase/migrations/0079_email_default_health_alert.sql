-- 1) E-posta bilgilendirmesi artik kayitta varsayilan olarak acik (kullanici karari, 16 Ekim 2026).
--    Kayit ekranindaki istege bagli kutu kalkti; yeni uyeler e-posta alir. Isteyen menuden ya da e-postadaki
--    baglantidan kapatir. Mevcut uyelerin tercihi bu dosyayla DEGISMEZ.
-- 2) Sistem sagligi sorun e-postasi: Sistem Sagligi'nda bir satir art arda iki kontrolde (10 dk) kirmizi kalirsa
--    yoneticilere tek e-posta gider; her sey duzelince "duzeldi" e-postasi gider. Hafta ici 10:00-18:59 her 5 dakikada
--    health-alert Edge Function'i cagrilir; o da health_alert_tick ile neyin gonderilecegini sorar.

ALTER TABLE public.users ALTER COLUMN email_opt_in SET DEFAULT true;

-- Saglik hesabi yonetici kontrolu olmadan da calisabilsin diye ic fonksiyona tasinir (yalnizca sunucu cagirir).
CREATE OR REPLACE FUNCTION public.borsa_system_health()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _open BOOLEAN;
    _checks JSONB := '[]'::jsonb;
    _ls public.stock_link_status%ROWTYPE;
    _mi public.market_index%ROWTYPE;
    _as public.asset_fetch_status%ROWTYPE;
    _tick TIMESTAMPTZ;
    _gap NUMERIC;
    _gaps JSONB;
    _cron JSONB;
    _st TEXT;
    _min NUMERIC;
BEGIN
    SELECT coalesce(is_market_open, false) INTO _open FROM public.market_settings WHERE id = 1;
    _open := coalesce(_open, false);

    -- Gercek hisse verisi (her dakika okunur)
    SELECT * INTO _ls FROM public.stock_link_status WHERE id = 1;
    _min := ROUND(extract(epoch FROM now() - _ls.checked_at)::NUMERIC / 60, 0);
    _st := CASE
        WHEN _ls.checked_at IS NULL THEN 'bad'
        WHEN NOT _open THEN 'idle'
        WHEN _ls.ok IS NOT TRUE OR _min > 5 THEN 'bad'
        WHEN _ls.message ILIKE '%okunamayan%' THEN 'warn'
        ELSE 'ok' END;
    _checks := _checks || jsonb_build_object('label', 'Hisse verisi okuma', 'status', _st,
        'detail', CASE WHEN _ls.checked_at IS NULL THEN 'Hiç okunmamış.'
                       ELSE 'Son okuma ' || _min || ' dk önce: ' || coalesce(_ls.message, '') END);

    -- Fiyat motoru (piyasa acikken her dakika grafik gecmisine yazar)
    SELECT max(recorded_at) INTO _tick FROM public.price_history;
    _min := ROUND(extract(epoch FROM now() - _tick)::NUMERIC / 60, 0);
    _st := CASE WHEN NOT _open THEN 'idle' WHEN _tick IS NULL OR _min > 3 THEN 'bad' ELSE 'ok' END;
    _checks := _checks || jsonb_build_object('label', 'Fiyat motoru (dakikalık)', 'status', _st,
        'detail', CASE WHEN _tick IS NULL THEN 'Kayıt yok.' ELSE 'Son fiyat güncellemesi ' || _min || ' dk önce.' END);

    -- Oyun fiyati ile bagli hissenin fiyati arasindaki fark. Acikken alim-satim etkisi ve ~1 dk gecikme
    -- kisa sureli fark yaratir; kapaliyken aksam esitlemesinden sonra sifir olmalidir.
    SELECT max(abs(s.current_price / l.last_price - 1)) * 100,
           jsonb_agg(jsonb_build_object('symbol', s.symbol, 'name', s.name,
                     'gap_pct', ROUND((s.current_price / l.last_price - 1) * 100, 2),
                     'fetched_min', ROUND(extract(epoch FROM now() - l.fetched_at)::NUMERIC / 60, 0))
                     ORDER BY abs(s.current_price / l.last_price - 1) DESC)
    INTO _gap, _gaps
    FROM public.stocks AS s
    JOIN public.stock_links AS l ON l.symbol = s.symbol
    WHERE l.last_price > 0;
    _st := CASE
        WHEN _gap IS NULL THEN 'bad'
        WHEN _open AND _gap < 1 THEN 'ok'
        WHEN _open AND _gap < 5 THEN 'warn'
        WHEN NOT _open AND _gap < 0.5 THEN 'ok'
        WHEN NOT _open AND _gap < 3 THEN 'warn'
        ELSE 'bad' END;
    _checks := _checks || jsonb_build_object('label', 'Oyun fiyatı = gerçek fiyat', 'status', _st,
        'detail', CASE WHEN _gap IS NULL THEN 'Bağlı hisse fiyatı yok.'
                       ELSE 'En büyük fark %' || replace(ROUND(_gap, 2)::TEXT, '.', ',')
                            || CASE WHEN _open THEN ' (piyasa açıkken büyük işlemler birkaç dakikalık fark yaratabilir).'
                                    ELSE ' (akşam eşitlemesinden sonra sıfır olmalı).' END END,
        'stocks', coalesce(_gaps, '[]'::jsonb));

    -- ZBEU 100 (piyasanin genel yonu)
    SELECT * INTO _mi FROM public.market_index WHERE id = 1;
    _min := ROUND(extract(epoch FROM now() - _mi.checked_at)::NUMERIC / 60, 0);
    _st := CASE WHEN _mi.checked_at IS NULL THEN 'bad' WHEN NOT _open THEN 'idle'
                WHEN _mi.ok IS NOT TRUE OR _min > 15 THEN 'bad' ELSE 'ok' END;
    _checks := _checks || jsonb_build_object('label', 'ZBEÜ 100 verisi', 'status', _st,
        'detail', CASE WHEN _mi.checked_at IS NULL THEN 'Hiç okunmamış.'
                       ELSE 'Son okuma ' || _min || ' dk önce' || CASE WHEN _mi.ok IS NOT TRUE THEN ': ' || coalesce(_mi.message, 'hata') ELSE '.' END END);

    -- Altin ve doviz
    SELECT * INTO _as FROM public.asset_fetch_status WHERE id = 1;
    _min := ROUND(extract(epoch FROM now() - _as.checked_at)::NUMERIC / 60, 0);
    _st := CASE WHEN _as.checked_at IS NULL THEN 'bad' WHEN _as.ok IS NOT TRUE THEN 'bad'
                WHEN NOT _open THEN 'idle' WHEN _min > 30 THEN 'warn' ELSE 'ok' END;
    _checks := _checks || jsonb_build_object('label', 'Altın ve döviz verisi', 'status', _st,
        'detail', CASE WHEN _as.checked_at IS NULL THEN 'Hiç okunmamış.'
                       ELSE 'Son okuma ' || _min || ' dk önce' || CASE WHEN _as.ok IS NOT TRUE THEN ': ' || coalesce(_as.message, 'hata') ELSE '.' END END);

    -- Zamanlanmis gorevler: son 24 saatteki basarisiz calismalar
    BEGIN
        SELECT jsonb_agg(jsonb_build_object('job', jobname, 'count', n, 'last_at', last_at, 'message', left(msg, 200)) ORDER BY last_at DESC)
        INTO _cron
        FROM (
            SELECT j.jobname, count(*) AS n, max(d.start_time) AS last_at,
                   (array_agg(d.return_message ORDER BY d.start_time DESC))[1] AS msg
            FROM cron.job_run_details AS d
            JOIN cron.job AS j ON j.jobid = d.jobid
            WHERE d.status = 'failed' AND d.start_time > now() - INTERVAL '24 hours'
            GROUP BY j.jobname
        ) AS f;
        _checks := _checks || jsonb_build_object('label', 'Zamanlanmış görevler (son 24 saat)',
            'status', CASE WHEN _cron IS NULL THEN 'ok' ELSE 'warn' END,
            'detail', CASE WHEN _cron IS NULL THEN 'Başarısız çalışma yok.'
                           ELSE jsonb_array_length(_cron) || ' görevde hata var.' END,
            'jobs', coalesce(_cron, '[]'::jsonb));
    EXCEPTION WHEN OTHERS THEN
        _checks := _checks || jsonb_build_object('label', 'Zamanlanmış görevler (son 24 saat)', 'status', 'warn',
            'detail', 'Görev kayıtları okunamadı: ' || left(SQLERRM, 150));
    END;

    RETURN jsonb_build_object('checked_at', now(), 'market_open', _open, 'checks', _checks);
END;
$$;
REVOKE ALL ON FUNCTION public.borsa_system_health() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_system_health()
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
    RETURN public.borsa_system_health();
END;
$$;
REVOKE ALL ON FUNCTION public.admin_system_health() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_system_health() TO authenticated;

-- Uyari durumu (tek satir).
CREATE TABLE IF NOT EXISTS public.health_alert_state (
    id         INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    bad_runs   INTEGER NOT NULL DEFAULT 0,
    alerted    BOOLEAN NOT NULL DEFAULT false,
    alerted_at TIMESTAMPTZ,
    last_bad   JSONB
);
INSERT INTO public.health_alert_state (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.health_alert_state ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.health_alert_state FROM anon, authenticated;

-- Her cagrida sagligi olcer ve ne gonderilecegini soyler:
--   'down' -> kirmizi satir art arda 2 kontrolde (10 dk) suruyor, henuz bildirilmedi
--   'up'   -> bildirilmis sorun tamamen duzeldi
--   'none' -> gonderilecek bir sey yok
-- Sari (dikkat) satirlar e-posta gondermez; yalnizca panelde gorunur.
CREATE OR REPLACE FUNCTION public.health_alert_tick()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _h JSONB := public.borsa_system_health();
    _bad JSONB;
    _st public.health_alert_state%ROWTYPE;
    _action TEXT := 'none';
BEGIN
    SELECT coalesce(jsonb_agg(jsonb_build_object('label', c ->> 'label', 'detail', c ->> 'detail')), '[]'::jsonb)
    INTO _bad
    FROM jsonb_array_elements(_h -> 'checks') AS c
    WHERE c ->> 'status' = 'bad';

    SELECT * INTO _st FROM public.health_alert_state WHERE id = 1 FOR UPDATE;

    IF jsonb_array_length(_bad) > 0 THEN
        UPDATE public.health_alert_state SET bad_runs = bad_runs + 1, last_bad = _bad WHERE id = 1;
        IF _st.bad_runs + 1 >= 2 AND NOT _st.alerted THEN
            UPDATE public.health_alert_state SET alerted = true, alerted_at = now() WHERE id = 1;
            _action := 'down';
        END IF;
    ELSE
        IF _st.alerted THEN
            _action := 'up';
        END IF;
        UPDATE public.health_alert_state SET bad_runs = 0, alerted = false WHERE id = 1;
    END IF;

    RETURN jsonb_build_object(
        'action', _action,
        'bad', CASE WHEN _action = 'up' THEN coalesce(_st.last_bad, '[]'::jsonb) ELSE _bad END,
        'since', _st.alerted_at,
        'to', coalesce((
            SELECT jsonb_agg(DISTINCT au.email)
            FROM public.admins AS a
            JOIN auth.users AS au ON au.id = a.user_id
            WHERE coalesce(au.email, '') <> ''
        ), '[]'::jsonb)
    );
END;
$$;
REVOKE ALL ON FUNCTION public.health_alert_tick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.health_alert_tick() TO service_role;

-- E-posta gonderilemezse durum geri alinir; bir sonraki kontrolde yeniden denenir.
CREATE OR REPLACE FUNCTION public.health_alert_failed(p_action TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF p_action = 'down' THEN
        UPDATE public.health_alert_state SET alerted = false, alerted_at = NULL WHERE id = 1;
    ELSIF p_action = 'up' THEN
        UPDATE public.health_alert_state SET alerted = true WHERE id = 1;
    END IF;
END;
$$;
REVOKE ALL ON FUNCTION public.health_alert_failed(TEXT) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.health_alert_failed(TEXT) TO service_role;

-- Hafta ici 10:00-18:59 (Turkiye) her 5 dakikada. Authorization'daki anahtar sitedeki herkese acik anon anahtardir;
-- asil yetki x-cron-secret ile kontrol edilir.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'borsa-health-alert';
SELECT cron.schedule(
    'borsa-health-alert',
    '*/5 7-15 * * 1-5',
    $$
    SELECT net.http_post(
        url := 'https://zhjdbpokoyitvwlkncdd.supabase.co/functions/v1/health-alert',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpoamRicG9rb3lpdHZ3bGtuY2RkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExODYyMzEsImV4cCI6MjEwNjc2MjIzMX0.Za4vf8mDR2xOKxXSKAipO0_-21Yk_vHiVUm5nlH1ZnY',
            'x-cron-secret', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'borsa_news_cron_secret')
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
    );
    $$
);

NOTIFY pgrst, 'reload schema';
