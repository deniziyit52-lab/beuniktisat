-- Yeni telefon bildirimleri (yalnizca bildirimleri acmis oyunculara gider):
-- 1) Yoneticiden duyuru: admin_send_push(baslik, metin) -> bildirimi acik herkese.
-- 2) Elindeki hisse sert oynadi: tuttugun hisse gun icinde %5 ya da daha fazla dusup/yukselirse;
--    hisse basina gunde en fazla bir kez (push_move_log). Dakikalik fiyat gorevinde, emirlerden sonra calisir.
-- 3) Temettu yatti: dividend_payments'a her kayit dusunce (tetikleyici).
-- Ayrica: sirada bekleyen bildirim varsa her dakika gonderici yeniden cagrilir (borsa-push-dispatch). Boylece
-- toplu duyurular 200'erli parcalar halinde biter, gecici olarak gidemeyenler yeniden denenir.

-- Ayni anda iki gonderici calisirsa (dakikalik yedek + emir sonrasi) ayni bildirim iki kez gitmesin:
-- alinan bildirim claimed_at ile isaretlenir; 2 dakika icinde gonderilmis sayilmazsa yeniden alinabilir.
ALTER TABLE public.push_queue ADD COLUMN IF NOT EXISTS claimed_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.push_queue_take(p_limit INTEGER DEFAULT 200)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _rows JSONB;
BEGIN
    WITH q AS (
        SELECT id FROM public.push_queue
        WHERE sent_at IS NULL AND tries < 3 AND created_at > now() - INTERVAL '1 day'
          AND (claimed_at IS NULL OR claimed_at < now() - INTERVAL '2 minutes')
        ORDER BY created_at
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED
    ),
    bumped AS (
        UPDATE public.push_queue AS p SET tries = p.tries + 1, claimed_at = now() FROM q WHERE p.id = q.id
        RETURNING p.*
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'id', b.id, 'title', b.title, 'body', b.body, 'url', b.url,
               'subs', coalesce((SELECT jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                                 FROM public.push_subscriptions AS s WHERE s.user_id = b.user_id), '[]'::jsonb))), '[]'::jsonb)
    INTO _rows
    FROM bumped AS b;
    RETURN _rows;
END;
$$;
REVOKE ALL ON FUNCTION public.push_queue_take(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_queue_take(INTEGER) TO service_role;

-- Sirada gonderilmemis bildirim varsa gondericiyi cagirir.
CREATE OR REPLACE FUNCTION public.push_dispatch_if_pending()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.push_queue
               WHERE sent_at IS NULL AND tries < 3 AND created_at > now() - INTERVAL '1 day'
                 AND (claimed_at IS NULL OR claimed_at < now() - INTERVAL '2 minutes')) THEN
        PERFORM public.push_dispatch();
        RETURN true;
    END IF;
    RETURN false;
END;
$$;
REVOKE ALL ON FUNCTION public.push_dispatch_if_pending() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'borsa-push-dispatch';
SELECT cron.schedule('borsa-push-dispatch', '* * * * *', $$ SELECT public.push_dispatch_if_pending(); $$);

-- 1) Yoneticiden duyuru
CREATE OR REPLACE FUNCTION public.admin_push_stats()
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
        'players', (SELECT count(DISTINCT user_id) FROM public.push_subscriptions),
        'devices', (SELECT count(*) FROM public.push_subscriptions)
    );
