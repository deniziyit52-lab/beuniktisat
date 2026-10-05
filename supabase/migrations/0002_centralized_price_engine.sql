-- =========================================================================
--  BORSA SIMULASYONU - 0002_centralized_price_engine.sql
--  MERKEZI FIYAT MOTORU: Supabase icinde, frontend OFFLOAD
--  Ucretsiz plan icin 3 ONEMLI OPTIMIZASYON:
--    [1] Guncelleme sikligi: HER 15 SANiYE (1s yerine 15s, 15x daha az yazma)
--    [2] Toplu islem (Batch): TEK UPDATE + CASE (her hisse icin ayri sorgu YOK)
--    [3] Saklama (Retention): price_history tablosunda hisse basi SON 100 kayit
-- =========================================================================
--  Calistirilma yeri: Supabase Dashboard > SQL Editor > New Query
--  ONEMLI: Once 0001_enable_realtime_stocks.sql calistigindan emin ol.
-- =========================================================================

-- =========================================================================
--  [ADIM 0/6] pg_cron extension yukle (Supabase ucretsiz planda VAR)
-- =========================================================================
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA extensions;
GRANT ALL ON SCHEMA cron TO postgres;
GRANT ALL ON SCHEMA cron TO supabase_admin;

-- =========================================================================
--  [ADIM 1/6] price_history tablosunu OLUSTUR (eski JSONB price_history yerine)
--         : Boylece satir satir ROW LEVEL, indeksli, retention temizligi kolay
-- =========================================================================
CREATE TABLE IF NOT EXISTS public.price_history (
    id          BIGSERIAL PRIMARY KEY,
    symbol      VARCHAR(16)   NOT NULL,
    price       NUMERIC(18,4) NOT NULL,
    recorded_at TIMESTAMPTZ   NOT NULL DEFAULT now()
);

ALTER TABLE public.price_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.price_history REPLICA IDENTITY FULL;

CREATE INDEX IF NOT EXISTS idx_price_history_symbol_time
    ON public.price_history (symbol ASC, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_price_history_time
    ON public.price_history (recorded_at DESC);

DROP POLICY IF EXISTS "price_history herkes okur" ON public.price_history;
CREATE POLICY "price_history herkes okur"
    ON public.price_history FOR SELECT USING (true);

DROP POLICY IF EXISTS "price_history admin yazar" ON public.price_history;
CREATE POLICY "price_history admin yazar"
    ON public.price_history FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

-- Publication'a ekle (frontend yeni fiyat satirini realtime alabilir, opsiyonel)
DO $$
DECLARE _found BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname='supabase_realtime'
          AND schemaname='public' AND tablename='price_history'
    ) INTO _found;
    IF NOT _found THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.price_history;
    END IF;
END $$;

-- stocks tablosunda ESKI JSONB price_history kolonu artik kullanilmayacak.
-- Bosalt (veritabani boyutunu kucultmek icin). UPDATE yapinca tekrar doldurulmaz.
UPDATE public.stocks SET price_history = '[]'::jsonb WHERE jsonb_array_length(price_history) > 0;

-- =========================================================================
--  [ADIM 2/6] BATCH PRICE UPDATE fonksiyonu - TEK SQL sorgusuyla TUM hisseler
--     Stokastik: 40% olasilikla hareket, volatilite +-%0.9 (frontend ile ayni)
--     Cikti: SETOF stocks (yeni degerler)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.batch_tick_market_prices()
RETURNS SETOF public.stocks
LANGUAGE plpgsql
AS $$
DECLARE
    _updated_count INTEGER := 0;
