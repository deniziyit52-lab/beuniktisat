-- Oyuncu, kazandigi rozetlerden en fazla 3 tanesini liderlik tablosunda adinin yaninda gosterebilir.
-- Secim yapmayan oyuncuda ilk kazandigi 3 rozet gosterilir.
-- (Once 0045_badges.sql calistirilmis olmali.)

ALTER TABLE public.user_badges
    ADD COLUMN IF NOT EXISTS featured BOOLEAN NOT NULL DEFAULT false;

-- Rozet listesi artik "liderlikte gosteriliyor mu" bilgisini de doner.
CREATE OR REPLACE FUNCTION public.get_my_badges()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    PERFORM public.evaluate_badges(_uid);

    RETURN (
        SELECT coalesce(
            jsonb_agg(jsonb_build_object(
                'badge', b.badge,
                'earned_at', b.earned_at,
                'featured', b.featured
            ) ORDER BY b.earned_at),
            '[]'::jsonb
        )
        FROM public.user_badges AS b
        WHERE b.user_id = _uid
    );
END;
$$;

-- Liderlikte gosterilecek rozetleri kaydeder: yalnizca oyuncunun kazandigi rozetler, en fazla 3.
CREATE OR REPLACE FUNCTION public.set_featured_badges(p_badges TEXT[])
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _wanted TEXT[];
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT coalesce(array_agg(DISTINCT x), ARRAY[]::TEXT[])
    INTO _wanted
    FROM unnest(coalesce(p_badges, ARRAY[]::TEXT[])) AS x;

    IF array_length(_wanted, 1) > 3 THEN
        RAISE EXCEPTION 'Liderlikte en fazla 3 rozet gösterebilirsin.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM unnest(_wanted) AS w
        WHERE NOT EXISTS (
            SELECT 1 FROM public.user_badges AS b WHERE b.user_id = _uid AND b.badge = w
        )
    ) THEN
        RAISE EXCEPTION 'Yalnızca kazandığın rozetleri gösterebilirsin.';
    END IF;

    UPDATE public.user_badges
    SET featured = (badge = ANY(_wanted))
    WHERE user_id = _uid;

    RETURN public.get_my_badges();
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_badges() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_featured_badges(TEXT[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_badges() TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_featured_badges(TEXT[]) TO authenticated;

-- Liderlik: oyuncunun sectigi rozetler; secim yoksa ilk kazandigi 3 rozet.
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
  ORDER BY r.return_pct DESC, u.id ASC
  LIMIT 10;
$$;

REVOKE ALL ON FUNCTION public.get_leaderboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_leaderboard() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

SELECT count(*) AS toplam_rozet, count(*) FILTER (WHERE featured) AS liderlikte_gosterilen
FROM public.user_badges;
