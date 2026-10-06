CREATE TABLE IF NOT EXISTS public.market_settings (
    id INTEGER PRIMARY KEY,
    is_market_open BOOLEAN NOT NULL DEFAULT true,
    CONSTRAINT market_settings_singleton CHECK (id = 1)
);

INSERT INTO public.market_settings (id, is_market_open)
VALUES (1, true)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.market_settings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "market_settings_read_public" ON public.market_settings;
CREATE POLICY "market_settings_read_public"
    ON public.market_settings FOR SELECT
    TO anon, authenticated
    USING (true);
DROP POLICY IF EXISTS "market_settings_admin_update" ON public.market_settings;
CREATE POLICY "market_settings_admin_update"
    ON public.market_settings FOR UPDATE
    TO authenticated
    USING (public.is_borsa_admin())
    WITH CHECK (public.is_borsa_admin());

GRANT SELECT ON public.market_settings TO anon, authenticated;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'market_settings'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.market_settings;
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.set_market_open(p_is_market_open BOOLEAN)
RETURNS public.market_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _settings public.market_settings%ROWTYPE;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    IF p_is_market_open IS NULL THEN
        RAISE EXCEPTION 'Market open status must be specified.';
    END IF;

    SELECT *
    INTO _settings
    FROM public.market_settings
    WHERE id = 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'market_settings row id=1 is missing.';
    END IF;

    IF NOT p_is_market_open THEN
        UPDATE public.stocks
        SET previous_close = current_price,
            change = 0,
            change_pct = 0,
            updated_at = now();
    END IF;

    UPDATE public.market_settings
    SET is_market_open = p_is_market_open
    WHERE id = 1
    RETURNING * INTO _settings;

    RETURN _settings;
END;
$$;

