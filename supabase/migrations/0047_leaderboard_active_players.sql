-- Liderlik tablosunda yalnizca en az bir islem yapmis oyuncular yer alir.
-- Onceden hic islem yapmayan oyuncular %0 getiriyle tabloyu dolduruyor, komisyon yuzunden
-- getirisi eksi birkac kurus olan aktif oyuncu ilk 10'a giremiyordu.

ALTER TABLE public.user_badges
    ADD COLUMN IF NOT EXISTS featured BOOLEAN NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.get_leaderboard()
RETURNS TABLE(
    rank_id BIGINT,
    display_name TEXT,
    balance NUMERIC,
    stocks_value NUMERIC,
    total_net_worth NUMERIC,
    starting_balance NUMERIC,
    return_pct NUMERIC,
    badges TEXT[]
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
      ROW_NUMBER() OVER (ORDER BY r.return_pct DESC, u.id ASC),
      u.display_name::TEXT,
      u.balance,
      ROUND(r.wealth - u.balance, 2),
      ROUND(r.wealth, 2),
      u.starting_balance,
      ROUND(r.return_pct, 2),
      COALESCE(
          (SELECT array_agg(f.badge ORDER BY f.earned_at)
           FROM public.user_badges AS f
           WHERE f.user_id = u.id AND f.featured),
          (SELECT array_agg(d.badge ORDER BY d.earned_at)
           FROM (
               SELECT b.badge, b.earned_at
               FROM public.user_badges AS b
               WHERE b.user_id = u.id
               ORDER BY b.earned_at
               LIMIT 3
           ) AS d),
          ARRAY[]::TEXT[]
      )
  FROM public.user_returns() AS r
  JOIN public.users AS u ON u.id = r.user_id
  WHERE EXISTS (SELECT 1 FROM public.transactions AS t WHERE t.user_id = u.id)
     OR EXISTS (SELECT 1 FROM public.asset_transactions AS a WHERE a.user_id = u.id)
  ORDER BY r.return_pct DESC, u.id ASC
  LIMIT 10;
$$;

REVOKE ALL ON FUNCTION public.get_leaderboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_leaderboard() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

-- Kontrol: islem yapmis butun oyuncular, getiri sirasina gore.
SELECT ROW_NUMBER() OVER (ORDER BY r.return_pct DESC, u.id) AS sira,
       u.display_name AS oyuncu,
       u.balance AS nakit,
       ROUND(r.wealth - u.balance, 2) AS varliklar,
       ROUND(r.wealth, 2) AS toplam,
       u.starting_balance AS baslangic,
       ROUND(r.return_pct, 3) AS getiri_yuzde
FROM public.user_returns() AS r
JOIN public.users AS u ON u.id = r.user_id
WHERE EXISTS (SELECT 1 FROM public.transactions AS t WHERE t.user_id = u.id)
   OR EXISTS (SELECT 1 FROM public.asset_transactions AS a WHERE a.user_id = u.id)
ORDER BY r.return_pct DESC, u.id;
