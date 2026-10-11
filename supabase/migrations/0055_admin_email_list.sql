-- Yonetici paneli icin: e-posta ile bilgilendirmeye onay veren uyelerin listesi.
-- (0054 calistirilmadiysa gereken sutunlar burada da eklenir.)

ALTER TABLE public.users ADD COLUMN IF NOT EXISTS email_opt_in BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS email_opt_in_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.admin_list_email_opt_ins()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    RETURN jsonb_build_object(
        'total_members', (SELECT count(*) FROM public.users),
        'members', (
            SELECT coalesce(jsonb_agg(jsonb_build_object(
                'email', u.email,
                'name', u.display_name,
                'opted_at', u.email_opt_in_at
            ) ORDER BY u.email_opt_in_at DESC NULLS LAST), '[]'::jsonb)
            FROM public.users AS u
            WHERE u.email_opt_in AND coalesce(u.email, '') <> ''
        )
    );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_email_opt_ins() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_email_opt_ins() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT count(*) AS toplam_uye, count(*) FILTER (WHERE email_opt_in) AS eposta_onayi_veren
FROM public.users;
