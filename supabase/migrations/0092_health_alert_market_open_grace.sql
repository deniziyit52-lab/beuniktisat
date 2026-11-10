-- ZBEU 100'un ilk Yahoo bar'i piyasa acilisinda gecikmeli gelebilir.
-- Acilistan sonraki ilk 20 dakikada bugunun bar'i yoksa kontrol sari kalir;
-- sonrasinda gercek bar yasi izlenir. Uyari yalnizca kesintisiz 10 dakika
-- kirmizi kalan sorunlar icin gonderilir.

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
    _bar_min NUMERIC;
    _local_now TIMESTAMP WITHOUT TIME ZONE := now() AT TIME ZONE 'Europe/Istanbul';
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

    -- Oyun fiyati ile bagli hissenin fiyati arasindaki fark.
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

    -- Kontrol basarisini degil, bugunun son endeks barinin yasini izler.
    SELECT * INTO _mi FROM public.market_index WHERE id = 1;
    _min := ROUND(extract(epoch FROM now() - _mi.checked_at)::NUMERIC / 60, 0);
    _bar_min := ROUND(extract(epoch FROM now() - _mi.last_bar_at)::NUMERIC / 60, 0);
    _st := CASE
        WHEN NOT _open THEN 'idle'
        WHEN _mi.last_bar_at IS NULL
          OR (_mi.last_bar_at AT TIME ZONE 'Europe/Istanbul')::DATE <> _local_now::DATE
          OR (_mi.last_bar_at AT TIME ZONE 'Europe/Istanbul')::TIME < TIME '10:00'
            THEN CASE WHEN _local_now::TIME < TIME '10:20' THEN 'warn' ELSE 'bad' END
        WHEN _mi.ok IS NOT TRUE OR _bar_min > 20 THEN 'bad'
        ELSE 'ok' END;
    _checks := _checks || jsonb_build_object('label', 'ZBEÜ 100 verisi', 'status', _st,
        'detail', CASE
            WHEN NOT _open THEN
                CASE WHEN _mi.checked_at IS NULL THEN 'Hiç okunmamış.'
                     ELSE 'Son okuma ' || _min || ' dk önce' || CASE WHEN _mi.ok IS NOT TRUE THEN ': ' || coalesce(_mi.message, 'hata') ELSE '.' END END
            WHEN _mi.last_bar_at IS NULL
              OR (_mi.last_bar_at AT TIME ZONE 'Europe/Istanbul')::DATE <> _local_now::DATE
              OR (_mi.last_bar_at AT TIME ZONE 'Europe/Istanbul')::TIME < TIME '10:00'
                THEN 'Bugünün ilk endeks barı henüz gelmedi.'
                     || CASE WHEN _local_now::TIME < TIME '10:20'
                             THEN ' Açılış veri gecikmesi için 10:20''ye kadar tolerans uygulanıyor.'
                             ELSE ' Açılış toleransı sona erdi.' END
            WHEN _mi.ok IS NOT TRUE THEN
                'Son okuma ' || _min || ' dk önce: ' || coalesce(_mi.message, 'hata')
            ELSE 'Son endeks verisi ' || _bar_min || ' dk önce.'
        END);

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

-- Mevcut RPC'nin yetki kontrolu korunur; sadece yeni saglik hesabini kullanir.
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

ALTER TABLE public.health_alert_state
    ADD COLUMN IF NOT EXISTS bad_since TIMESTAMPTZ;

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
    _bad_since TIMESTAMPTZ;
    _action TEXT := 'none';
BEGIN
    SELECT coalesce(jsonb_agg(jsonb_build_object('label', c ->> 'label', 'detail', c ->> 'detail')), '[]'::jsonb)
    INTO _bad
    FROM jsonb_array_elements(_h -> 'checks') AS c
    WHERE c ->> 'status' = 'bad';

    SELECT * INTO _st FROM public.health_alert_state WHERE id = 1 FOR UPDATE;

    IF jsonb_array_length(_bad) > 0 THEN
        UPDATE public.health_alert_state
        SET bad_runs = bad_runs + 1,
            bad_since = coalesce(bad_since, now()),
            last_bad = _bad
        WHERE id = 1
        RETURNING bad_since INTO _bad_since;

        IF _bad_since <= now() - INTERVAL '10 minutes' AND NOT _st.alerted THEN
            UPDATE public.health_alert_state SET alerted = true, alerted_at = now() WHERE id = 1;
            _action := 'down';
        END IF;
    ELSE
        IF _st.alerted THEN
            _action := 'up';
        END IF;
        UPDATE public.health_alert_state
        SET bad_runs = 0, bad_since = NULL, alerted = false
        WHERE id = 1;
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

NOTIFY pgrst, 'reload schema';
