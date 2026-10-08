-- Grafikte 1 hafta / 1 ay gorunumleri icin saatlik fiyat arsivi.
-- Dakikalik gecmis (price_history) 48 saat tutuluyor; uzun donem icin saat basi tek nokta saklanir.

CREATE TABLE IF NOT EXISTS public.price_history_hourly (
    id          BIGSERIAL PRIMARY KEY,
    symbol      VARCHAR(16) NOT NULL REFERENCES public.stocks(symbol) ON UPDATE CASCADE ON DELETE CASCADE,
    price       NUMERIC(18,4) NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_price_history_hourly_symbol_time
    ON public.price_history_hourly (symbol, recorded_at);

ALTER TABLE public.price_history_hourly ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "price_history_hourly herkes okur" ON public.price_history_hourly;
CREATE POLICY "price_history_hourly herkes okur"
    ON public.price_history_hourly FOR SELECT USING (true);

REVOKE ALL ON public.price_history_hourly FROM anon, authenticated;
GRANT SELECT ON public.price_history_hourly TO anon, authenticated;

-- Saat basi calisir: piyasa aciksa her hissenin o anki fiyatini kaydeder, 90 gunden eskiyi siler.
CREATE OR REPLACE FUNCTION public.record_hourly_prices()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _count INTEGER := 0;
BEGIN
    IF EXISTS (SELECT 1 FROM public.market_settings WHERE id = 1 AND is_market_open) THEN
        INSERT INTO public.price_history_hourly (symbol, price, recorded_at)
        SELECT symbol, current_price, now() FROM public.stocks;
        GET DIAGNOSTICS _count = ROW_COUNT;
    END IF;

    DELETE FROM public.price_history_hourly
    WHERE recorded_at < now() - INTERVAL '90 days';

    RETURN _count;
END;
$$;

REVOKE ALL ON FUNCTION public.record_hourly_prices() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'borsa-hourly-prices';

SELECT cron.schedule(
    'borsa-hourly-prices',
    '0 * * * *',
    $$ SELECT public.record_hourly_prices(); $$
);

-- Elde olan son 48 saatlik dakikalik gecmisten saatlik noktalar uretilir (her saatin ilk kaydi).
INSERT INTO public.price_history_hourly (symbol, price, recorded_at)
SELECT DISTINCT ON (h.symbol, date_trunc('hour', h.recorded_at))
       h.symbol, h.price, date_trunc('hour', h.recorded_at)
FROM public.price_history AS h
JOIN public.stocks AS s ON s.symbol = h.symbol
WHERE NOT EXISTS (SELECT 1 FROM public.price_history_hourly)
ORDER BY h.symbol, date_trunc('hour', h.recorded_at), h.recorded_at;

-- Oyunu sifirlama: saatlik arsiv ve bekleyen fiyat etkisi de temizlenir.
CREATE OR REPLACE FUNCTION public.admin_reset_game()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _users INTEGER;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    UPDATE public.users
    SET balance = 100000,
        starting_balance = 100000,
        portfolio = '{}'::jsonb,
        assets = '{}'::jsonb
    WHERE true;
    GET DIAGNOSTICS _users = ROW_COUNT;

    DELETE FROM public.transactions WHERE true;
    DELETE FROM public.asset_transactions WHERE true;
    DELETE FROM public.quiz_attempts WHERE true;
    DELETE FROM public.market_tips WHERE true;
    DELETE FROM public.news_feed WHERE true;
    DELETE FROM public.price_history WHERE true;
    DELETE FROM public.price_history_hourly WHERE true;

    UPDATE public.stocks
    SET previous_close = current_price,
        change = 0,
        change_pct = 0,
        vol_mult = 1,
        breaker_ref = current_price,
        halt_until = NULL,
        impact_pending = 0,
        updated_at = now()
    WHERE symbol IS NOT NULL;

    UPDATE public.market_settings
    SET halt_until = NULL, halt_level = 0
    WHERE id = 1;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM public.stocks;

    INSERT INTO public.price_history_hourly (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM public.stocks;

    RETURN jsonb_build_object('users', _users);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_game() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_game() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT count(*) AS saatlik_nokta_sayisi, min(recorded_at) AS en_eski, max(recorded_at) AS en_yeni
FROM public.price_history_hourly;
