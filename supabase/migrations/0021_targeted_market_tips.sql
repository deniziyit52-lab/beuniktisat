DO $$
BEGIN
    IF to_regclass('public.market_tips') IS NULL
       OR to_regclass('public.users') IS NULL THEN
        RAISE EXCEPTION 'Run the market_tips and users migrations first.';
    END IF;
END
$$;

ALTER TABLE public.market_tips
    ADD COLUMN IF NOT EXISTS target_user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE;

CREATE INDEX IF NOT EXISTS idx_market_tips_target_user_id
    ON public.market_tips (target_user_id);

CREATE OR REPLACE FUNCTION public.admin_list_whisper_users()
RETURNS TABLE(id UUID, display_name TEXT, email TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
STABLE
SET search_path = public, auth, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT
        account.id,
        coalesce(
            nullif(profile.display_name, ''),
            nullif(account.raw_user_meta_data ->> 'full_name', ''),
            account.email
        )::TEXT,
        account.email::TEXT
    FROM auth.users AS account
    LEFT JOIN public.users AS profile ON profile.id = account.id
    ORDER BY 2, 3;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_whisper_users() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_whisper_users() TO authenticated;

NOTIFY pgrst, 'reload schema';
