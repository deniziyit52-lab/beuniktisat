-- 1) Tek hissede en fazla pay: bir hissedeki pozisyon, toplam varligin belli bir yuzdesini gecemez.
-- 2) Fiyat etkisinin bir kismi sonraki dakikalarda geri doner.
-- 3) Piyasa geneli devre kesici: hisselerin ortalamasi gun icinde cok duserse butun hisse islemleri durur.

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS max_position_pct NUMERIC NOT NULL DEFAULT 0.40
        CHECK (max_position_pct > 0 AND max_position_pct <= 1);
ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS impact_revert_share NUMERIC NOT NULL DEFAULT 0.50
        CHECK (impact_revert_share >= 0 AND impact_revert_share <= 1);
-- Geri donecek kismin her dakika eriyen orani: 0.20 ile yaklasik 10 dakikada biter.
ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS impact_revert_rate NUMERIC NOT NULL DEFAULT 0.20
        CHECK (impact_revert_rate > 0 AND impact_revert_rate <= 1);
-- drop: ortalama dusus (kesir), minutes: durma suresi; 0 = gun sonuna kadar.
ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS market_breaker_levels JSONB NOT NULL
    DEFAULT '[{"drop": 0.07, "minutes": 15}, {"drop": 0.13, "minutes": 30}, {"drop": 0.20, "minutes": 0}]'::jsonb;

-- Henuz geri donmemis fiyat etkisi (logaritmik getiri olarak).
ALTER TABLE public.stocks
    ADD COLUMN IF NOT EXISTS impact_pending NUMERIC(12,6) NOT NULL DEFAULT 0;

ALTER TABLE public.market_settings ADD COLUMN IF NOT EXISTS halt_until TIMESTAMPTZ;
ALTER TABLE public.market_settings ADD COLUMN IF NOT EXISTS halt_level INTEGER NOT NULL DEFAULT 0;

-- Oyuncu sayfasinin bilmesi gereken kurallar (gizli ayarlar acilmadan).
CREATE OR REPLACE FUNCTION public.get_game_rules()
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_build_object('max_position_pct', max_position_pct)
    FROM public.engine_settings
    WHERE id = 1;
$$;

REVOKE ALL ON FUNCTION public.get_game_rules() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_game_rules() TO anon, authenticated;

-- Fiyat motoru: piyasa geneli durusta fiyatlar oynamaz; islem etkisinin geri donen kismi burada eritilir;
-- her dakikanin sonunda piyasa geneli devre kesici kontrol edilir.
CREATE OR REPLACE FUNCTION public.batch_tick_market_prices()
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _market public.market_settings%ROWTYPE;
    _cfg public.engine_settings%ROWTYPE;
    _n DOUBLE PRECISION;
    _sigma_m DOUBLE PRECISION;
    _sigma_m_min DOUBLE PRECISION;
    _m DOUBLE PRECISION;
    _rate DOUBLE PRECISION;
    _updated_count INTEGER := 0;
    _index NUMERIC;
    _level RECORD;
