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

CREATE OR REPLACE FUNCTION public.admin_set_price(
    p_symbol VARCHAR(16),
    p_price NUMERIC
)
RETURNS SETOF public.stocks
LANGUAGE plpgsql
AS $$
DECLARE
    _new NUMERIC(18,4) := ROUND(GREATEST(0.05, p_price::numeric), 4);
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.stocks WHERE symbol = p_symbol) THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', p_symbol;
    END IF;

    WITH upd AS (
        UPDATE public.stocks
        SET
            current_price = _new,
            change = ROUND(_new - previous_close, 4),
            change_pct = ROUND(
                CASE WHEN previous_close = 0 THEN 0
                     ELSE ((_new - previous_close) / previous_close) * 100
                END, 4
            ),
            updated_at = now()
        WHERE symbol = p_symbol
        RETURNING symbol, current_price
    )
    INSERT INTO public.price_history (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM upd;

    RETURN QUERY SELECT * FROM public.stocks WHERE symbol = p_symbol LIMIT 1;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_price(VARCHAR(16), NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_price(VARCHAR(16), NUMERIC) TO authenticated;

NOTIFY pgrst, 'reload schema';
