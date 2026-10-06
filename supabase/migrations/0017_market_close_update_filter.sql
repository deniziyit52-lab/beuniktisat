CREATE OR REPLACE FUNCTION public.set_market_open(p_is_market_open BOOLEAN)
RETURNS public.market_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _settings public.market_settings%ROWTYPE;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    IF p_is_market_open IS NULL THEN
        RAISE EXCEPTION 'Market open status must be specified.';
    END IF;

    SELECT *
    INTO _settings
    FROM public.market_settings
    WHERE id = 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'market_settings row id=1 is missing.';
    END IF;

    IF NOT p_is_market_open THEN
        UPDATE public.stocks
        SET previous_close = current_price,
            change = 0,
            change_pct = 0,
            updated_at = now()
        WHERE symbol IS NOT NULL;
    END IF;

    UPDATE public.market_settings
    SET is_market_open = p_is_market_open
    WHERE id = 1
    RETURNING * INTO _settings;

    RETURN _settings;
END;
$$;

NOTIFY pgrst, 'reload schema';
