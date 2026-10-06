-- Keep the news feed as a permanent archive, including during market resets.
CREATE OR REPLACE FUNCTION public.purge_price_history_retention()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _deleted INTEGER := 0;
BEGIN
    DELETE FROM public.price_history
    WHERE recorded_at < now() - INTERVAL '48 hours';
    GET DIAGNOSTICS _deleted = ROW_COUNT;
    RETURN _deleted;
END;
$$;

REVOKE ALL ON FUNCTION public.purge_price_history_retention() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_reset_market()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF lower(coalesce(auth.jwt() ->> 'email', '')) <> 'deniziyit52@gmail.com' THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    DELETE FROM public.market_tips;
    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reset_market_prices()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    RETURN public.admin_reset_market();
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_market() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_market() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_reset_market_prices() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_market_prices() TO authenticated;
