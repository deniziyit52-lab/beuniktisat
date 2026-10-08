-- Hisse turleri (Guvenli/Orta/Riskli) ve yeni dakikalik fiyat motoru.
-- getiri = drift + vol_dk*vol_mult*gauss + beta*piyasa_faktoru (+ sok); fiyat*exp(getiri); taban price_floor.

-- Tur ayarlari: oranlar kesir olarak tutulur (0.05 = %5).
CREATE TABLE IF NOT EXISTS public.stock_types (
    risk_type     TEXT PRIMARY KEY,
    label         TEXT NOT NULL,
    daily_sigma   NUMERIC NOT NULL CHECK (daily_sigma >= 0),
    beta          NUMERIC NOT NULL,
    drift_daily   NUMERIC NOT NULL DEFAULT 0,
    shock_per_day NUMERIC NOT NULL DEFAULT 0 CHECK (shock_per_day >= 0),
    shock_min     NUMERIC NOT NULL DEFAULT 0 CHECK (shock_min >= 0),
    shock_max     NUMERIC NOT NULL DEFAULT 0 CHECK (shock_max >= shock_min),
    sort_order    INTEGER NOT NULL DEFAULT 0
);

INSERT INTO public.stock_types
    (risk_type, label, daily_sigma, beta, drift_daily, shock_per_day, shock_min, shock_max, sort_order)
VALUES
    ('guvenli', 'Güvenli', 0.02, 0.5, 0, 0.5, 0.005, 0.01,  1),
    ('orta',    'Orta',    0.05, 1.0, 0, 1,   0.01,  0.025, 2),
    ('riskli',  'Riskli',  0.11, 1.5, 0, 2,   0.02,  0.05,  3)
ON CONFLICT (risk_type) DO NOTHING;

-- Motorun genel ayarlari (tek satir).
CREATE TABLE IF NOT EXISTS public.engine_settings (
    id                  INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    market_daily_sigma  NUMERIC NOT NULL DEFAULT 0.015,
    minutes_per_day     NUMERIC NOT NULL DEFAULT 900 CHECK (minutes_per_day > 0),
    price_floor         NUMERIC NOT NULL DEFAULT 1,
    shock_vol_mult      NUMERIC NOT NULL DEFAULT 2,
    news_vol_mult       NUMERIC NOT NULL DEFAULT 2,
    vol_mult_decay      NUMERIC NOT NULL DEFAULT 0.9 CHECK (vol_mult_decay >= 0 AND vol_mult_decay < 1)
);

INSERT INTO public.engine_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.stock_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.engine_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "stock_types herkes okur" ON public.stock_types;
CREATE POLICY "stock_types herkes okur"
    ON public.stock_types FOR SELECT USING (true);

REVOKE ALL ON public.stock_types, public.engine_settings FROM anon, authenticated;
GRANT SELECT ON public.stock_types TO anon, authenticated;

ALTER TABLE public.stocks
    ADD COLUMN IF NOT EXISTS risk_type TEXT NOT NULL DEFAULT 'orta' REFERENCES public.stock_types(risk_type);
ALTER TABLE public.stocks
    ADD COLUMN IF NOT EXISTS vol_mult NUMERIC(8,4) NOT NULL DEFAULT 1;

CREATE OR REPLACE FUNCTION public.batch_tick_market_prices()
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _market_open BOOLEAN;
    _cfg public.engine_settings%ROWTYPE;
    _n DOUBLE PRECISION;
    _sigma_m DOUBLE PRECISION;
    _sigma_m_min DOUBLE PRECISION;
    _m DOUBLE PRECISION;
    _updated_count INTEGER := 0;
