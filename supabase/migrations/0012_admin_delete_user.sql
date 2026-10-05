CREATE OR REPLACE FUNCTION public.admin_delete_user(p_user_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    _email TEXT := lower(trim(coalesce(p_user_email, '')));
    _target_user_id UUID;
    _matches INTEGER;
BEGIN
    IF lower(coalesce(auth.jwt() ->> 'email', '')) <> 'deniziyit52@gmail.com' THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    IF _email = '' THEN
        RAISE EXCEPTION 'Kullanici e-posta adresi gerekli.';
    END IF;

    SELECT count(*) INTO _matches
    FROM auth.users
    WHERE lower(email) = _email;

    IF _matches = 0 THEN
        RAISE EXCEPTION 'Bu e-posta ile kullanici bulunamadi.';
    ELSIF _matches > 1 THEN
        RAISE EXCEPTION 'Bu e-posta birden fazla kullaniciya ait; silme iptal edildi.';
    END IF;

    SELECT id INTO _target_user_id
    FROM auth.users
    WHERE lower(email) = _email
    FOR UPDATE;

    IF _target_user_id = auth.uid() THEN
        RAISE EXCEPTION 'Yonetici hesabi bu panelden silinemez.';
    END IF;

    DELETE FROM public.transactions WHERE user_id = _target_user_id;
    DELETE FROM public.market_tips WHERE user_id = _target_user_id;
    DELETE FROM public.users WHERE id = _target_user_id;
    DELETE FROM auth.users WHERE id = _target_user_id;

    RETURN jsonb_build_object(
        'user_id', _target_user_id,
        'email', _email,
        'deleted', true
    );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_user(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_user(TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
