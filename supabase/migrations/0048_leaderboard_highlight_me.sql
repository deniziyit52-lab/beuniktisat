-- Liderlik: oyuncunun kendi satiri isaretlenir (is_me). Ilk 10'da degilse kendi sirasi da listeye eklenir.
-- Donus tipi degistigi icin fonksiyon yeniden olusturulur.

ALTER TABLE public.user_badges
    ADD COLUMN IF NOT EXISTS featured BOOLEAN NOT NULL DEFAULT false;

DROP FUNCTION IF EXISTS public.get_leaderboard();

CREATE FUNCTION public.get_leaderboard()
RETURNS TABLE(
    rank_id BIGINT,
    display_name TEXT,
    balance NUMERIC,
    stocks_value NUMERIC,
    total_net_worth NUMERIC,
    starting_balance NUMERIC,
    return_pct NUMERIC,
    badges TEXT[],
    is_me BOOLEAN
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH ranked AS (
      SELECT
          ROW_NUMBER() OVER (ORDER BY r.return_pct DESC, u.id ASC) AS rank_id,
          u.id,
          u.display_name::TEXT AS display_name,
          u.balance,
          u.starting_balance,
          r.wealth,
          r.return_pct
      FROM public.user_returns() AS r
      JOIN public.users AS u ON u.id = r.user_id
      -- Yalnizca en az bir islem yapmis oyuncular siralanir.
      WHERE EXISTS (SELECT 1 FROM public.transactions AS t WHERE t.user_id = u.id)
         OR EXISTS (SELECT 1 FROM public.asset_transactions AS a WHERE a.user_id = u.id)
  )
  SELECT
      k.rank_id,
      k.display_name,
      k.balance,
      ROUND(k.wealth - k.balance, 2),
      ROUND(k.wealth, 2),
      k.starting_balance,
      ROUND(k.return_pct, 2),
      COALESCE(
          (SELECT array_agg(f.badge ORDER BY f.earned_at)
           FROM public.user_badges AS f
           WHERE f.user_id = k.id AND f.featured),
          (SELECT array_agg(d.badge ORDER BY d.earned_at)
           FROM (
               SELECT b.badge, b.earned_at
               FROM public.user_badges AS b
               WHERE b.user_id = k.id
               ORDER BY b.earned_at
               LIMIT 3
           ) AS d),
          ARRAY[]::TEXT[]
      ),
      coalesce(k.id = auth.uid(), false)
  FROM ranked AS k
  WHERE k.rank_id <= 10 OR k.id = auth.uid()
  ORDER BY k.rank_id;
$$;

REVOKE ALL ON FUNCTION public.get_leaderboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_leaderboard() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

SELECT rank_id AS sira, display_name AS oyuncu, return_pct AS getiri_yuzde
FROM public.get_leaderboard();
