CREATE EXTENSION IF NOT EXISTS pg_cron;

ALTER TABLE public.stocks REPLICA IDENTITY FULL;
CREATE INDEX IF NOT EXISTS idx_price_history_symbol_time
    ON public.price_history (symbol ASC, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_price_history_time
    ON public.price_history (recorded_at DESC);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'stocks'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.stocks;
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.batch_tick_market_prices()
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _updated_count INTEGER := 0;
BEGIN
    WITH next_prices AS (
        SELECT
            s.symbol,
            GREATEST(
                0.05::numeric,
                ROUND(
                    s.current_price * (
                        1 + (CASE WHEN random() < 0.5 THEN -1::numeric ELSE 1::numeric END)
                          * (0.01::numeric + random()::numeric * 0.02::numeric)
                    ),
                    4
                )
            ) AS new_price
        FROM public.stocks s
    ),
    updated AS (
        UPDATE public.stocks s
        SET
            current_price = np.new_price,
            change = ROUND(np.new_price - s.previous_close, 4),
            change_pct = ROUND(
                CASE WHEN s.previous_close = 0 THEN 0
                     ELSE ((np.new_price - s.previous_close) / s.previous_close) * 100
                END,
                4
            ),
            updated_at = now()
        FROM next_prices np
        WHERE s.symbol = np.symbol
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
    WHERE recorded_at < now() - INTERVAL '24 hours';

    RETURN QUERY
    SELECT * FROM public.stocks ORDER BY symbol;
END;
$$;

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
    WHERE recorded_at < now() - INTERVAL '24 hours';
    GET DIAGNOSTICS _deleted = ROW_COUNT;
    RETURN _deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.batch_tick_market_prices() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.purge_price_history_retention() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname IN (
    'borsa-every-15s-price-tick',
    'borsa-every-10m-retention'
);

SELECT cron.schedule(
    'borsa-every-15s-price-tick',
    '15 seconds',
    $$ SELECT public.batch_tick_market_prices(); $$
);

SELECT cron.schedule(
    'borsa-every-10m-retention',
    '*/10 * * * *',
    $$ SELECT public.purge_price_history_retention(); $$
);

NOTIFY pgrst, 'reload schema';
