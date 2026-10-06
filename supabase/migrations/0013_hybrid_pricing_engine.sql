-- Keep trade settlement in the existing execute_trade RPC, and apply the
-- resulting price impact in the same transaction.
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
    _impact_pct NUMERIC;
    _new_price NUMERIC(18,4);
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

    IF _stock.current_price < 0.01 OR _stock.shares <= 0 THEN
        RAISE EXCEPTION 'Stock price and share count must be positive.';
    END IF;

    _execution_price := _stock.current_price;
    _trade_volume := p_qty::numeric * _execution_price;

    -- Impact scales with traded value relative to the stock's total value,
    -- with a 5% per-trade cap. The stock row remains locked through settlement.
    _impact_pct := LEAST(
        5::numeric,
        (_trade_volume / (_stock.shares::numeric * _execution_price)) * 100
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

    _new_price := ROUND(
        GREATEST(
            0.01::numeric,
            _execution_price * (
                1 + CASE WHEN _side = 'BUY'
                    THEN _impact_pct / 100
                    ELSE -_impact_pct / 100
                END
            )
        ),
        4
    );

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
        'impact_pct', _impact_pct,
        'stock', to_jsonb(_updated_stock)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.execute_hybrid_trade(UUID, VARCHAR(16), INTEGER, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_hybrid_trade(UUID, VARCHAR(16), INTEGER, TEXT)
    TO authenticated;

-- The existing 15-second pg_cron schedule calls this function. Applying
-- movement as an UPDATE expression makes it relative to the latest row value
-- after any concurrent trade/update releases its row lock.
CREATE OR REPLACE FUNCTION public.batch_tick_market_prices()
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _updated_count INTEGER := 0;
BEGIN
    WITH next_moves AS MATERIALIZED (
        SELECT
            symbol,
            (random() * 0.006 - 0.003)::numeric AS delta
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

    RETURN QUERY
    SELECT * FROM public.stocks ORDER BY symbol;
END;
$$;

REVOKE ALL ON FUNCTION public.batch_tick_market_prices()
    FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
