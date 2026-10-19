-- Telefon bildirimi: piyasa acildi (10:00) / piyasa kapandi (18:00). Bildirimleri acmis herkese gider.
-- Piyasayi acan/kapatan gorevler (borsa-market-open / borsa-market-close) once piyasayi acar/kapatir, sonra
-- push_market_session'i cagirir. Bildirim yalnizca piyasa gercekten o durumdaysa ve o gun henuz gonderilmediyse
-- yazilir (push_market_log). Bildirim adiminda bir hata olursa yutulur; piyasanin acilip kapanmasi bozulmaz.

CREATE TABLE IF NOT EXISTS public.push_market_log (
    day     DATE NOT NULL,
    is_open BOOLEAN NOT NULL,
    sent_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (day, is_open)
);
ALTER TABLE public.push_market_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_market_log FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.push_market_session(p_open BOOLEAN)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _today DATE := (now() AT TIME ZONE 'Europe/Istanbul')::DATE;
    _title TEXT;
    _body TEXT;
    _up RECORD;
    _down RECORD;
    _n INTEGER;
BEGIN
    IF p_open IS NULL
       OR coalesce((SELECT is_market_open FROM public.market_settings WHERE id = 1), NOT p_open) IS DISTINCT FROM p_open THEN
        RETURN 0;
    END IF;

    INSERT INTO public.push_market_log (day, is_open) VALUES (_today, p_open) ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    IF p_open THEN
        _title := '🔔 Piyasa açıldı';
        _body := 'Alım satım 18:00''e kadar açık. Bugünün fiyatlarına göz at.';
    ELSE
        SELECT name, change_pct INTO _up FROM public.stocks
        WHERE change_pct IS NOT NULL ORDER BY change_pct DESC LIMIT 1;
        SELECT name, change_pct INTO _down FROM public.stocks
        WHERE change_pct IS NOT NULL ORDER BY change_pct ASC LIMIT 1;
        _title := '🔕 Piyasa kapandı';
        _body := CASE WHEN extract(isodow FROM _today) >= 5 THEN 'Pazartesi' ELSE 'Yarın' END
                 || ' 10:00''da yeniden açılıyor.';
        IF _up.change_pct > 0 THEN
            _body := _body || ' Günün yıldızı: ' || _up.name || ' +%' || replace(to_char(_up.change_pct, 'FM990.0'), '.', ',') || '.';
        END IF;
        IF _down.change_pct < 0 THEN
            _body := _body || ' En çok düşen: ' || _down.name || ' −%' || replace(to_char(abs(_down.change_pct), 'FM990.0'), '.', ',') || '.';
        END IF;
    END IF;

    INSERT INTO public.push_queue (user_id, title, body, url)
    SELECT DISTINCT user_id, _title, _body, '/'
    FROM public.push_subscriptions;
    GET DIAGNOSTICS _n = ROW_COUNT;

    DELETE FROM public.push_market_log WHERE day < _today - 30;
    IF _n > 0 THEN
        PERFORM public.push_dispatch();
    END IF;
    RETURN _n;
EXCEPTION WHEN OTHERS THEN
    RETURN 0;
END;
$$;
REVOKE ALL ON FUNCTION public.push_market_session(BOOLEAN) FROM PUBLIC, anon, authenticated;

-- Acilis 10:00, kapanis 18:00 (Turkiye; UTC 07:00 ve 15:00), yalnizca hafta ici. Saatler 0062 ile ayni.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('borsa-market-open', 'borsa-market-close');
SELECT cron.schedule('borsa-market-open', '0 7 * * 1-5',
    $$ SELECT public.apply_market_open(true); SELECT public.push_market_session(true); $$);
SELECT cron.schedule('borsa-market-close', '0 15 * * 1-5',
    $$ SELECT public.apply_market_open(false); SELECT public.push_market_session(false); $$);

-- Kontrol: iki gorev de gorunmeli, ikisi de push_market_session icermeli.
SELECT jobname, schedule, command FROM cron.job WHERE jobname IN ('borsa-market-open', 'borsa-market-close');
