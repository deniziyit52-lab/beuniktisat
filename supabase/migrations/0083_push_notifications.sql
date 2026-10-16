-- Telefon bildirimleri (Web Push).
-- Oyuncu menuden "Telefon bildirimleri"ni acinca cihazinin bildirim adresi push_subscriptions'a yazilir.
-- Gonderilecek bildirimler push_queue'ya yazilir; push_dispatch, send-push Edge Function'ini cagirir; o da
-- push_queue_take ile sirayi alip her cihaza gonderir, push_queue_done ile isaretler. Gecersiz olan
-- (oyuncunun sildigi ya da izni kaldirdigi) cihaz adresleri kendiliginden silinir.
-- Su an gonderilen bildirimler: bekleyen emir gerceklesti / gerceklesemedi, bildirimleri acinca deneme bildirimi.

CREATE TABLE IF NOT EXISTS public.push_subscriptions (
    id         BIGSERIAL PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    endpoint   TEXT NOT NULL UNIQUE,
    p256dh     TEXT NOT NULL,
    auth       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS push_subscriptions_user_idx ON public.push_subscriptions (user_id);
ALTER TABLE public.push_subscriptions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_subscriptions FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.push_queue (
    id         BIGSERIAL PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    title      TEXT NOT NULL,
    body       TEXT,
    url        TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at    TIMESTAMPTZ,
    tries      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS push_queue_unsent_idx ON public.push_queue (created_at) WHERE sent_at IS NULL;
ALTER TABLE public.push_queue ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_queue FROM anon, authenticated;

-- Sirayi gonderici fonksiyona iletir (yalnizca sunucu ici).
CREATE OR REPLACE FUNCTION public.push_dispatch()
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _secret TEXT;
    _id BIGINT;
BEGIN
    SELECT decrypted_secret INTO _secret FROM vault.decrypted_secrets WHERE name = 'borsa_news_cron_secret';
    IF _secret IS NULL THEN
        RETURN NULL;
    END IF;
    -- Authorization'daki anahtar sitedeki herkese acik anon anahtardir; asil yetki x-cron-secret ile kontrol edilir.
    SELECT net.http_post(
        url := 'https://zhjdbpokoyitvwlkncdd.supabase.co/functions/v1/send-push',
        headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpoamRicG9rb3lpdHZ3bGtuY2RkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExODYyMzEsImV4cCI6MjEwNjc2MjIzMX0.Za4vf8mDR2xOKxXSKAipO0_-21Yk_vHiVUm5nlH1ZnY', 'x-cron-secret', _secret),
        body := '{}'::jsonb,
        timeout_milliseconds := 30000
    ) INTO _id;
    RETURN _id;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION public.push_dispatch() FROM PUBLIC, anon, authenticated;

-- Oyuncu cihazini kaydeder; her kayitta (bildirimleri acinca) deneme bildirimi gonderilir.
CREATE OR REPLACE FUNCTION public.save_push_subscription(p_endpoint TEXT, p_p256dh TEXT, p_auth TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giriş gerekli.' USING ERRCODE = '42501';
    END IF;
    IF coalesce(p_endpoint, '') !~ '^https://' OR length(p_endpoint) > 1000
       OR coalesce(p_p256dh, '') = '' OR coalesce(p_auth, '') = '' OR length(p_p256dh) > 200 OR length(p_auth) > 100 THEN
        RAISE EXCEPTION 'Geçersiz bildirim adresi.';
    END IF;
    -- Oyuncu basina en fazla 5 cihaz; fazlasinda en eskisi silinir.
    IF (SELECT count(*) FROM public.push_subscriptions WHERE user_id = _uid AND endpoint <> p_endpoint) >= 5 THEN
        DELETE FROM public.push_subscriptions
        WHERE id = (SELECT id FROM public.push_subscriptions WHERE user_id = _uid ORDER BY created_at LIMIT 1);
    END IF;
    INSERT INTO public.push_subscriptions (user_id, endpoint, p256dh, auth)
    VALUES (_uid, p_endpoint, p_p256dh, p_auth)
    ON CONFLICT (endpoint) DO UPDATE SET user_id = EXCLUDED.user_id, p256dh = EXCLUDED.p256dh, auth = EXCLUDED.auth;

    INSERT INTO public.push_queue (user_id, title, body, url)
    VALUES (_uid, '🔔 Bildirimler açık', 'Emirlerin gerçekleşince sana buradan haber vereceğiz.', '/');
    PERFORM public.push_dispatch();
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.save_push_subscription(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.save_push_subscription(TEXT, TEXT, TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.delete_push_subscription(p_endpoint TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Giriş gerekli.' USING ERRCODE = '42501';
    END IF;
    DELETE FROM public.push_subscriptions WHERE endpoint = p_endpoint AND user_id = auth.uid();
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.delete_push_subscription(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_push_subscription(TEXT) TO authenticated;

-- Bu cihazin kayitli olup olmadigi (menudeki anahtarin durumu icin).
CREATE OR REPLACE FUNCTION public.has_push_subscription(p_endpoint TEXT)
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (SELECT 1 FROM public.push_subscriptions WHERE endpoint = p_endpoint AND user_id = auth.uid());
$$;
REVOKE ALL ON FUNCTION public.has_push_subscription(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.has_push_subscription(TEXT) TO authenticated;

-- Gonderici (send-push) icin: gonderilmemis bildirimler ve alicinin cihazlari. 3 denemede gidemeyen birakilir;
-- 1 gunden eski gonderilmemis bildirim artik anlamsizdir, gonderilmez.
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
        ORDER BY created_at
        LIMIT p_limit
        FOR UPDATE SKIP LOCKED
    ),
    bumped AS (
        UPDATE public.push_queue AS p SET tries = p.tries + 1 FROM q WHERE p.id = q.id
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

CREATE OR REPLACE FUNCTION public.push_queue_done(p_sent BIGINT[], p_dead_endpoints TEXT[])
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.push_queue SET sent_at = now() WHERE id = ANY (coalesce(p_sent, '{}'));
    DELETE FROM public.push_subscriptions WHERE endpoint = ANY (coalesce(p_dead_endpoints, '{}'));
    DELETE FROM public.push_queue WHERE created_at < now() - INTERVAL '7 days';
END;
$$;
REVOKE ALL ON FUNCTION public.push_queue_done(BIGINT[], TEXT[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_queue_done(BIGINT[], TEXT[]) TO service_role;

-- 0082'deki surum; fark: gerceklesen ya da gerceklesemeyen emir icin oyuncuya bildirim sirasi yazilir
-- ve tur sonunda gonderici cagrilir.
CREATE OR REPLACE FUNCTION public.process_pending_orders()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _market public.market_settings%ROWTYPE;
    _o RECORD;
    _price NUMERIC;
    _halt TIMESTAMPTZ;
    _hit BOOLEAN;
    _held NUMERIC;
    _qty INTEGER;
    _res JSONB;
    _done INTEGER := 0;
    _msg TEXT;
    _name TEXT;
    _queued INTEGER := 0;
BEGIN
    SELECT * INTO _market FROM public.market_settings WHERE id = 1;
    IF NOT FOUND OR NOT _market.is_market_open
       OR (_market.halt_until IS NOT NULL AND _market.halt_until > now()) THEN
        RETURN 0;
    END IF;

    FOR _o IN
        SELECT o.*
        FROM public.stock_orders AS o
        JOIN public.stocks AS s ON s.symbol = o.symbol
        WHERE o.status = 'pending'
          AND (s.halt_until IS NULL OR s.halt_until <= now())
          AND CASE
                WHEN o.kind = 'LIMIT' AND o.side = 'BUY'  THEN s.current_price <= o.trigger_price
                WHEN o.kind = 'LIMIT' AND o.side = 'SELL' THEN s.current_price >= o.trigger_price
                WHEN o.kind = 'STOP'  AND o.side = 'SELL' THEN s.current_price <= o.trigger_price
                ELSE false END
        ORDER BY o.created_at
        LIMIT 200
    LOOP
        -- Onceki emirler fiyati oynatmis olabilir: kosul guncel fiyatla yeniden denetlenir.
        SELECT current_price, halt_until INTO _price, _halt FROM public.stocks WHERE symbol = _o.symbol;
        _hit := CASE
            WHEN _o.kind = 'LIMIT' AND _o.side = 'BUY'  THEN _price <= _o.trigger_price
            WHEN _o.kind = 'LIMIT' AND _o.side = 'SELL' THEN _price >= _o.trigger_price
            ELSE _price <= _o.trigger_price END;
        IF (_halt IS NOT NULL AND _halt > now()) OR NOT coalesce(_hit, false) THEN
            CONTINUE;
        END IF;

        _qty := _o.qty;
        IF _o.side = 'SELL' THEN
            SELECT coalesce((u.portfolio -> _o.symbol ->> 'qty')::NUMERIC, 0) INTO _held
            FROM public.users AS u WHERE u.id = _o.user_id AND jsonb_typeof(u.portfolio) = 'object';
            _qty := LEAST(_o.qty, floor(coalesce(_held, 0))::INTEGER);
            IF _qty <= 0 THEN
                UPDATE public.stock_orders
                SET status = 'cancelled', done_at = now(), note = 'Elinde bu hisseden kalmadığı için iptal edildi.'
                WHERE id = _o.id;
                CONTINUE;
            END IF;
        END IF;

        BEGIN
            PERFORM set_config('request.jwt.claim.sub', _o.user_id::TEXT, true);
            PERFORM set_config('request.jwt.claims', jsonb_build_object('sub', _o.user_id, 'role', 'authenticated')::TEXT, true);
            _res := public.execute_hybrid_trade(_o.user_id, _o.symbol, _qty, _o.side);
            UPDATE public.stock_orders
            SET status = 'filled', done_at = now(),
                fill_price = (_res ->> 'execution_price')::NUMERIC,
                fill_qty = _qty,
                fill_total = (_res ->> 'total')::NUMERIC,
                note = CASE WHEN _qty < _o.qty THEN 'Elindeki ' || _qty || ' adet satıldı.' END
            WHERE id = _o.id;
            _done := _done + 1;
            SELECT name INTO _name FROM public.stocks WHERE symbol = _o.symbol;
            INSERT INTO public.push_queue (user_id, title, body, url)
            VALUES (_o.user_id,
                    '✅ ' || CASE WHEN _o.kind = 'STOP' THEN 'Zarar durdur' WHEN _o.side = 'BUY' THEN 'Limit alış' ELSE 'Limit satış' END
                          || ' emrin gerçekleşti',
                    coalesce(_name, _o.symbol) || ': ' || _qty || ' adet × '
                          || replace(to_char((_res ->> 'execution_price')::NUMERIC, 'FM999999990.00'), '.', ',') || ' ₺',
                    '/');
            _queued := _queued + 1;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS _msg = MESSAGE_TEXT;
            UPDATE public.stock_orders
            SET status = 'failed', done_at = now(), note = left(_msg, 300)
            WHERE id = _o.id;
            INSERT INTO public.push_queue (user_id, title, body, url)
            SELECT _o.user_id, '⚠️ Emrin gerçekleşemedi', coalesce(s.name, _o.symbol) || ': ' || left(_msg, 120), '/'
            FROM public.stocks AS s WHERE s.symbol = _o.symbol;
            _queued := _queued + 1;
        END;
    END LOOP;

    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', '', true);
    IF _queued > 0 THEN
        PERFORM public.push_dispatch();
    END IF;
    RETURN _done;
END;
$$;
REVOKE ALL ON FUNCTION public.process_pending_orders() FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
