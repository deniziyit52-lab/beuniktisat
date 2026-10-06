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

    IF NOT FOUND THEN
        RAISE EXCEPTION 'market_settings row id=1 is missing.';
    END IF;

    IF NOT _market_open THEN
        RETURN QUERY SELECT * FROM public.stocks ORDER BY symbol;
        RETURN;
    END IF;

    WITH next_moves AS MATERIALIZED (
        SELECT
            symbol,
            (CASE WHEN random() < 0.5 THEN -1::numeric ELSE 1::numeric END)
                * (0.0002::numeric + random()::numeric * 0.0013::numeric) AS delta
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
