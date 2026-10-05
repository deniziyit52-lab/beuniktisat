DO $$
BEGIN
    IF to_regclass('public.stocks') IS NULL
       OR to_regclass('public.price_history') IS NULL
       OR to_regclass('public.news_feed') IS NULL THEN
        RAISE EXCEPTION 'Run migrations 0001 and 0002 first; stocks, price_history, and news_feed are required.';
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public.market_tips (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    message VARCHAR(280) NOT NULL,
    stock_symbol VARCHAR(16) NOT NULL,
    is_fake BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.market_tips ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_borsa_admin()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT lower(coalesce(auth.jwt() ->> 'email', '')) = 'deniziyit52@gmail.com';
$$;

REVOKE ALL ON FUNCTION public.is_borsa_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_borsa_admin() TO authenticated;

DO $$
DECLARE
    _policy RECORD;
BEGIN
    FOR _policy IN
        SELECT policyname
        FROM pg_policies
        WHERE schemaname = 'public' AND tablename = 'market_tips'
    LOOP
        EXECUTE format('DROP POLICY %I ON public.market_tips', _policy.policyname);
    END LOOP;
END
$$;

CREATE POLICY "market_tips_admin_manage"
    ON public.market_tips FOR ALL TO authenticated
    USING (public.is_borsa_admin())
    WITH CHECK (public.is_borsa_admin());

CREATE POLICY "market_tips_recipient_read"
    ON public.market_tips FOR SELECT TO authenticated
    USING (user_id = auth.uid());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.market_tips TO authenticated;
DO $$
DECLARE
    _sequence REGCLASS := pg_get_serial_sequence('public.market_tips', 'id')::regclass;
BEGIN
    IF _sequence IS NOT NULL THEN
        EXECUTE format('GRANT USAGE, SELECT ON SEQUENCE %s TO authenticated', _sequence);
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.admin_reset_market_prices()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    DELETE FROM public.news_feed;
    DELETE FROM public.market_tips;
    DELETE FROM public.price_history;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_market_prices() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_market_prices() TO authenticated;

NOTIFY pgrst, 'reload schema';
