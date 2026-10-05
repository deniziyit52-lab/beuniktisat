DO $$
BEGIN
    IF to_regclass('public.stocks') IS NULL
       OR to_regclass('public.price_history') IS NULL
       OR to_regclass('public.news_feed') IS NULL
       OR to_regclass('public.app_settings') IS NULL THEN
        RAISE EXCEPTION 'Run migrations 0001_enable_realtime_stocks.sql and 0002_centralized_price_engine.sql first.';
    END IF;
END
$$;

CREATE OR REPLACE FUNCTION public.is_borsa_admin()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
AS $$
    SELECT lower(coalesce(auth.jwt() ->> 'email', '')) = 'deniziyit52@gmail.com';
$$;

REVOKE ALL ON FUNCTION public.is_borsa_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_borsa_admin() TO authenticated;

DROP POLICY IF EXISTS "stocks auth kullanici degistirebilir" ON public.stocks;
DROP POLICY IF EXISTS "stocks admin yonetebilir" ON public.stocks;
CREATE POLICY "stocks admin yonetebilir"
    ON public.stocks FOR ALL TO authenticated
    USING (public.is_borsa_admin())
    WITH CHECK (public.is_borsa_admin());

DROP POLICY IF EXISTS "price_history admin yazar" ON public.price_history;
DROP POLICY IF EXISTS "price_history admin yonetebilir" ON public.price_history;
CREATE POLICY "price_history admin yonetebilir"
    ON public.price_history FOR ALL TO authenticated
    USING (public.is_borsa_admin())
    WITH CHECK (public.is_borsa_admin());

DROP POLICY IF EXISTS "news_feed auth yazar" ON public.news_feed;
DROP POLICY IF EXISTS "news_feed admin yonetebilir" ON public.news_feed;
CREATE POLICY "news_feed admin yonetebilir"
    ON public.news_feed FOR ALL TO authenticated
    USING (public.is_borsa_admin())
    WITH CHECK (public.is_borsa_admin());

DROP POLICY IF EXISTS "app_settings auth gunceller" ON public.app_settings;
DROP POLICY IF EXISTS "app_settings admin yonetebilir" ON public.app_settings;
CREATE POLICY "app_settings admin yonetebilir"
    ON public.app_settings FOR ALL TO authenticated
    USING (public.is_borsa_admin())
    WITH CHECK (public.is_borsa_admin());

GRANT SELECT ON public.stocks, public.price_history, public.news_feed, public.app_settings TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.stocks, public.app_settings TO authenticated;

DROP FUNCTION IF EXISTS public.admin_publish_news(TEXT, VARCHAR(16), NUMERIC);
DROP FUNCTION IF EXISTS public.admin_set_stock_price(VARCHAR(16), NUMERIC);
DROP FUNCTION IF EXISTS public.admin_apply_news_impact(VARCHAR(16), NUMERIC);
DROP FUNCTION IF EXISTS public.admin_reset_market_prices();

CREATE FUNCTION public.admin_apply_news_impact(
    p_symbol VARCHAR(16),
    p_impact_pct NUMERIC
)
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _symbol VARCHAR(16) := upper(trim(p_symbol));
    _old_price NUMERIC(18,4);
    _previous_close NUMERIC(18,4);
    _new_price NUMERIC(18,4);
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT current_price, previous_close
    INTO _old_price, _previous_close
    FROM public.stocks
    WHERE symbol = _symbol
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', p_symbol;
    END IF;

    _new_price := ROUND(GREATEST(0.05, _old_price * (1 + coalesce(p_impact_pct, 0) / 100)), 4);

    UPDATE public.stocks
    SET current_price = _new_price,
        change = ROUND(_new_price - _previous_close, 4),
        change_pct = ROUND(
            CASE WHEN _previous_close = 0 THEN 0
                 ELSE ((_new_price - _previous_close) / _previous_close) * 100
            END,
            4
        ),
        updated_at = now()
    WHERE symbol = _symbol;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    VALUES (_symbol, _new_price, now());

    RETURN QUERY SELECT * FROM public.stocks WHERE symbol = _symbol;
END;
$$;

CREATE FUNCTION public.admin_set_stock_price(
    p_symbol VARCHAR(16),
    p_price NUMERIC
)
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _symbol VARCHAR(16) := upper(trim(p_symbol));
    _new_price NUMERIC(18,4);
    _previous_close NUMERIC(18,4);
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF p_price IS NULL OR p_price < 0.05 THEN
        RAISE EXCEPTION 'Fiyat en az 0.05 olmalidir.';
    END IF;

    _new_price := ROUND(p_price, 4);
    UPDATE public.stocks
    SET current_price = _new_price,
        change = ROUND(_new_price - previous_close, 4),
        change_pct = ROUND(
            CASE WHEN previous_close = 0 THEN 0
                 ELSE ((_new_price - previous_close) / previous_close) * 100
            END,
            4
        ),
        updated_at = now()
    WHERE symbol = _symbol
    RETURNING previous_close INTO _previous_close;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', p_symbol;
    END IF;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    VALUES (_symbol, _new_price, now());

    RETURN QUERY SELECT * FROM public.stocks WHERE symbol = _symbol;
END;
$$;

CREATE FUNCTION public.admin_publish_news(
    p_title TEXT,
    p_symbol VARCHAR(16),
    p_impact_pct NUMERIC
)
RETURNS public.news_feed
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _news public.news_feed;
    _symbol VARCHAR(16) := nullif(upper(trim(p_symbol)), '');
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF nullif(trim(p_title), '') IS NULL THEN
        RAISE EXCEPTION 'Haber basligi bos olamaz.';
    END IF;
    IF _symbol IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.stocks WHERE symbol = _symbol
    ) THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', _symbol;
    END IF;

    INSERT INTO public.news_feed (id, title, stock_symbol, impact_pct, created_at)
    VALUES (
        floor(extract(epoch FROM clock_timestamp()) * 1000000)::BIGINT,
        left(trim(p_title), 280),
        _symbol,
        coalesce(p_impact_pct, 0),
        now()
    )
    RETURNING * INTO _news;

    IF _symbol IS NOT NULL AND coalesce(p_impact_pct, 0) <> 0 THEN
        PERFORM public.admin_apply_news_impact(_symbol, p_impact_pct);
    END IF;

    RETURN _news;
END;
$$;

CREATE FUNCTION public.admin_reset_market_prices()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    UPDATE public.stocks
    SET current_price = previous_close,
        change = 0,
        change_pct = 0,
        updated_at = now();

    DELETE FROM public.price_history;
    INSERT INTO public.price_history (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM public.stocks;

    DELETE FROM public.news_feed;
    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_apply_news_impact(VARCHAR(16), NUMERIC) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_stock_price(VARCHAR(16), NUMERIC) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_publish_news(TEXT, VARCHAR(16), NUMERIC) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_reset_market_prices() FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_apply_news_impact(VARCHAR(16), NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_stock_price(VARCHAR(16), NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_publish_news(TEXT, VARCHAR(16), NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_reset_market_prices() TO authenticated;

NOTIFY pgrst, 'reload schema';