BEGIN
    -- ---------------------------------------------------------------------
    --  [OPTIMIZASYON 2: BATCH UPDATE - TEK SORGU, CASE WHEN ile tum hisseler]
    --  Her satir icin ayrı UPDATE yapmak yerine, tek bir komutla 8 hissenin
    --  hepsini guncelleriz. 8 ayri sorgu = 8x fazla yazma + 8x WAL bloat.
    -- ---------------------------------------------------------------------
    WITH next_prices AS (
        SELECT
            s.symbol,
            s.current_price AS old_price,
            CASE
                -- [OPTIMIZASYON 1: Tick basina 40% olasilik (frontend ile ayni)]
                WHEN random() < 0.40 THEN
                    ROUND(
                        GREATEST(
                            0.05::numeric,
                            s.current_price * (1.0 + ((random() - 0.5) * 0.018))
                        ), 4
                    )
                ELSE s.current_price
            END AS new_price
        FROM public.stocks s
    ),
    do_update AS (
        UPDATE public.stocks s
        SET
            current_price  = np.new_price,
            change         = ROUND(np.new_price - s.previous_close, 4),
            change_pct     = ROUND(
                CASE WHEN s.previous_close = 0 THEN 0
                     ELSE ((np.new_price - s.previous_close) / s.previous_close) * 100
                END, 4
            ),
            updated_at     = now()
        FROM next_prices np
        WHERE s.symbol = np.symbol
          AND ABS(np.new_price - np.old_price) > 0.0001
        RETURNING s.symbol, s.current_price
    )
    -- INSERT INTO price_history (YENI fiyatlar icin 1 satir / tick / hisse)
    INSERT INTO public.price_history (symbol, price, recorded_at)
    SELECT du.symbol, du.current_price, now()
    FROM do_update du;

    GET DIAGNOSTICS _updated_count = ROW_COUNT;

    -- [OPTIMIZASYON 3: SAKLAMA - hisse basi 100 kayit limiti]
    -- Bu tickte yazilanlari saymayan, 100'den eski kayitlari HEMEN sil.
    -- (Daha agoradan 24 saat limiti asagida pg_cron ile her 10dk bir)
    DELETE FROM public.price_history ph
    USING (
        SELECT
            h.symbol,
            h.id,
            ROW_NUMBER() OVER (
                PARTITION BY h.symbol ORDER BY h.recorded_at DESC
            ) AS rn
        FROM public.price_history h
    ) sub
    WHERE ph.id = sub.id AND sub.rn > 100;

    -- app_settings.last_tick_at guncelle (opsiyonel)
    UPDATE public.app_settings SET last_tick_at = now() WHERE id = 1;

    -- Son halini geri don (opsiyonel, SETOF)
    RETURN QUERY SELECT * FROM public.stocks ORDER BY symbol ASC;

    RAISE NOTICE '[borsa-tick] % hisse fiyat guncellendi, history temizlendi.', _updated_count;
END;
$$;

-- =========================================================================
--  [ADIM 3/6] Tekil bir hisse icin fiyat direkt set (admin sessiz fiyat)
--   Frontend Borsa.setPrice() bunlar cagirmiyorsa manuel kullanilir.
-- =========================================================================
CREATE OR REPLACE FUNCTION public.admin_set_price(
    p_symbol  VARCHAR(16),
    p_price   NUMERIC
)
RETURNS SETOF public.stocks
LANGUAGE plpgsql
AS $$
DECLARE
    _new NUMERIC(18,4) := ROUND(GREATEST(0.05, p_price::numeric), 4);
