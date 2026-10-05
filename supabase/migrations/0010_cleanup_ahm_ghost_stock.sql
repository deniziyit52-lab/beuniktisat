BEGIN;

-- Holdings are stored as JSONB on users in this project, not in a portfoy table.
UPDATE public.users
SET portfolio = coalesce(portfolio, '{}'::jsonb) - 'AHM'
WHERE coalesce(portfolio, '{}'::jsonb) ? 'AHM';

DELETE FROM public.transactions WHERE stock_symbol = 'AHM';
DELETE FROM public.market_tips WHERE stock_symbol = 'AHM';
DELETE FROM public.news_feed WHERE stock_symbol = 'AHM';
DELETE FROM public.price_history WHERE symbol = 'AHM';
DELETE FROM public.stocks WHERE symbol = 'AHM';

-- Failsafe: remove every JSONB holding whose symbol has no matching stock.
UPDATE public.users AS u
SET portfolio = coalesce((
    SELECT jsonb_object_agg(holding.key, holding.value)
    FROM jsonb_each(coalesce(u.portfolio, '{}'::jsonb)) AS holding(key, value)
    WHERE EXISTS (
        SELECT 1
        FROM public.stocks AS s
        WHERE s.symbol = holding.key
    )
), '{}'::jsonb)
WHERE jsonb_typeof(coalesce(u.portfolio, '{}'::jsonb)) = 'object'
  AND EXISTS (
      SELECT 1
      FROM jsonb_each(coalesce(u.portfolio, '{}'::jsonb)) AS holding(key, value)
      WHERE NOT EXISTS (
          SELECT 1 FROM public.stocks AS s WHERE s.symbol = holding.key
      )
  );

COMMIT;
