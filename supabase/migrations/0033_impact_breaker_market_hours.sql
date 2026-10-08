-- 1) Fiyat etkisi hisse turune gore tek mantikla hesaplanir (elle girilmis market_cap yerine).
-- 2) Devre kesici: fiyat referansa gore %10 oynarsa o hissede islemler 5 dakika durur.
-- 3) Piyasa her gun 09:00'da acilir, 24:00'te kapanir (Turkiye saati).

-- impact_depth: etki = islem tutari / impact_depth. 100.000 TL'lik islem:
-- Guvenli %1, Orta %2, Riskli %4 oynatir.
ALTER TABLE public.stock_types
    ADD COLUMN IF NOT EXISTS impact_depth NUMERIC NOT NULL DEFAULT 5000000 CHECK (impact_depth > 0);

UPDATE public.stock_types
SET impact_depth = CASE risk_type
        WHEN 'guvenli' THEN 10000000
        WHEN 'riskli' THEN 2500000
        ELSE 5000000
    END;

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS breaker_pct NUMERIC NOT NULL DEFAULT 0.10 CHECK (breaker_pct > 0);
ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS breaker_minutes INTEGER NOT NULL DEFAULT 5 CHECK (breaker_minutes > 0);
ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS max_trade_impact NUMERIC NOT NULL DEFAULT 0.10 CHECK (max_trade_impact > 0);

-- halt_until: bu ana kadar hissede islem yok. breaker_ref: %10'un olculdugu referans fiyat.
ALTER TABLE public.stocks ADD COLUMN IF NOT EXISTS halt_until TIMESTAMPTZ;
ALTER TABLE public.stocks ADD COLUMN IF NOT EXISTS breaker_ref NUMERIC(18,4);

UPDATE public.stocks SET breaker_ref = current_price WHERE breaker_ref IS NULL;

-- Fiyati kim degistirirse degistirsin (motor, alim satim, haber, admin) ayni kural calisir.
CREATE OR REPLACE FUNCTION public.apply_circuit_breaker()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _pct NUMERIC;
    _minutes INTEGER;
BEGIN
    IF NEW.current_price IS NOT DISTINCT FROM OLD.current_price THEN
        RETURN NEW;
    END IF;
    IF NEW.breaker_ref IS NULL OR NEW.breaker_ref <= 0 THEN
        NEW.breaker_ref := OLD.current_price;
    END IF;

    SELECT breaker_pct, breaker_minutes INTO _pct, _minutes
    FROM public.engine_settings WHERE id = 1;

    IF NEW.breaker_ref > 0
       AND abs(NEW.current_price / NEW.breaker_ref - 1) >= coalesce(_pct, 0.10) THEN
        NEW.halt_until := now() + make_interval(mins => coalesce(_minutes, 5));
        NEW.breaker_ref := NEW.current_price;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_circuit_breaker() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_stocks_circuit_breaker ON public.stocks;
CREATE TRIGGER trg_stocks_circuit_breaker
    BEFORE UPDATE OF current_price ON public.stocks
    FOR EACH ROW
    EXECUTE FUNCTION public.apply_circuit_breaker();

-- Fiyat ozetine halt_until eklenir; site devre kesici etiketini buradan gosterir.
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
                'risk_type', risk_type,
                'halt_until', halt_until
            )
            ORDER BY symbol
        ),
        '[]'::jsonb
    )
    FROM public.stocks;
$$;

REVOKE ALL ON FUNCTION public.build_market_snapshot() FROM PUBLIC, anon, authenticated;

-- Fiyat motoru: devre kesicideki hisseler o dakika atlanir.
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
        WHERE s.halt_until IS NULL OR s.halt_until <= now()
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