BEGIN
    IF NOT EXISTS (SELECT 1 FROM public.stocks WHERE symbol = p_symbol) THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', p_symbol;
    END IF;

    WITH upd AS (
        UPDATE public.stocks
        SET
            current_price = _new,
            change        = ROUND(_new - previous_close, 4),
            change_pct    = ROUND(
                CASE WHEN previous_close = 0 THEN 0
                     ELSE ((_new - previous_close) / previous_close) * 100
                END, 4
            ),
            updated_at    = now()
        WHERE symbol = p_symbol
        RETURNING symbol, current_price
    )
    INSERT INTO public.price_history (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM upd;

    RETURN QUERY SELECT * FROM public.stocks WHERE symbol = p_symbol LIMIT 1;
END;
$$;

-- =========================================================================
--  [ADIM 4/6] Haber / Impact uygula (admin_publish_news + admin_apply_impact)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.admin_apply_news_impact(
    p_symbol    VARCHAR(16),
    p_impact_pct NUMERIC
)
RETURNS SETOF public.stocks
LANGUAGE plpgsql
AS $$
DECLARE
    _pct NUMERIC(18,6) := COALESCE(p_impact_pct, 0)::numeric;
    _old NUMERIC(18,4);
    _new NUMERIC(18,4);
BEGIN
    SELECT current_price INTO STRICT _old
    FROM public.stocks WHERE symbol = p_symbol FOR UPDATE;

    _new := ROUND(GREATEST(0.05, _old * (1.0 + (_pct / 100.0))), 4);

    WITH upd AS (
        UPDATE public.stocks
        SET
            current_price = _new,
            change        = ROUND(_new - previous_close, 4),
            change_pct    = ROUND(
                CASE WHEN previous_close = 0 THEN 0
                     ELSE ((_new - previous_close) / previous_close) * 100
                END, 4
            ),
            updated_at    = now()
        WHERE symbol = p_symbol
        RETURNING symbol, current_price
    )
    INSERT INTO public.price_history (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM upd;

    RETURN QUERY SELECT * FROM public.stocks WHERE symbol = p_symbol LIMIT 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_publish_news(
    p_title       TEXT,
    p_symbol      VARCHAR(16) DEFAULT NULL,
    p_impact_pct  NUMERIC     DEFAULT 0
)
RETURNS public.news_feed
LANGUAGE plpgsql
AS $$
DECLARE
    _nid BIGINT := (EXTRACT(EPOCH FROM now()) * 1000)::BIGINT + (random() * 999)::BIGINT;
    _out public.news_feed;
BEGIN
    INSERT INTO public.news_feed (id, title, stock_symbol, impact_pct, created_at)
    VALUES (_nid, substring(coalesce(p_title,'') from 1 for 280), nullif(p_symbol,''),
            coalesce(p_impact_pct,0)::numeric(8,4), now())
    RETURNING * INTO _out;

    IF p_symbol IS NOT NULL AND coalesce(p_impact_pct, 0) <> 0 THEN
        PERFORM public.admin_apply_news_impact(p_symbol, p_impact_pct);
    END IF;

    RETURN _out;
END;
$$;

-- =========================================================================
--  [ADIM 5/6] 24 saatten eski price_history KAYITLARINI SILEN FONKSIYON
--      + hisse basi 100 kayit (tekrar + guvenlik)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.purge_price_history_retention()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    _deleted INTEGER := 0;
BEGIN
    -- 24 saat + eski
    DELETE FROM public.price_history
    WHERE recorded_at < now() - INTERVAL '24 hours';
    GET DIAGNOSTICS _deleted = ROW_COUNT;

    -- hisse basi max 100 (tekrar guvenlik, ustteki 24 saatten farkli)
    WITH ranked AS (
        SELECT
            id,
            ROW_NUMBER() OVER (
                PARTITION BY symbol ORDER BY recorded_at DESC
            ) AS rn
        FROM public.price_history
    )
    DELETE FROM public.price_history ph
    USING ranked r
    WHERE ph.id = r.id AND r.rn > 100;

    -- news_feed de son 200 + 7 gunluk tutalim (disk optimizasyonu)
    WITH ranked_news AS (
        SELECT id, ROW_NUMBER() OVER (ORDER BY created_at DESC) AS rn
        FROM public.news_feed
    )
    DELETE FROM public.news_feed nf
    USING ranked_news r
    WHERE nf.id = r.id AND r.rn > 200;

    DELETE FROM public.news_feed WHERE created_at < now() - INTERVAL '7 days';

    RETURN _deleted;
END;
$$;

-- =========================================================================
--  [ADIM 6/6] pg_cron GUNCELLEME - OPTIMIZASYON 1: HER 15 SANiYE
--         + retention temizligi HER 10 DAKiKADA bir
-- =========================================================================
-- Oncelikle eskiden varsa kaldır (temiz kurulum)
SELECT cron.unschedule('borsa-every-15s-price-tick')  WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'borsa-every-15s-price-tick');
SELECT cron.unschedule('borsa-every-10m-retention')    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'borsa-every-10m-retention');

-- Yeni schedule:
--  [1] 15 SANiYEDE BIR fiyat tick
SELECT cron.schedule(
    'borsa-every-15s-price-tick',
    '*/15 * * * * *',  -- 6 alan (yıl-dakika-saat-gun-ay-hafta): SANIYE icin 6 kisim kullanilir
    $$ SELECT public.batch_tick_market_prices(); $$
);

--  [2] 10 DAKiKADA BIR retention temizligi
SELECT cron.schedule(
    'borsa-every-10m-retention',
    '*/10 * * * *',   -- 5 alan = her 10 dakika
    $$ SELECT public.purge_price_history_retention(); $$
);

-- Supabase auth izinleri (RPC'leri cagirabilmek icin)
GRANT EXECUTE ON FUNCTION public.batch_tick_market_prices() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_price(VARCHAR(16), NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_news_impact(VARCHAR(16), NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_publish_news(TEXT, VARCHAR(16), NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.purge_price_history_retention() TO pg_database_owner;

-- =========================================================================
--  BILGILENDIRME:
--  Kurulum sonrasi 1 satir kontrol:
--     SELECT * FROM cron.job ORDER BY jobid;
--  Fiyatlar guncelleniyor mu?
--     SELECT symbol, current_price, updated_at FROM stocks ORDER BY updated_at DESC LIMIT 5;
--  Kayit sayisi kontrolu (her hisse basi <= 100 satir olmali):
--     SELECT symbol, COUNT(*) FROM price_history GROUP BY 1 ORDER BY 1;
-- =========================================================================