REVOKE ALL ON FUNCTION public.set_market_open(BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_market_open(BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.execute_hybrid_trade(
    p_user_id UUID,
    p_symbol VARCHAR(16),
    p_qty INTEGER,
    p_side TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _symbol VARCHAR(16) := upper(trim(coalesce(p_symbol, '')));
    _side TEXT := upper(trim(coalesce(p_side, '')));
    _market_open BOOLEAN;
    _stock public.stocks%ROWTYPE;
    _updated_stock public.stocks%ROWTYPE;
    _execution_price NUMERIC(18,4);
    _trade_volume NUMERIC;
    _impact_fraction NUMERIC;
    _unlimited_price NUMERIC;
    _new_price NUMERIC(18,4);
    _circuit_breaker_triggered BOOLEAN;
    _trade_result JSONB;
BEGIN
    IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_user_id THEN
        RAISE EXCEPTION 'Authenticated user does not match trade user.'
            USING ERRCODE = '42501';
    END IF;

    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'Trade quantity must be greater than zero.';
    END IF;

    IF _side NOT IN ('BUY', 'SELL') THEN
        RAISE EXCEPTION 'Trade side must be BUY or SELL.';
    END IF;

    SELECT is_market_open
    INTO _market_open
    FROM public.market_settings
    WHERE id = 1
    FOR SHARE;

    IF NOT FOUND OR NOT _market_open THEN
        RAISE EXCEPTION 'Piyasa kapalı. Alım-satım yapılamaz.';
    END IF;

    SELECT *
    INTO _stock
    FROM public.stocks
    WHERE symbol = _symbol
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock not found: %', _symbol;
    END IF;

    IF _stock.current_price < 0.01
       OR _stock.market_cap IS NULL
       OR _stock.market_cap <= 0 THEN
        RAISE EXCEPTION 'Stock price and market cap must be positive.';
    END IF;

    _execution_price := _stock.current_price;
    _trade_volume := p_qty::numeric * _execution_price;
    _impact_fraction := _trade_volume / _stock.market_cap;
    _unlimited_price := _execution_price * (
        1 + CASE WHEN _side = 'BUY'
            THEN _impact_fraction
            ELSE -_impact_fraction
        END
    );
    _circuit_breaker_triggered :=
        _unlimited_price > _execution_price * 1.20
        OR _unlimited_price < _execution_price * 0.80;
    _new_price := ROUND(
        GREATEST(
            0.01::numeric,
            LEAST(
                _execution_price * 1.20,
                GREATEST(_execution_price * 0.80, _unlimited_price)
            )
        ),
        4
    );

    EXECUTE
        'SELECT to_jsonb(t)
         FROM public.execute_trade(
             $1::uuid, $2::varchar(16), $3::integer, $4::numeric, $5::text
         ) AS t'
    INTO _trade_result
    USING p_user_id, _symbol, p_qty, _execution_price, _side;

    IF _trade_result IS NULL THEN
        RAISE EXCEPTION 'Trade settlement RPC returned no result.';
    END IF;

    UPDATE public.stocks
    SET current_price = _new_price,
        change = ROUND(_new_price - previous_close, 4),
        change_pct = ROUND(
            CASE WHEN previous_close = 0 THEN 0
                 ELSE ((_new_price - previous_close) / previous_close) * 100
            END,
            4
        ),
        updated_at = now()
    WHERE symbol = _symbol
    RETURNING * INTO _updated_stock;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    VALUES (_symbol, _new_price, now());

    RETURN jsonb_build_object(
        'trade', _trade_result,
        'execution_price', _execution_price,
        'trade_volume', _trade_volume,
        'impact_fraction', _impact_fraction,
        'circuit_breaker_triggered', _circuit_breaker_triggered,
        'circuit_breaker_message', CASE
            WHEN _circuit_breaker_triggered
            THEN 'Devre Kesici: Aşırı hacim nedeniyle fiyat maksimum %20 oranında değişti.'
            ELSE NULL
        END,
        'new_price', _new_price,
        'stock', to_jsonb(_updated_stock)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.execute_hybrid_trade(UUID, VARCHAR(16), INTEGER, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_hybrid_trade(UUID, VARCHAR(16), INTEGER, TEXT)
    TO authenticated;

DO $$
DECLARE
    _trade_function REGPROCEDURE;
BEGIN
    FOR _trade_function IN
        SELECT p.oid::regprocedure
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'execute_trade'
    LOOP
        EXECUTE format(
            'REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC, anon, authenticated',
            _trade_function
        );
    END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION public.batch_tick_market_prices()
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _market_open BOOLEAN;
    _updated_count INTEGER := 0;
BEGIN
    SELECT is_market_open
    INTO _market_open
    FROM public.market_settings
    WHERE id = 1
    FOR SHARE;

    IF NOT FOUND OR NOT _market_open THEN
        RETURN QUERY SELECT * FROM public.stocks ORDER BY symbol;
        RETURN;
    END IF;

    WITH next_moves AS MATERIALIZED (
        SELECT symbol, (random() * 0.006 - 0.003)::numeric AS delta
        FROM public.stocks
    ),
    updated AS (
        UPDATE public.stocks AS s
        SET current_price = GREATEST(
                0.01::numeric,
                ROUND(s.current_price * (1 + n.delta), 4)
            ),
            change = ROUND(
                GREATEST(0.01::numeric, ROUND(s.current_price * (1 + n.delta), 4))
                - s.previous_close,
                4
            ),
            change_pct = ROUND(
                CASE WHEN s.previous_close = 0 THEN 0
                     ELSE (
                         (
                             GREATEST(0.01::numeric, ROUND(s.current_price * (1 + n.delta), 4))
                             - s.previous_close
                         ) / s.previous_close
                     ) * 100
                END,
                4
            ),
            updated_at = now()
        FROM next_moves AS n
        WHERE s.symbol = n.symbol
        RETURNING s.symbol, s.current_price
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

    RETURN QUERY SELECT * FROM public.stocks ORDER BY symbol;
END;
$$;

REVOKE ALL ON FUNCTION public.batch_tick_market_prices()
    FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
