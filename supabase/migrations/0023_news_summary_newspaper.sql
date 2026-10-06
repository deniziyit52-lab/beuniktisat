ALTER TABLE public.news_feed
    ADD COLUMN IF NOT EXISTS summary TEXT;

DROP FUNCTION IF EXISTS public.admin_publish_news(TEXT, VARCHAR(16), NUMERIC);

CREATE FUNCTION public.admin_publish_news(
    p_title TEXT,
    p_symbol VARCHAR(16),
    p_impact_pct NUMERIC,
    p_summary TEXT DEFAULT NULL
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

    INSERT INTO public.news_feed (id, title, summary, stock_symbol, impact_pct, created_at)
    VALUES (
        floor(extract(epoch FROM clock_timestamp()) * 1000000)::BIGINT,
        left(trim(p_title), 280),
        nullif(left(trim(coalesce(p_summary, '')), 500), ''),
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

REVOKE ALL ON FUNCTION public.admin_publish_news(TEXT, VARCHAR(16), NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_publish_news(TEXT, VARCHAR(16), NUMERIC, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
