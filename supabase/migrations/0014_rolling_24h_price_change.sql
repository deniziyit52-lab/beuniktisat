CREATE OR REPLACE FUNCTION public.get_stock_24h_baselines()
RETURNS TABLE (
    symbol VARCHAR(16),
    price_24h_ago NUMERIC(18,4),
    recorded_at TIMESTAMPTZ
)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        s.symbol,
        COALESCE(past.price, oldest.price, s.current_price)::numeric(18,4),
        COALESCE(past.recorded_at, oldest.recorded_at, s.created_at)
    FROM public.stocks AS s
    LEFT JOIN LATERAL (
        SELECT h.price, h.recorded_at
        FROM public.price_history AS h
        WHERE h.symbol = s.symbol
          AND h.recorded_at <= now() - INTERVAL '24 hours'
        ORDER BY h.recorded_at DESC, h.id DESC
        LIMIT 1
    ) AS past ON true
    LEFT JOIN LATERAL (
        SELECT h.price, h.recorded_at
        FROM public.price_history AS h
        WHERE h.symbol = s.symbol
        ORDER BY h.recorded_at ASC, h.id ASC
        LIMIT 1
    ) AS oldest ON true
    ORDER BY s.symbol;
$$;

REVOKE ALL ON FUNCTION public.get_stock_24h_baselines() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_stock_24h_baselines() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.purge_price_history_retention()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _deleted INTEGER := 0;
BEGIN
    DELETE FROM public.price_history
    WHERE recorded_at < now() - INTERVAL '48 hours';
    GET DIAGNOSTICS _deleted = ROW_COUNT;
    RETURN _deleted;
END;
$$;

NOTIFY pgrst, 'reload schema';
