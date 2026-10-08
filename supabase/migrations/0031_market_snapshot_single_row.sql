-- Butun hisse fiyatlari tek satirda (jsonb) yayinlanir: stocks tablosuna yapilan her yazma
-- komutu icin oyuncuya hisse sayisi kadar degil, tek bir realtime mesaji gider.
CREATE TABLE IF NOT EXISTS public.market_snapshot (
    id         INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    stocks     JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO public.market_snapshot (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.market_snapshot ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "market_snapshot herkes okur" ON public.market_snapshot;
CREATE POLICY "market_snapshot herkes okur"
    ON public.market_snapshot FOR SELECT USING (true);

REVOKE ALL ON public.market_snapshot FROM anon, authenticated;
GRANT SELECT ON public.market_snapshot TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.build_market_snapshot()
RETURNS JSONB
LANGUAGE SQL
SET search_path = public, pg_temp
AS $$
    SELECT coalesce(
        jsonb_agg(
            jsonb_build_object(
                'symbol', symbol,
                'name', name,
                'color', color,
                'current_price', current_price,
                'previous_close', previous_close,
                'change', change,
                'shares', shares,
                'risk_type', risk_type
            )
            ORDER BY symbol
        ),
        '[]'::jsonb
    )
    FROM public.stocks;
$$;

REVOKE ALL ON FUNCTION public.build_market_snapshot() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_market_snapshot()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _stocks JSONB := public.build_market_snapshot();
BEGIN
    -- Hicbir sey degismediyse satira dokunulmaz; bos yere realtime mesaji gitmez.
    UPDATE public.market_snapshot
    SET stocks = _stocks, updated_at = now()
    WHERE id = 1 AND stocks IS DISTINCT FROM _stocks;
    RETURN NULL;
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_market_snapshot() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_stocks_refresh_snapshot ON public.stocks;
CREATE TRIGGER trg_stocks_refresh_snapshot
    AFTER INSERT OR UPDATE OR DELETE ON public.stocks
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.refresh_market_snapshot();

UPDATE public.market_snapshot
SET stocks = public.build_market_snapshot(), updated_at = now()
WHERE id = 1;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'market_snapshot'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.market_snapshot;
    END IF;
END
$$;

NOTIFY pgrst, 'reload schema';

SELECT jsonb_array_length(stocks) AS hisse_sayisi, updated_at FROM public.market_snapshot;
