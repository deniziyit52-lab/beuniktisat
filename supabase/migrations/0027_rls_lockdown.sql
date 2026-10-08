DO $$
BEGIN
    IF to_regclass('public.users') IS NULL
       OR to_regclass('public.transactions') IS NULL
       OR to_regclass('public.market_tips') IS NULL THEN
        RAISE EXCEPTION 'users, transactions ve market_tips tablolari gerekli.';
    END IF;
END
$$;

-- stocks: panelden elle eklenmis "herkes yazar" kurallari kaldirilir.
-- Kalanlar: "stocks anon herkes okuyabilir" (SELECT) ve "stocks admin yonetebilir" (ALL).
DROP POLICY IF EXISTS "stocks_insert_all" ON public.stocks;
DROP POLICY IF EXISTS "stocks_update_all" ON public.stocks;
DROP POLICY IF EXISTS "stocks_delete_all" ON public.stocks;
DROP POLICY IF EXISTS "stocks_select_all" ON public.stocks;
DROP POLICY IF EXISTS "stocks_write_authenticated" ON public.stocks;

-- app_settings: kalanlar "app_settings herkes okur" ve "app_settings admin yonetebilir".
DROP POLICY IF EXISTS "app_settings_insert_all" ON public.app_settings;
DROP POLICY IF EXISTS "app_settings_update_all" ON public.app_settings;
DROP POLICY IF EXISTS "app_settings_delete_all" ON public.app_settings;
DROP POLICY IF EXISTS "app_settings_select_all" ON public.app_settings;
DROP POLICY IF EXISTS "app_settings_write_authn" ON public.app_settings;

-- users: herkes yalnizca kendi satirini okur. Yazma sadece SECURITY DEFINER RPC ile.
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "users_insert_self" ON public.users;
DROP POLICY IF EXISTS "users_update_self" ON public.users;
DROP POLICY IF EXISTS "users_select_self" ON public.users;
DROP POLICY IF EXISTS "users_read_own" ON public.users;
CREATE POLICY "users_read_own"
    ON public.users FOR SELECT TO authenticated
    USING (id = auth.uid());

REVOKE ALL ON public.users FROM anon, authenticated;
GRANT SELECT ON public.users TO authenticated;

-- transactions: herkes yalnizca kendi islemlerini okur. Yazma sadece execute_hybrid_trade ile.
ALTER TABLE public.transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tx_insert_self" ON public.transactions;
DROP POLICY IF EXISTS "tx_select_self" ON public.transactions;
DROP POLICY IF EXISTS "transactions_read_own" ON public.transactions;
CREATE POLICY "transactions_read_own"
    ON public.transactions FOR SELECT TO authenticated
    USING (user_id = auth.uid());

REVOKE ALL ON public.transactions FROM anon, authenticated;
GRANT SELECT ON public.transactions TO authenticated;

-- market_tips: kurallar 0006'da tanimli (admin yonetir, alici kendi tuyosunu okur).
ALTER TABLE public.market_tips ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.market_tips FROM anon;

-- Yeni uyenin profil satirini sunucu olusturur; bakiye istemciden gelmez.
CREATE OR REPLACE FUNCTION public.ensure_profile()
RETURNS SETOF public.users
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.users (id, email, display_name, balance, portfolio)
    SELECT
        account.id,
        coalesce(account.email, ''),
        coalesce(nullif(account.raw_user_meta_data ->> 'full_name', ''), account.email, ''),
        100000,
        '{}'::jsonb
    FROM auth.users AS account
    WHERE account.id = _uid
    ON CONFLICT (id) DO NOTHING;

    RETURN QUERY SELECT * FROM public.users WHERE id = _uid;
END;
$$;

REVOKE ALL ON FUNCTION public.ensure_profile() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.ensure_profile() TO authenticated;

NOTIFY pgrst, 'reload schema';
