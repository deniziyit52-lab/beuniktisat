CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'borsa-fetch-economy-news';

SELECT cron.schedule(
    'borsa-fetch-economy-news',
    '0 */2 * * *',
    $$
    SELECT net.http_post(
        url := 'https://zhjdbpokoyitvwlkncdd.supabase.co/functions/v1/fetch-economy-news',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', (
                SELECT decrypted_secret
                FROM vault.decrypted_secrets
                WHERE name = 'borsa_news_cron_secret'
            )
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 20000
    );
    $$
);