END;
$$;
REVOKE ALL ON FUNCTION public.admin_push_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_push_stats() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_send_push(p_title TEXT, p_body TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _title TEXT := btrim(coalesce(p_title, ''));
    _body TEXT := btrim(coalesce(p_body, ''));
    _n INTEGER;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF _title = '' OR length(_title) > 80 THEN
        RAISE EXCEPTION 'Başlık 1-80 karakter olmalı.';
    END IF;
    IF length(_body) > 200 THEN
        RAISE EXCEPTION 'Metin en fazla 200 karakter olabilir.';
    END IF;
    INSERT INTO public.push_queue (user_id, title, body, url)
    SELECT DISTINCT user_id, '📣 ' || _title, nullif(_body, ''), '/'
    FROM public.push_subscriptions;
    GET DIAGNOSTICS _n = ROW_COUNT;
    IF _n > 0 THEN
        PERFORM public.push_dispatch();
    END IF;
    RETURN _n;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_send_push(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_send_push(TEXT, TEXT) TO authenticated;

-- 2) Elindeki hisse sert oynadi
CREATE TABLE IF NOT EXISTS public.push_move_log (
    user_id UUID NOT NULL,
    symbol  TEXT NOT NULL,
    day     DATE NOT NULL,
    PRIMARY KEY (user_id, symbol, day)
);
ALTER TABLE public.push_move_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_move_log FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.push_check_big_moves()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _today DATE := (now() AT TIME ZONE 'Europe/Istanbul')::DATE;
    _n INTEGER;
BEGIN
    IF NOT coalesce((SELECT is_market_open FROM public.market_settings WHERE id = 1), false) THEN
        RETURN 0;
    END IF;

    WITH hits AS (
        SELECT DISTINCT ON (u.id, s.symbol)
               u.id AS user_id, s.symbol, s.name, s.change_pct, s.current_price,
               (u.portfolio -> s.symbol ->> 'qty')::NUMERIC AS qty
        FROM public.stocks AS s
        JOIN public.users AS u
          ON jsonb_typeof(u.portfolio) = 'object'
         AND coalesce((u.portfolio -> s.symbol ->> 'qty')::NUMERIC, 0) > 0
        JOIN public.push_subscriptions AS p ON p.user_id = u.id
        WHERE abs(s.change_pct) >= 5
          AND NOT EXISTS (SELECT 1 FROM public.push_move_log AS l
                          WHERE l.user_id = u.id AND l.symbol = s.symbol AND l.day = _today)
    ),
    logged AS (
        INSERT INTO public.push_move_log (user_id, symbol, day)
        SELECT user_id, symbol, _today FROM hits
        ON CONFLICT DO NOTHING
        RETURNING user_id, symbol
    )
    INSERT INTO public.push_queue (user_id, title, body, url)
    SELECT h.user_id,
           CASE WHEN h.change_pct < 0 THEN '📉 ' ELSE '📈 ' END || h.name || ' bugün %'
               || replace(to_char(abs(h.change_pct), 'FM990.0'), '.', ',')
               || CASE WHEN h.change_pct < 0 THEN ' düştü' ELSE ' yükseldi' END,
           'Elinde ' || trim(to_char(h.qty, 'FM999999990')) || ' adet var (yaklaşık '
               || replace(to_char(h.qty * h.current_price, 'FM999999990'), '.', ',') || ' ₺). '
               || CASE WHEN h.change_pct < 0 THEN 'Zararı sınırlamak için zarar durdur emri verebilirsin.'
                       ELSE 'Kârı korumak için limit satış ya da zarar durdur emri verebilirsin.' END,
           '/'
    FROM hits AS h
    JOIN logged AS g ON g.user_id = h.user_id AND g.symbol = h.symbol;
    GET DIAGNOSTICS _n = ROW_COUNT;

    DELETE FROM public.push_move_log WHERE day < _today - 7;
    IF _n > 0 THEN
        PERFORM public.push_dispatch();
    END IF;
    RETURN _n;
END;
$$;
REVOKE ALL ON FUNCTION public.push_check_big_moves() FROM PUBLIC, anon, authenticated;

-- Dakikalik fiyat gorevi: fiyat, emirler, sonra sert hareket bildirimi.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'borsa-every-60s-price-tick';
SELECT cron.schedule(
    'borsa-every-60s-price-tick',
    '* * * * *',
    $$ SELECT public.batch_tick_market_prices(); SELECT public.process_pending_orders(); SELECT public.push_check_big_moves(); $$
);

-- 3) Temettu yatti
CREATE OR REPLACE FUNCTION public.push_on_dividend()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NEW.amount > 0 AND EXISTS (SELECT 1 FROM public.push_subscriptions WHERE user_id = NEW.user_id) THEN
        INSERT INTO public.push_queue (user_id, title, body, url)
        SELECT NEW.user_id,
               '💰 ' || coalesce(s.name, NEW.symbol) || ' temettü dağıttı',
               replace(to_char(NEW.amount, 'FM999999990.00'), '.', ',') || ' ₺ hesabına yattı ('
                   || trim(to_char(NEW.qty, 'FM999999990')) || ' adet için).',
               '/'
        FROM (SELECT 1) AS x
        LEFT JOIN public.stocks AS s ON s.symbol = NEW.symbol;
    END IF;
    RETURN NEW;
EXCEPTION WHEN OTHERS THEN
    -- Bildirim yazilamasa bile temettu odemesi bozulmaz.
    RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.push_on_dividend() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_dividend_push ON public.dividend_payments;
CREATE TRIGGER trg_dividend_push
    AFTER INSERT ON public.dividend_payments
    FOR EACH ROW EXECUTE FUNCTION public.push_on_dividend();

NOTIFY pgrst, 'reload schema';

-- Kontrol: iki gorev de gorunmeli; fiyat gorevi uc satiri icermeli.
SELECT jobname, schedule, command FROM cron.job WHERE jobname IN ('borsa-every-60s-price-tick', 'borsa-push-dispatch');
