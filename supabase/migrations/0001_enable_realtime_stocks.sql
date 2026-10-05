-- =========================================================================
--  BORSA SIMULASYONU - SUPABASE REALTIME AKTIVASYONU
--  Calistirilma yeri: Supabase Dashboard > SQL Editor > New Query
--  BU DOSYA: PostgreSQL 13+ ile %100 UYUMLU (CREATE POLICY IF NOT EXISTS YOK)
-- =========================================================================

-- -------------------------------------------------------------------------
--  1) STOCKS (Hisseler) - TEK DOGRULUK KAYNAGI
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.stocks (
    symbol          VARCHAR(16)  PRIMARY KEY,
    name            VARCHAR(120) NOT NULL,
    color           VARCHAR(16)  NOT NULL DEFAULT '#3b82f6',
    current_price   NUMERIC(18,4) NOT NULL DEFAULT 100.00,
    previous_close  NUMERIC(18,4) NOT NULL DEFAULT 100.00,
    shares          BIGINT       NOT NULL DEFAULT 100000,
    price_history   JSONB        NOT NULL DEFAULT '[]'::jsonb,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);

ALTER TABLE public.stocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stocks REPLICA IDENTITY FULL;

DROP POLICY IF EXISTS "stocks anon herkes okuyabilir" ON public.stocks;
CREATE POLICY "stocks anon herkes okuyabilir"
    ON public.stocks FOR SELECT USING (true);

DROP POLICY IF EXISTS "stocks auth kullanici degistirebilir" ON public.stocks;
CREATE POLICY "stocks auth kullanici degistirebilir"
    ON public.stocks FOR ALL TO authenticated
    USING (true) WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_stocks_updated_at ON public.stocks (updated_at DESC);

-- -------------------------------------------------------------------------
--  2) MEVCUT TABLOLAR ICIN REPLICA IDENTITY (zorunlu - UPDATE/DELETE yayini icin)
-- -------------------------------------------------------------------------
ALTER TABLE IF EXISTS public.users        REPLICA IDENTITY FULL;
ALTER TABLE IF EXISTS public.transactions REPLICA IDENTITY FULL;
ALTER TABLE IF EXISTS public.market_tips  REPLICA IDENTITY FULL;

-- -------------------------------------------------------------------------
--  3) APP_SETTINGS (Bakim modu + Piyasa acik/kapali)
--     ONEMLI: Eski kurulumlarda tablo zaten VAR ve kolonlar farkli olabilir
--            -> CREATE TABLE IF NOT EXISTS sonrasi ADD COLUMN IF NOT EXISTS ile yama yap.
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.app_settings (
    id               INTEGER PRIMARY KEY DEFAULT 1,
    maintenance_mode BOOLEAN NOT NULL DEFAULT false,
    market_open      BOOLEAN NOT NULL DEFAULT true,
    last_tick_at     TIMESTAMPTZ,
    updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- EKSIK KOLONLARI OLUŞTUR (eski tablolarda kolonlar eksikse)
ALTER TABLE public.app_settings
    ADD COLUMN IF NOT EXISTS maintenance_mode BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.app_settings
    ADD COLUMN IF NOT EXISTS market_open      BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE public.app_settings
    ADD COLUMN IF NOT EXISTS last_tick_at     TIMESTAMPTZ;
ALTER TABLE public.app_settings
    ADD COLUMN IF NOT EXISTS updated_at       TIMESTAMPTZ NOT NULL DEFAULT now();

ALTER TABLE public.app_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_settings REPLICA IDENTITY FULL;

DROP POLICY IF EXISTS "app_settings herkes okur" ON public.app_settings;
CREATE POLICY "app_settings herkes okur"
    ON public.app_settings FOR SELECT USING (true);

DROP POLICY IF EXISTS "app_settings auth gunceller" ON public.app_settings;
CREATE POLICY "app_settings auth gunceller"
    ON public.app_settings FOR UPDATE TO authenticated
    USING (true) WITH CHECK (true);

-- id=1 SATIRINI OLUSTUR VE DEFAULT DEGERLERI ENSURE ET (DUPLICATE-SAFE)
INSERT INTO public.app_settings (id, maintenance_mode, market_open, updated_at)
VALUES (1, false, true, now())
ON CONFLICT (id) DO UPDATE SET
    maintenance_mode = COALESCE(EXCLUDED.maintenance_mode, false),
    market_open      = COALESCE(app_settings.market_open, EXCLUDED.market_open),
    updated_at       = GREATEST(COALESCE(app_settings.updated_at, '-infinity'::timestamptz), EXCLUDED.updated_at);

-- -------------------------------------------------------------------------
--  4) NEWS_FEED (Admin haberleri + otomatik fiyat etkisi)
-- -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.news_feed (
    id           BIGINT PRIMARY KEY,
    title        VARCHAR(280) NOT NULL,
    stock_symbol VARCHAR(16),
    impact_pct   NUMERIC(8,4) NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

ALTER TABLE public.news_feed ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.news_feed REPLICA IDENTITY FULL;

DROP POLICY IF EXISTS "news_feed herkes okur" ON public.news_feed;
CREATE POLICY "news_feed herkes okur"
    ON public.news_feed FOR SELECT USING (true);

DROP POLICY IF EXISTS "news_feed auth yazar" ON public.news_feed;
CREATE POLICY "news_feed auth yazar"
    ON public.news_feed FOR INSERT TO authenticated
    WITH CHECK (true);

CREATE INDEX IF NOT EXISTS idx_news_feed_created_at ON public.news_feed (created_at DESC);

-- -------------------------------------------------------------------------
--  5) UPDATED_AT TRIGGER
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_stocks_set_updated_at ON public.stocks;
CREATE TRIGGER trg_stocks_set_updated_at
BEFORE UPDATE ON public.stocks
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

DROP TRIGGER IF EXISTS trg_app_settings_set_updated_at ON public.app_settings;
CREATE TRIGGER trg_app_settings_set_updated_at
BEFORE UPDATE ON public.app_settings
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- -------------------------------------------------------------------------
--  6) PUBLICATION + TABLO EKLEME (EN ONEMLI KISIM - DUPLICATE-SAFE)
--     NOT: Eski "ALTER PUBLICATION ... ADD TABLE" tek tek kaldirildi,
--     sadece ASAGIDAKI guvenli DO blogu calisir (zaten varsa atlar).
-- -------------------------------------------------------------------------
DO $$
DECLARE
    _pub_exists BOOLEAN;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime')
    INTO _pub_exists;
    IF NOT _pub_exists THEN
        CREATE PUBLICATION supabase_realtime;
    END IF;
END $$;

DO $$
DECLARE
    _tables TEXT[] := ARRAY[
        'public.stocks',
        'public.transactions',
        'public.app_settings',
        'public.users',
        'public.market_tips',
        'public.news_feed'
    ];
    _t TEXT;
    _found BOOLEAN;
BEGIN
    FOREACH _t IN ARRAY _tables LOOP
        SELECT EXISTS (
            SELECT 1
            FROM pg_publication_tables
            WHERE pubname = 'supabase_realtime'
              AND (schemaname || '.' || tablename) = _t
        ) INTO _found;
        IF NOT _found THEN
            EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE ' || _t;
            RAISE NOTICE '[OK] Eklendi: %', _t;
        ELSE
            RAISE NOTICE '[SKIP] Zaten yayinda: %', _t;
        END IF;
    END LOOP;
END $$;
