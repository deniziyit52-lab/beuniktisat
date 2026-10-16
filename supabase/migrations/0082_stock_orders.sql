-- Bekleyen emirler: Limit Al, Limit Sat, Zarar Durdur (sat).
--   LIMIT BUY : fiyat tetik fiyatina ya da altina inince alir
--   LIMIT SELL: fiyat tetik fiyatina ya da ustune cikinca satar
--   STOP  SELL: fiyat tetik fiyatina ya da altina inince satar (zarar durdur)
-- Emir iptal edilene kadar bekler; piyasa kapaliyken de verilebilir. Piyasa acikken her dakika, fiyat
-- guncellendikten hemen sonra (ayni cron gorevi) kontrol edilir. Tetiklenen emir normal alim-satimla ayni
-- yoldan (execute_hybrid_trade) o anki fiyattan gerceklesir: komisyon, fiyat kaymasi, %40 siniri, bakiye
-- kontrolu aynidir. Nakit emir verilirken ayrilmaz; gerceklesme aninda yetmezse emir "gerçekleşemedi" olur.
-- Satis emrinde oyuncunun elindeki adet azaldiysa elindeki kadari satilir.

CREATE TABLE IF NOT EXISTS public.stock_orders (
    id            BIGSERIAL PRIMARY KEY,
    user_id       UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    symbol        VARCHAR(16) NOT NULL,
    side          TEXT NOT NULL CHECK (side IN ('BUY', 'SELL')),
    kind          TEXT NOT NULL CHECK (kind IN ('LIMIT', 'STOP')),
    qty           INTEGER NOT NULL CHECK (qty > 0),
    trigger_price NUMERIC(18,4) NOT NULL CHECK (trigger_price > 0),
    status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'filled', 'cancelled', 'failed')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    done_at       TIMESTAMPTZ,
    fill_price    NUMERIC(18,4),
    fill_qty      INTEGER,
    fill_total    NUMERIC,
    note          TEXT,
    CHECK (NOT (kind = 'STOP' AND side = 'BUY'))
);
CREATE INDEX IF NOT EXISTS stock_orders_pending_idx ON public.stock_orders (symbol) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS stock_orders_user_idx ON public.stock_orders (user_id, created_at DESC);

ALTER TABLE public.stock_orders ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stock_orders FROM anon, authenticated;
GRANT SELECT ON public.stock_orders TO authenticated;
DROP POLICY IF EXISTS "stock_orders kendi emirleri" ON public.stock_orders;
CREATE POLICY "stock_orders kendi emirleri" ON public.stock_orders
    FOR SELECT TO authenticated USING (user_id = auth.uid());

-- Emir ver
CREATE OR REPLACE FUNCTION public.place_stock_order(p_symbol TEXT, p_side TEXT, p_kind TEXT, p_qty INTEGER, p_price NUMERIC)
RETURNS public.stock_orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _symbol TEXT := upper(btrim(coalesce(p_symbol, '')));
    _side TEXT := upper(btrim(coalesce(p_side, '')));
    _kind TEXT := upper(btrim(coalesce(p_kind, '')));
    _price NUMERIC;
    _row public.stock_orders;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Emir vermek için giriş yapın.' USING ERRCODE = '42501';
    END IF;
    IF _side NOT IN ('BUY', 'SELL') OR _kind NOT IN ('LIMIT', 'STOP') OR (_kind = 'STOP' AND _side = 'BUY') THEN
        RAISE EXCEPTION 'Geçersiz emir türü.';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 OR p_qty > 1000000 THEN
        RAISE EXCEPTION 'Geçerli bir adet girin.';
    END IF;
    IF p_price IS NULL OR p_price <= 0 OR p_price > 1000000 THEN
        RAISE EXCEPTION 'Geçerli bir tetik fiyatı girin.';
    END IF;
    SELECT current_price INTO _price FROM public.stocks WHERE symbol = _symbol;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hisse bulunamadı.';
    END IF;
    IF (SELECT count(*) FROM public.stock_orders WHERE user_id = _uid AND status = 'pending') >= 20 THEN
        RAISE EXCEPTION 'Aynı anda en fazla 20 bekleyen emrin olabilir. Önce birini iptal et.';
    END IF;
    IF _side = 'SELL' AND coalesce((
           SELECT (u.portfolio -> _symbol ->> 'qty')::NUMERIC FROM public.users AS u
           WHERE u.id = _uid AND jsonb_typeof(u.portfolio) = 'object'), 0) <= 0 THEN
        RAISE EXCEPTION 'Bu hisseden elinde yok; satış emri veremezsin.';
    END IF;

    INSERT INTO public.stock_orders (user_id, symbol, side, kind, qty, trigger_price)
    VALUES (_uid, _symbol, _side, _kind, p_qty, ROUND(p_price, 4))
    RETURNING * INTO _row;
    RETURN _row;
