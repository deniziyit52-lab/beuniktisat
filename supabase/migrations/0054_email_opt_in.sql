-- Istege bagli e-posta bilgilendirme onayi: kayit sirasinda isaretlenirse oyuncunun satirina yazilir.

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS email_opt_in BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS email_opt_in_at TIMESTAMPTZ;

-- Oyuncu kendi e-posta bilgilendirme tercihini kaydeder (onay verir ya da geri alir).
CREATE OR REPLACE FUNCTION public.set_email_opt_in(p_opt_in BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _value BOOLEAN := coalesce(p_opt_in, false);
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    UPDATE public.users
    SET email_opt_in = _value,
        email_opt_in_at = CASE WHEN _value THEN now() ELSE NULL END
    WHERE id = _uid;

    IF NOT FOUND THEN
        -- Profil satiri henuz olusmadiysa once olusturulur.
        PERFORM public.ensure_profile();
        UPDATE public.users
        SET email_opt_in = _value,
            email_opt_in_at = CASE WHEN _value THEN now() ELSE NULL END
        WHERE id = _uid;
    END IF;

    RETURN _value;
END;
$$;

REVOKE ALL ON FUNCTION public.set_email_opt_in(BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_email_opt_in(BOOLEAN) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT count(*) AS toplam_uye, count(*) FILTER (WHERE email_opt_in) AS eposta_onayi_veren
FROM public.users;