BEGIN
    SELECT *
    INTO _market
    FROM public.market_settings
    WHERE id = 1
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'market_settings row id=1 is missing.';
    END IF;

    IF NOT _market.is_market_open
       OR (_market.halt_until IS NOT NULL AND _market.halt_until > now()) THEN
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
    _rate := coalesce(_cfg.impact_revert_rate, 0.20);
    -- Piyasa faktoru: bu dakika butun hisseler icin ortak tek cekilis.
    _m := _sigma_m_min * sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random());

    WITH draws AS MATERIALIZED (
        SELECT
            s.symbol,
            s.current_price::DOUBLE PRECISION AS price,
            s.vol_mult::DOUBLE PRECISION AS vol_mult,
            s.impact_pending::DOUBLE PRECISION AS impact_pending,
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
            impact_pending,
            GREATEST(
                _cfg.price_floor,
                ROUND((price * exp(
                    drift_daily / _n
                    + vol_min * vol_mult * gauss
                    + beta * _m
                    - 0.5 * ((vol_min * vol_mult) ^ 2 + (beta * _sigma_m_min) ^ 2)
                    + CASE WHEN shocked THEN shock ELSE 0 END
                    -- Islem etkisinin geri donecek kisminin bu dakikaki payi.
                    - impact_pending * _rate
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
            impact_pending = CASE
                WHEN abs(n.impact_pending * (1 - _rate)) < 0.0002 THEN 0
                ELSE ROUND((n.impact_pending * (1 - _rate))::NUMERIC, 6)
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

    -- Piyasa geneli devre kesici: hisselerin gunluk degisim ortalamasina bakilir.
    -- Her basamak gunde bir kez calisir; en agir uyan basamak gecerlidir.
    SELECT coalesce(avg(change_pct), 0) / 100 INTO _index FROM public.stocks;

    FOR _level IN
        SELECT e.ord::INTEGER AS ord,
               (e.item ->> 'drop')::NUMERIC AS drop_pct,
               coalesce((e.item ->> 'minutes')::INTEGER, 0) AS minutes
        FROM jsonb_array_elements(_cfg.market_breaker_levels) WITH ORDINALITY AS e(item, ord)
        ORDER BY e.ord DESC
    LOOP
        IF _level.drop_pct > 0 AND _index <= -_level.drop_pct AND _level.ord > _market.halt_level THEN
            INSERT INTO public.news_feed (id, title, summary, stock_symbol, impact_pct, created_at)
            VALUES (
                floor(extract(epoch FROM clock_timestamp()) * 1000000)::BIGINT,
                '⚡ Piyasa geneli devre kesici devreye girdi',
                'Hisselerin ortalaması gün içinde %' || ROUND(abs(_index) * 100, 1)
                    || ' düştü. Hisse işlemleri '
                    || CASE WHEN _level.minutes > 0
                            THEN _level.minutes || ' dakika durduruldu.'
                            ELSE 'gün sonuna kadar durduruldu; piyasa yarın 09:00''da açılacak.'
                       END,
                NULL,
                0,
                now()
            );

            IF _level.minutes > 0 THEN
                UPDATE public.market_settings
                SET halt_level = _level.ord,
                    halt_until = now() + make_interval(mins => _level.minutes)
                WHERE id = 1;
            ELSE
                UPDATE public.market_settings
                SET halt_level = _level.ord, halt_until = NULL
                WHERE id = 1;
                PERFORM public.apply_market_open(false);
            END IF;
            EXIT;
        END IF;
    END LOOP;

    RETURN QUERY SELECT * FROM public.stocks ORDER BY symbol;
END;
$$;

REVOKE ALL ON FUNCTION public.batch_tick_market_prices()
    FROM PUBLIC, anon, authenticated;

-- Alim satim: pozisyon siniri, piyasa geneli durus ve geri donecek etki kaydi eklendi.
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
    _market public.market_settings%ROWTYPE;
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
    _balance NUMERIC;
    _portfolio JSONB;
    _assets JSONB;
    _wealth NUMERIC;
    _held NUMERIC;
    _cap NUMERIC;
    _max_more NUMERIC;
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

    SELECT *
    INTO _market
    FROM public.market_settings
    WHERE id = 1
    FOR SHARE;

    IF NOT FOUND OR NOT _market.is_market_open THEN
        RAISE EXCEPTION 'Piyasa kapalı. Alım-satım yapılamaz.';
    END IF;

    IF _market.halt_until IS NOT NULL AND _market.halt_until > now() THEN
        RAISE EXCEPTION 'Piyasa geneli devre kesici devrede. Hisse işlemleri saat % itibarıyla yeniden açılacak.',
            to_char(_market.halt_until AT TIME ZONE 'Europe/Istanbul', 'HH24:MI');
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

    _execution_price := _stock.current_price;
    _trade_volume := p_qty::numeric * _execution_price;

    -- Tek hissede en fazla pay: alimdan sonraki pozisyon, toplam varligin belli bir yuzdesini gecemez.
    IF _side = 'BUY' THEN
        _cap := coalesce(_cfg.max_position_pct, 0.40);

        SELECT u.balance,
               CASE WHEN jsonb_typeof(u.portfolio) = 'object' THEN u.portfolio ELSE '{}'::jsonb END,
               CASE WHEN jsonb_typeof(u.assets) = 'object' THEN u.assets ELSE '{}'::jsonb END
        INTO _balance, _portfolio, _assets
        FROM public.users AS u
        WHERE u.id = p_user_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Profil bulunamadı.';
        END IF;

        _wealth := _balance
            + coalesce((
                SELECT sum((kv.value ->> 'qty')::NUMERIC * s.current_price)
                FROM jsonb_each(_portfolio) AS kv
                JOIN public.stocks AS s ON s.symbol = kv.key
            ), 0)
            + coalesce((
                SELECT sum((kv.value ->> 'qty')::NUMERIC * (ap.prices ->> kv.key)::NUMERIC)
                FROM jsonb_each(_assets) AS kv
                CROSS JOIN public.asset_prices AS ap
                WHERE ap.id = 1
            ), 0);

        _held := coalesce((_portfolio -> _symbol ->> 'qty')::NUMERIC, 0);
        _max_more := GREATEST(floor(_cap * _wealth / _execution_price) - _held, 0);

        IF p_qty > _max_more THEN
            RAISE EXCEPTION 'Tek bir hissede toplam varlığının en fazla %%%''ini tutabilirsin. Bu hisseden şu an en fazla % adet daha alabilirsin.',
                ROUND(_cap * 100), _max_more;
        END IF;
    END IF;

    SELECT impact_depth INTO _depth
    FROM public.stock_types
    WHERE risk_type = _stock.risk_type;

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
        -- Etkinin bir kismi sonraki dakikalarda geri donmek uzere kaydedilir.
        impact_pending = ROUND(
            impact_pending
            + coalesce(_cfg.impact_revert_share, 0.50) * ln(_new_price / _execution_price),
            6
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

-- Acilista piyasa geneli durus ve bekleyen etki de sifirlanir.
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
            impact_pending = 0,
            updated_at = now()
        WHERE symbol IS NOT NULL;
    ELSE
        -- Kapanista gunun degisimi ertesi sabaha kadar gorunur kalir.
        UPDATE public.stocks
        SET halt_until = NULL
        WHERE symbol IS NOT NULL;
    END IF;

    UPDATE public.market_settings
    SET is_market_open = p_is_market_open,
        halt_until = NULL,
        halt_level = CASE WHEN p_is_market_open THEN 0 ELSE halt_level END
    WHERE id = 1
    RETURNING * INTO _settings;

    RETURN _settings;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_market_open(BOOLEAN) FROM PUBLIC, anon, authenticated;

-- p_rules: {"max_position_pct": 0.40, "impact_revert_share": 0.50,
--           "market_breaker_levels": [{"drop": 0.07, "minutes": 15}, ...]}   (oranlar kesir)
CREATE OR REPLACE FUNCTION public.admin_save_market_rules(p_rules JSONB)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _cap NUMERIC := (p_rules ->> 'max_position_pct')::NUMERIC;
    _share NUMERIC := (p_rules ->> 'impact_revert_share')::NUMERIC;
    _levels JSONB := p_rules -> 'market_breaker_levels';
    _level JSONB;
    _previous NUMERIC := 0;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF _cap IS NULL OR _cap < 0.05 OR _cap > 1 THEN
        RAISE EXCEPTION 'Tek hissedeki en fazla pay %%5 ile %%100 arasında olmalı.';
    END IF;
    IF _share IS NULL OR _share < 0 OR _share > 1 THEN
        RAISE EXCEPTION 'Geri dönen etki %%0 ile %%100 arasında olmalı.';
    END IF;
    IF jsonb_typeof(_levels) IS DISTINCT FROM 'array' OR jsonb_array_length(_levels) = 0 THEN
        RAISE EXCEPTION 'Piyasa geneli devre kesici basamakları geçersiz.';
    END IF;

    FOR _level IN SELECT * FROM jsonb_array_elements(_levels) LOOP
        IF (_level ->> 'drop')::NUMERIC IS NULL
           OR (_level ->> 'drop')::NUMERIC <= _previous
           OR (_level ->> 'drop')::NUMERIC > 0.9
           OR (_level ->> 'minutes')::INTEGER IS NULL
           OR (_level ->> 'minutes')::INTEGER < 0
           OR (_level ->> 'minutes')::INTEGER > 600 THEN
            RAISE EXCEPTION 'Piyasa geneli devre kesici: düşüş yüzdeleri küçükten büyüğe sıralı, süreler 0 ile 600 dakika arasında olmalı.';
        END IF;
        _previous := (_level ->> 'drop')::NUMERIC;
    END LOOP;

    UPDATE public.engine_settings
    SET max_position_pct = _cap,
        impact_revert_share = _share,
        market_breaker_levels = _levels
    WHERE id = 1;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_save_market_rules(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_save_market_rules(JSONB) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT max_position_pct AS tek_hisse_siniri,
       impact_revert_share AS geri_donen_etki,
       market_breaker_levels AS piyasa_devre_kesici
FROM public.engine_settings
WHERE id = 1;
