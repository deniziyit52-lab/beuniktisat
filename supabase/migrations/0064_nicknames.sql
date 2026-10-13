-- Takma ad: isteyen oyuncu liderlik tablosunda gercek adi yerine sectigi takma adla gorunur.
-- Ilk secimden sonra en fazla 2 kez degistirilebilir. Gercek ad veritabaninda kalir; yonetici ikisini de gorur.

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS nickname TEXT;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS nickname_sets INTEGER NOT NULL DEFAULT 0;

CREATE UNIQUE INDEX IF NOT EXISTS users_nickname_unique ON public.users (lower(nickname)) WHERE nickname IS NOT NULL;

-- Oyuncu kendi takma adini belirler. Bos gonderilirse takma ad kaldirilir (hak harcamaz).
CREATE OR REPLACE FUNCTION public.set_nickname(p_nickname TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _nick TEXT := nullif(regexp_replace(btrim(coalesce(p_nickname, '')), '\s+', ' ', 'g'), '');
    _me public.users%ROWTYPE;
    _max CONSTANT INTEGER := 3;  -- ilk secim + 2 degisiklik
    _plain TEXT;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO _me FROM public.users WHERE id = _uid FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profil bulunamadı.';
    END IF;

    IF _nick IS NULL THEN
        UPDATE public.users SET nickname = NULL WHERE id = _uid;
        RETURN jsonb_build_object('nickname', NULL, 'remaining', GREATEST(_max - _me.nickname_sets, 0));
    END IF;

    IF _nick = _me.nickname THEN
        RETURN jsonb_build_object('nickname', _me.nickname, 'remaining', GREATEST(_max - _me.nickname_sets, 0));
    END IF;

    IF _me.nickname_sets >= _max THEN
        RAISE EXCEPTION 'Takma adını değiştirme hakkın kalmadı.';
    END IF;
    IF char_length(_nick) < 3 OR char_length(_nick) > 20 THEN
        RAISE EXCEPTION 'Takma ad 3 ile 20 karakter arasında olmalı.';
    END IF;
    IF _nick !~ '^[[:alnum:]çğıöşüÇĞİÖŞÜ._ -]+$' THEN
        RAISE EXCEPTION 'Takma adda yalnızca harf, rakam, boşluk, nokta, tire ve alt çizgi kullanılabilir.';
    END IF;

    -- Uygunsuz ve yaniltici adlar (kucuk harfe cevrilip bosluk ve isaretler atilarak bakilir).
    _plain := regexp_replace(lower(_nick), '[^[:alnum:]çğıöşü]', '', 'g');
    IF _plain ~ '(admin|yonetici|yönetici|moderator|hoca|rektor|rektör|dekan|amk|siktir|sikeyim|orospu|piç|yarrak|yarak|gavat|pezevenk|gotveren|götveren|ibne|kahpe|salak|gerizekali|gerizekalı)' THEN
        RAISE EXCEPTION 'Bu takma ad kullanılamaz; başka bir ad seç.';
    END IF;

    -- Baska bir oyuncunun gercek adi ya da takma adi alinamaz.
    IF EXISTS (
        SELECT 1 FROM public.users AS u
        WHERE u.id <> _uid
          AND (lower(u.nickname) = lower(_nick) OR lower(btrim(u.display_name)) = lower(_nick))
    ) THEN
        RAISE EXCEPTION 'Bu ad başka bir oyuncuya ait; başka bir ad seç.';
    END IF;

    UPDATE public.users
    SET nickname = _nick, nickname_sets = nickname_sets + 1
    WHERE id = _uid;

    RETURN jsonb_build_object('nickname', _nick, 'remaining', _max - _me.nickname_sets - 1);
END;
$$;

REVOKE ALL ON FUNCTION public.set_nickname(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_nickname(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_my_nickname()
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_build_object('nickname', u.nickname, 'remaining', GREATEST(3 - u.nickname_sets, 0))
    FROM public.users AS u
    WHERE u.id = auth.uid();
$$;

REVOKE ALL ON FUNCTION public.get_my_nickname() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_nickname() TO authenticated;

-- Liderlik: takma adi olan oyuncu onunla gorunur (0048'deki govde; yalnizca gosterilen ad degisti).
CREATE OR REPLACE FUNCTION public.get_leaderboard()
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
          coalesce(u.nickname, u.display_name)::TEXT AS display_name,
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

-- Yonetici: takma adi olan oyuncular (gercek ad ve e-posta ile) ve takma adi kaldirma.
CREATE OR REPLACE FUNCTION public.admin_list_nicknames()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    RETURN coalesce((
        SELECT jsonb_agg(jsonb_build_object('nickname', u.nickname, 'name', u.display_name, 'email', u.email)
                         ORDER BY lower(u.nickname))
        FROM public.users AS u
        WHERE u.nickname IS NOT NULL
    ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_nicknames() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_nicknames() TO authenticated;

-- Uygunsuz takma adi kaldirir; oyuncu gercek adiyla gorunur. Harcadigi hak geri verilmez.
CREATE OR REPLACE FUNCTION public.admin_clear_nickname(p_user_email TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    UPDATE public.users SET nickname = NULL
    WHERE lower(email) = lower(btrim(coalesce(p_user_email, ''))) AND nickname IS NOT NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Bu e-postada takma adı olan bir oyuncu bulunamadı.';
    END IF;
    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_clear_nickname(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_clear_nickname(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT 'Takma ad' AS konu,
       CASE WHEN to_regprocedure('public.set_nickname(text)') IS NOT NULL THEN 'kuruldu' ELSE 'KURULAMADI' END AS sonuc;