-- Alim satim: etki ture gore, islem basina en fazla max_trade_impact; devre kesicideki hissede islem yok.
CREATE OR REPLACE FUNCTION public.execute_hybrid_trade(
    p_user_id UUID,
    p_symbol VARCHAR(16),
    p_qty INTEGER,
    p_side TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _symbol VARCHAR(16) := upper(trim(coalesce(p_symbol, '')));
    _side TEXT := upper(trim(coalesce(p_side, '')));
    _market_open BOOLEAN;
    _cfg public.engine_settings%ROWTYPE;
    _stock public.stocks%ROWTYPE;
    _updated_stock public.stocks%ROWTYPE;
    _depth NUMERIC;
    _execution_price NUMERIC(18,4);
    _trade_volume NUMERIC;
    _impact_fraction NUMERIC;
    _new_price NUMERIC(18,4);
    _circuit_breaker_triggered BOOLEAN;
    _trade_result JSONB;
BEGIN
    IF auth.uid() IS NULL OR auth.uid() IS DISTINCT FROM p_user_id THEN
        RAISE EXCEPTION 'Authenticated user does not match trade user.'
            USING ERRCODE = '42501';
    END IF;

    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'Trade quantity must be greater than zero.';
    END IF;

    IF _side NOT IN ('BUY', 'SELL') THEN
        RAISE EXCEPTION 'Trade side must be BUY or SELL.';
    END IF;

    SELECT is_market_open
    INTO _market_open
    FROM public.market_settings
    WHERE id = 1
    FOR SHARE;

    IF NOT FOUND OR NOT _market_open THEN
        RAISE EXCEPTION 'Piyasa kapalı. Alım-satım yapılamaz.';
    END IF;

    SELECT * INTO _cfg FROM public.engine_settings WHERE id = 1;

    SELECT *
    INTO _stock
    FROM public.stocks
    WHERE symbol = _symbol
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock not found: %', _symbol;
    END IF;

    IF _stock.halt_until IS NOT NULL AND _stock.halt_until > now() THEN
        RAISE EXCEPTION 'Devre kesici devrede. Bu hissede işlemler saat % itibarıyla yeniden açılacak.',
            to_char(_stock.halt_until AT TIME ZONE 'Europe/Istanbul', 'HH24:MI');
    END IF;

    IF _stock.current_price < 0.01 THEN
        RAISE EXCEPTION 'Stock price must be positive.';
    END IF;

    SELECT impact_depth INTO _depth
    FROM public.stock_types
    WHERE risk_type = _stock.risk_type;

    _execution_price := _stock.current_price;
    _trade_volume := p_qty::numeric * _execution_price;
    _impact_fraction := LEAST(
        _trade_volume / coalesce(_depth, 5000000),
        coalesce(_cfg.max_trade_impact, 0.10)
    );
    _new_price := ROUND(
        GREATEST(
            coalesce(_cfg.price_floor, 1),
            _execution_price * (1 + CASE WHEN _side = 'BUY' THEN _impact_fraction ELSE -_impact_fraction END)
        ),
        4
    );

    EXECUTE
        'SELECT to_jsonb(t)
         FROM public.execute_trade(
             $1::uuid, $2::varchar(16), $3::integer, $4::numeric, $5::text
         ) AS t'
    INTO _trade_result
    USING p_user_id, _symbol, p_qty, _execution_price, _side;

    IF _trade_result IS NULL THEN
        RAISE EXCEPTION 'Trade settlement RPC returned no result.';
    END IF;

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
    RETURNING * INTO _updated_stock;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    VALUES (_symbol, _new_price, now());

    _circuit_breaker_triggered :=
        _updated_stock.halt_until IS NOT NULL AND _updated_stock.halt_until > now();

    RETURN jsonb_build_object(
        'trade', _trade_result,
        'execution_price', _execution_price,
        'trade_volume', _trade_volume,
        'impact_fraction', _impact_fraction,
        'circuit_breaker_triggered', _circuit_breaker_triggered,
        'circuit_breaker_message', CASE
            WHEN _circuit_breaker_triggered
            THEN 'Devre kesici devreye girdi: bu hissede işlemler saat '
                 || to_char(_updated_stock.halt_until AT TIME ZONE 'Europe/Istanbul', 'HH24:MI')
                 || ' itibarıyla yeniden açılacak.'
            ELSE NULL
        END,
        'new_price', _new_price,
        'stock', to_jsonb(_updated_stock)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.execute_hybrid_trade(UUID, VARCHAR(16), INTEGER, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_hybrid_trade(UUID, VARCHAR(16), INTEGER, TEXT)
    TO authenticated;

-- Piyasayi acip kapatan ortak mantik: hem admin dugmesi hem zamanlayici bunu kullanir.
CREATE OR REPLACE FUNCTION public.apply_market_open(p_is_market_open BOOLEAN)
RETURNS public.market_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _settings public.market_settings%ROWTYPE;
BEGIN
    IF p_is_market_open IS NULL THEN
        RAISE EXCEPTION 'Market open status must be specified.';
    END IF;

    SELECT *
    INTO _settings
    FROM public.market_settings
    WHERE id = 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'market_settings row id=1 is missing.';
    END IF;

    IF _settings.is_market_open = p_is_market_open THEN
        RETURN _settings;
    END IF;

    IF p_is_market_open THEN
        -- Acilista gunluk degisim yuzdesi ve devre kesiciler sifirlanir; yeni gun guncel fiyattan baslar.
        UPDATE public.stocks
        SET previous_close = current_price,
            change = 0,
            change_pct = 0,
            breaker_ref = current_price,
            halt_until = NULL,
            updated_at = now()
        WHERE symbol IS NOT NULL;
    ELSE
        -- Kapanista gunun degisimi ertesi sabaha kadar gorunur kalir.
        UPDATE public.stocks
        SET halt_until = NULL
        WHERE symbol IS NOT NULL;
    END IF;

    UPDATE public.market_settings
    SET is_market_open = p_is_market_open
    WHERE id = 1
    RETURNING * INTO _settings;

    RETURN _settings;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_market_open(BOOLEAN) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.set_market_open(p_is_market_open BOOLEAN)
RETURNS public.market_settings
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    RETURN public.apply_market_open(p_is_market_open);
END;
$$;

REVOKE ALL ON FUNCTION public.set_market_open(BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_market_open(BOOLEAN) TO authenticated;

-- Zamanlayici UTC calisir; Turkiye UTC+3: 09:00 = 06:00 UTC, 24:00 = 21:00 UTC.
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname IN ('borsa-market-open', 'borsa-market-close');

SELECT cron.schedule(
    'borsa-market-open',
    '0 6 * * *',
    $$ SELECT public.apply_market_open(true); $$
);

SELECT cron.schedule(
    'borsa-market-close',
    '0 21 * * *',
    $$ SELECT public.apply_market_open(false); $$
);

-- Ozet satiri yeni alanla (halt_until) bir kez yenilenir.
UPDATE public.market_snapshot
SET stocks = public.build_market_snapshot(), updated_at = now()
WHERE id = 1;

NOTIFY pgrst, 'reload schema';

SELECT jobname AS zamanlanmis_gorev, schedule AS utc_zamani
FROM cron.job
WHERE jobname LIKE 'borsa-%'
ORDER BY jobname;
