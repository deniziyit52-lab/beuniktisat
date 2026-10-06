SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname IN (
    'borsa-every-15s-price-tick',
    'borsa-every-60s-price-tick'
)
OR position('batch_tick_market_prices' IN command) > 0;

SELECT cron.schedule(
    'borsa-every-60s-price-tick',
    '* * * * *',
    $$ SELECT public.batch_tick_market_prices(); $$
);

NOTIFY pgrst, 'reload schema';
