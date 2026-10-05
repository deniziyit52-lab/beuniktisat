DO $$
BEGIN
    IF to_regclass('public.news_feed') IS NULL
       OR to_regclass('public.market_tips') IS NULL
       OR to_regclass('public.price_history') IS NULL THEN
        RAISE EXCEPTION 'Required reset tables are missing: news_feed, market_tips, price_history.';
    END IF;
END
$$;

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

    DELETE FROM public.news_feed;
    DELETE FROM public.market_tips;
    DELETE FROM public.price_history;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_market() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_market() TO authenticated;

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

REVOKE ALL ON FUNCTION public.admin_reset_market_prices() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_market_prices() TO authenticated;

NOTIFY pgrst, 'reload schema';