BEGIN
    SELECT is_market_open
    INTO _market_open
    FROM public.market_settings
    WHERE id = 1
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'market_settings row id=1 is missing.';
    END IF;

    IF NOT _market_open THEN
        RETURN QUERY SELECT * FROM public.stocks ORDER BY symbol;
        RETURN;
    END IF;

    SELECT * INTO _cfg FROM public.engine_settings WHERE id = 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'engine_settings row id=1 is missing.';
    END IF;

    _n := _cfg.minutes_per_day;
    _sigma_m := _cfg.market_daily_sigma;
    _sigma_m_min := _sigma_m / sqrt(_n);
    -- Piyasa faktoru: bu dakika butun hisseler icin ortak tek cekilis.
    _m := _sigma_m_min * sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random());

    WITH draws AS MATERIALIZED (
        SELECT
            s.symbol,
            s.current_price::DOUBLE PRECISION AS price,
            s.vol_mult::DOUBLE PRECISION AS vol_mult,
            t.beta::DOUBLE PRECISION AS beta,
            t.drift_daily::DOUBLE PRECISION AS drift_daily,
            -- Hissenin kendi oynakligi: toplam gunluk sigma hedefinden piyasa payi dusulur.
            sqrt(GREATEST(
                t.daily_sigma::DOUBLE PRECISION ^ 2 - (t.beta::DOUBLE PRECISION * _sigma_m) ^ 2,
                0
            )) / sqrt(_n) AS vol_min,
            sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random()) AS gauss,
            random() < t.shock_per_day::DOUBLE PRECISION / _n AS shocked,
            (CASE WHEN random() < 0.5 THEN -1 ELSE 1 END)
                * (t.shock_min::DOUBLE PRECISION
                   + random() * (t.shock_max - t.shock_min)::DOUBLE PRECISION) AS shock
        FROM public.stocks AS s
        JOIN public.stock_types AS t ON t.risk_type = s.risk_type
    ),
    moves AS MATERIALIZED (
        SELECT
            symbol,
            shocked,
            GREATEST(
                _cfg.price_floor,
                ROUND((price * exp(
                    drift_daily / _n
                    + vol_min * vol_mult * gauss
                    + beta * _m
                    - 0.5 * ((vol_min * vol_mult) ^ 2 + (beta * _sigma_m_min) ^ 2)
                    + CASE WHEN shocked THEN shock ELSE 0 END
                ))::NUMERIC, 4)
            ) AS new_price
        FROM draws
    ),
    updated AS (
        UPDATE public.stocks AS s
        SET current_price = n.new_price,
            change = ROUND(n.new_price - s.previous_close, 4),
            change_pct = ROUND(
                CASE WHEN s.previous_close = 0 THEN 0
                     ELSE ((n.new_price - s.previous_close) / s.previous_close) * 100
                END,
                4
            ),
            -- Sok sonrasi oynaklik yukselir, sonra her dakika 1'e dogru geri doner.
            vol_mult = CASE
                WHEN n.shocked THEN GREATEST(s.vol_mult, _cfg.shock_vol_mult)
                ELSE ROUND(1 + (s.vol_mult - 1) * _cfg.vol_mult_decay, 4)
            END,
            updated_at = now()
        FROM moves AS n
        WHERE s.symbol = n.symbol
        RETURNING s.symbol, s.current_price
    ),
    inserted AS (
        INSERT INTO public.price_history (symbol, price, recorded_at)
        SELECT symbol, current_price, now()
        FROM updated
        RETURNING id
    )
    SELECT count(*) INTO _updated_count FROM inserted;

    DELETE FROM public.price_history
    WHERE recorded_at < now() - INTERVAL '48 hours';

    RETURN QUERY SELECT * FROM public.stocks ORDER BY symbol;
END;
$$;

REVOKE ALL ON FUNCTION public.batch_tick_market_prices()
    FROM PUBLIC, anon, authenticated;

-- Haber etkisi: fiyat tabani ayardan okunur, haberden sonra oynaklik yukselir.
CREATE OR REPLACE FUNCTION public.admin_apply_news_impact(
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
    _floor NUMERIC;
    _news_vol_mult NUMERIC;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT price_floor, news_vol_mult INTO _floor, _news_vol_mult
    FROM public.engine_settings WHERE id = 1;

    SELECT current_price, previous_close
    INTO _old_price, _previous_close
    FROM public.stocks
    WHERE symbol = _symbol
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', p_symbol;
    END IF;

    _new_price := ROUND(GREATEST(coalesce(_floor, 1), _old_price * (1 + coalesce(p_impact_pct, 0) / 100)), 4);

    UPDATE public.stocks
    SET current_price = _new_price,
        change = ROUND(_new_price - _previous_close, 4),
        change_pct = ROUND(
            CASE WHEN _previous_close = 0 THEN 0
                 ELSE ((_new_price - _previous_close) / _previous_close) * 100
            END,
            4
        ),
        vol_mult = GREATEST(vol_mult, coalesce(_news_vol_mult, 1)),
        updated_at = now()
    WHERE symbol = _symbol;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    VALUES (_symbol, _new_price, now());

    RETURN QUERY SELECT * FROM public.stocks WHERE symbol = _symbol;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_apply_news_impact(VARCHAR(16), NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_apply_news_impact(VARCHAR(16), NUMERIC) TO authenticated;

-- Admin panelinden hissenin turunu degistirme.
CREATE OR REPLACE FUNCTION public.admin_set_stock_type(
    p_symbol TEXT,
    p_risk_type TEXT
)
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _symbol TEXT := upper(trim(coalesce(p_symbol, '')));
    _risk_type TEXT := lower(trim(coalesce(p_risk_type, '')));
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.stock_types WHERE risk_type = _risk_type) THEN
        RAISE EXCEPTION 'Gecersiz hisse turu: %', p_risk_type;
    END IF;

    UPDATE public.stocks
    SET risk_type = _risk_type, updated_at = now()
    WHERE symbol = _symbol;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', _symbol;
    END IF;

    RETURN QUERY SELECT * FROM public.stocks WHERE symbol = _symbol;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_stock_type(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_stock_type(TEXT, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';