END;
$$;
REVOKE ALL ON FUNCTION public.place_stock_order(TEXT, TEXT, TEXT, INTEGER, NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.place_stock_order(TEXT, TEXT, TEXT, INTEGER, NUMERIC) TO authenticated;

-- Emri iptal et (yalnizca kendi bekleyen emri)
CREATE OR REPLACE FUNCTION public.cancel_stock_order(p_id BIGINT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Giriş gerekli.' USING ERRCODE = '42501';
    END IF;
    UPDATE public.stock_orders
    SET status = 'cancelled', done_at = now(), note = 'Sen iptal ettin.'
    WHERE id = p_id AND user_id = auth.uid() AND status = 'pending';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Bu emir artık beklemede değil (gerçekleşmiş ya da iptal edilmiş olabilir).';
    END IF;
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION public.cancel_stock_order(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_stock_order(BIGINT) TO authenticated;

-- Tetiklenen emirleri gerceklestirir. Yalnizca cron cagirir (fiyat guncellemesinden hemen sonra).
-- Alim-satim fonksiyonu oturumdaki kullaniciyi kontrol ettigi icin, her emir icin o oyuncunun kimligi
-- yalnizca bu islem icinde gecici olarak ayarlanir; her emir kendi alt isleminde calisir, biri basarisiz
-- olursa digerleri etkilenmez.
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
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS _msg = MESSAGE_TEXT;
            UPDATE public.stock_orders
            SET status = 'failed', done_at = now(), note = left(_msg, 300)
            WHERE id = _o.id;
        END;
    END LOOP;

    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN _done;
END;
$$;
REVOKE ALL ON FUNCTION public.process_pending_orders() FROM PUBLIC, anon, authenticated;

-- Dakikalik fiyat gorevi: once fiyat, hemen ardindan emirler.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'borsa-every-60s-price-tick';
SELECT cron.schedule(
    'borsa-every-60s-price-tick',
    '* * * * *',
    $$ SELECT public.batch_tick_market_prices(); SELECT public.process_pending_orders(); $$
);

-- Oyunu sifirlama bekleyen emirleri de siler (0077'deki surum + emirler).
CREATE OR REPLACE FUNCTION public.admin_reset_game()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _users INTEGER;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    UPDATE public.users
    SET balance = 100000,
        starting_balance = 100000,
        portfolio = '{}'::jsonb,
        assets = '{}'::jsonb
    WHERE true;
    GET DIAGNOSTICS _users = ROW_COUNT;

    DELETE FROM public.transactions WHERE true;
    DELETE FROM public.asset_transactions WHERE true;
    DELETE FROM public.quiz_attempts WHERE true;
    DELETE FROM public.daily_quiz_attempts WHERE true;
    DELETE FROM public.user_badges WHERE true;
    DELETE FROM public.market_tips WHERE true;
    DELETE FROM public.news_feed WHERE true;
    DELETE FROM public.stock_orders WHERE true;

    UPDATE public.stocks
    SET previous_close = current_price,
        change = 0,
        change_pct = 0,
        vol_mult = 1,
        breaker_ref = current_price,
        halt_until = NULL,
        impact_pending = 0,
        updated_at = now()
    WHERE symbol IS NOT NULL;

    UPDATE public.market_settings
    SET halt_until = NULL, halt_level = 0
    WHERE id = 1;

    RETURN jsonb_build_object('users', _users);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_reset_game() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_game() TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Kontrol: gorev komutu iki satiri da icermeli.
SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'borsa-every-60s-price-tick';
