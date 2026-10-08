-- Admin yetkisi artik e-posta yerine admins tablosundan okunur.
CREATE TABLE IF NOT EXISTS public.admins (
    user_id    UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.admins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.admins FROM anon, authenticated;

INSERT INTO public.admins (user_id)
SELECT id FROM auth.users WHERE lower(email) = 'deniziyit52@gmail.com'
ON CONFLICT (user_id) DO NOTHING;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.admins) THEN
        RAISE EXCEPTION 'admins tablosu bos kaldi; yonetici hesabi bulunamadi. Hicbir sey degistirilmedi.';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.is_borsa_admin()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT EXISTS (SELECT 1 FROM public.admins WHERE user_id = auth.uid());
$$;

REVOKE ALL ON FUNCTION public.is_borsa_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_borsa_admin() TO authenticated;

-- E-postayi dogrudan kontrol eden iki fonksiyon is_borsa_admin() kullanacak sekilde yenilenir.
CREATE OR REPLACE FUNCTION public.admin_reset_market()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    DELETE FROM public.news_feed WHERE true;
    DELETE FROM public.market_tips WHERE true;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_market() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_market() TO authenticated;

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
    IF NOT public.is_borsa_admin() THEN
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

-- Hisse ekleme: admin paneli artik stocks tablosuna dogrudan yazmaz.
CREATE OR REPLACE FUNCTION public.admin_add_stock(
    p_symbol TEXT,
    p_name TEXT,
    p_price NUMERIC,
    p_color TEXT DEFAULT NULL
)
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _symbol TEXT := upper(trim(coalesce(p_symbol, '')));
    _name TEXT := trim(coalesce(p_name, ''));
    _price NUMERIC(18,4);
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF _symbol = '' OR _name = '' THEN
        RAISE EXCEPTION 'Sembol ve isim gerekli.';
    END IF;
    IF length(_symbol) > 16 OR length(_name) > 120 THEN
        RAISE EXCEPTION 'Sembol en fazla 16, isim en fazla 120 karakter olabilir.';
    END IF;
    IF p_price IS NULL OR p_price < 1 THEN
        RAISE EXCEPTION 'Baslangic fiyati en az 1 TL olmalidir.';
    END IF;
    IF EXISTS (SELECT 1 FROM public.stocks WHERE symbol = _symbol) THEN
        RAISE EXCEPTION 'Bu sembol zaten var: %', _symbol;
    END IF;

    _price := ROUND(p_price, 4);

    INSERT INTO public.stocks (symbol, name, color, current_price, previous_close, change, change_pct, shares)
    VALUES (_symbol, _name, coalesce(nullif(trim(p_color), ''), '#3b82f6'), _price, _price, 0, 0, 100000);

    INSERT INTO public.price_history (symbol, price, recorded_at)
    VALUES (_symbol, _price, now());

    RETURN QUERY SELECT * FROM public.stocks WHERE symbol = _symbol;
END;
$$;

-- Hisse duzenleme: yalnizca sembol ve isim degisir, fiyat degismez.
-- Sembol degisirse portfoyler, islem gecmisi ve grafik gecmisi yeni sembole tasinir.
CREATE OR REPLACE FUNCTION public.admin_edit_stock(
    p_old_symbol TEXT,
    p_new_symbol TEXT,
    p_new_name TEXT
)
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _old TEXT := upper(trim(coalesce(p_old_symbol, '')));
    _new TEXT := upper(trim(coalesce(p_new_symbol, '')));
    _name TEXT := trim(coalesce(p_new_name, ''));
    _stock public.stocks%ROWTYPE;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO _stock FROM public.stocks WHERE symbol = _old FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', _old;
    END IF;

    IF _new = '' THEN _new := _old; END IF;
    IF _name = '' THEN _name := _stock.name; END IF;
    IF length(_new) > 16 OR length(_name) > 120 THEN
        RAISE EXCEPTION 'Sembol en fazla 16, isim en fazla 120 karakter olabilir.';
    END IF;

    IF _new = _old THEN
        UPDATE public.stocks SET name = _name, updated_at = now() WHERE symbol = _old;
        RETURN QUERY SELECT * FROM public.stocks WHERE symbol = _old;
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM public.stocks WHERE symbol = _new) THEN
        RAISE EXCEPTION 'Yeni sembol zaten kullanimda: %', _new;
    END IF;

    INSERT INTO public.stocks
    SELECT * FROM jsonb_populate_record(
        NULL::public.stocks,
        to_jsonb(_stock) || jsonb_build_object('symbol', _new, 'name', _name, 'updated_at', now())
    );

    UPDATE public.price_history SET symbol = _new WHERE symbol = _old;
    UPDATE public.transactions SET stock_symbol = _new WHERE stock_symbol = _old;
    UPDATE public.news_feed SET stock_symbol = _new WHERE stock_symbol = _old;
    UPDATE public.market_tips SET stock_symbol = _new WHERE stock_symbol = _old;
    UPDATE public.users
    SET portfolio = (portfolio - _old) || jsonb_build_object(_new, portfolio -> _old)
    WHERE jsonb_typeof(portfolio) = 'object' AND portfolio ? _old;

    DELETE FROM public.stocks WHERE symbol = _old;

    RETURN QUERY SELECT * FROM public.stocks WHERE symbol = _new;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_stock(p_symbol TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _symbol TEXT := upper(trim(coalesce(p_symbol, '')));
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    DELETE FROM public.stocks WHERE symbol = _symbol;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', _symbol;
    END IF;

    RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_maintenance(p_enabled BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.app_settings (id, maintenance_mode, updated_at)
    VALUES (1, coalesce(p_enabled, false), now())
    ON CONFLICT (id) DO UPDATE
    SET maintenance_mode = EXCLUDED.maintenance_mode,
        updated_at = EXCLUDED.updated_at;

    RETURN coalesce(p_enabled, false);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_add_stock(TEXT, TEXT, NUMERIC, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_edit_stock(TEXT, TEXT, TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_delete_stock(TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_maintenance(BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_add_stock(TEXT, TEXT, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_edit_stock(TEXT, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_stock(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_maintenance(BOOLEAN) TO authenticated;

-- Bu tablolara artik yalnizca fonksiyonlar yazar; dogrudan yazma yolu tamamen kapatilir.
DROP POLICY IF EXISTS "stocks admin yonetebilir" ON public.stocks;
DROP POLICY IF EXISTS "price_history admin yonetebilir" ON public.price_history;
DROP POLICY IF EXISTS "news_feed admin yonetebilir" ON public.news_feed;
DROP POLICY IF EXISTS "app_settings admin yonetebilir" ON public.app_settings;
DROP POLICY IF EXISTS "market_settings_admin_update" ON public.market_settings;

REVOKE INSERT, UPDATE, DELETE, TRUNCATE
    ON public.stocks, public.price_history, public.news_feed, public.app_settings, public.market_settings
    FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';
