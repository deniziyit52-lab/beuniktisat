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

    SELECT *
    INTO _stock
    FROM public.stocks
    WHERE symbol = _symbol
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock not found: %', _symbol;
    END IF;

    IF _stock.current_price < 0.01 OR _stock.market_cap IS NULL OR _stock.market_cap <= 0 THEN
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

NOTIFY pgrst, 'reload schema';
