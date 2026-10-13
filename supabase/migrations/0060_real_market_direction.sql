-- Piyasanin ortak yonu gercek borsaya baglanir.
--
-- Simdiye kadar butun hisseleri birlikte iten "piyasa faktoru" her dakika rastgele cekiliyordu.
-- Artik gercek borsa acikken (hafta ici 10:00-18:00) bu yon BIST 100 endeksinin gercek hareketinden gelir.
-- Her hissenin kendi dalgalanmasi, haber ve oyuncu etkisi, devre kesici ve tavan/taban aynen kalir.
-- Gercek borsa kapaliyken ya da veri gelmezse eski rastgele yon kullanilir. Hisse adlari degismez.
-- Veri Yahoo'dan gelir (XU100.IS, yaklasik 15 dakika gecikmeli), 5 dakikada bir okunur.

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS real_market_enabled BOOLEAN NOT NULL DEFAULT true;
ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS real_market_scale NUMERIC NOT NULL DEFAULT 1
        CHECK (real_market_scale >= 0 AND real_market_scale <= 5);

CREATE TABLE IF NOT EXISTS public.market_index (
    id             INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    last_price     NUMERIC,
    last_bar_at    TIMESTAMPTZ,
    day_change_pct NUMERIC,
    pending_return DOUBLE PRECISION NOT NULL DEFAULT 0,
    ticks_left     INTEGER NOT NULL DEFAULT 0,
    fetched_at     TIMESTAMPTZ,
    checked_at     TIMESTAMPTZ,
    ok             BOOLEAN,
    message        TEXT
);
INSERT INTO public.market_index (id) VALUES (1) ON CONFLICT (id) DO NOTHING;
ALTER TABLE public.market_index ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.market_index FROM anon, authenticated;

-- BIST 100'un son degerini okur; yeni bir veri noktasi geldiyse aradaki degisimi motora birakir.
CREATE OR REPLACE FUNCTION public.refresh_market_index()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _url CONSTANT TEXT := 'https://query1.finance.yahoo.com/v8/finance/spark?symbols=XU100.IS&range=1d&interval=5m';
    _status INTEGER;
    _body TEXT;
    _x JSONB;
    _last NUMERIC;
    _prev NUMERIC;
    _bar_at TIMESTAMPTZ;
    _old public.market_index%ROWTYPE;
    _r DOUBLE PRECISION := 0;
    _new_bar BOOLEAN := false;
BEGIN
    BEGIN
        BEGIN
            PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;

        SELECT r.status, r.content
        INTO _status, _body
        FROM extensions.http((
            'GET',
            _url,
            ARRAY[extensions.http_header('User-Agent', 'Mozilla/5.0')],
            NULL,
            NULL
        )::extensions.http_request) AS r;

        IF _status IS DISTINCT FROM 200 THEN
            RAISE EXCEPTION 'Yahoo HTTP durumu: %', _status;
        END IF;

        _x := _body::JSONB -> 'XU100.IS';

        -- Fiyati dolu olan son veri noktasi ve zamani
        SELECT (c.val #>> '{}')::NUMERIC, to_timestamp((t.val #>> '{}')::DOUBLE PRECISION)
        INTO _last, _bar_at
        FROM jsonb_array_elements(_x -> 'close') WITH ORDINALITY AS c(val, ord)
        JOIN jsonb_array_elements(_x -> 'timestamp') WITH ORDINALITY AS t(val, ord) ON t.ord = c.ord
        WHERE jsonb_typeof(c.val) = 'number'
        ORDER BY c.ord DESC
        LIMIT 1;

        IF coalesce(_last, 0) <= 0 OR _bar_at IS NULL THEN
            RAISE EXCEPTION 'Yahoo cevabinda BIST 100 degeri yok.';
        END IF;
        _prev := coalesce((_x ->> 'chartPreviousClose')::NUMERIC, (_x ->> 'previousClose')::NUMERIC);

        SELECT * INTO _old FROM public.market_index WHERE id = 1 FOR UPDATE;

        IF _old.last_bar_at IS NULL OR _bar_at > _old.last_bar_at THEN
            _new_bar := true;
            IF coalesce(_old.last_price, 0) > 0 THEN
                -- Bozuk veriye karsi: iki okuma arasinda %15'ten buyuk sicrama kabul edilmez.
                IF abs(_last / _old.last_price - 1) > 0.15 THEN
                    RAISE EXCEPTION 'BIST 100 bir anda %% 15ten fazla degisti; guncelleme reddedildi.';
                END IF;
                -- Gece ya da hafta sonu biriken acilis farki en fazla %3 olarak yansitilir.
                _r := GREATEST(-0.03, LEAST(0.03, ln((_last / _old.last_price)::DOUBLE PRECISION)));
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        UPDATE public.market_index
        SET checked_at = now(), ok = false, message = left(SQLERRM, 300)
        WHERE id = 1;
        RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;

    IF _new_bar THEN
        UPDATE public.market_index
        SET last_price = _last,
            last_bar_at = _bar_at,
            day_change_pct = CASE WHEN coalesce(_prev, 0) > 0 THEN ROUND((_last / _prev - 1) * 100, 2) END,
            -- Eskiden kalmis, dagitilmamis hareket yeni veriyle birlikte tasinmaz.
            pending_return = CASE WHEN fetched_at > now() - INTERVAL '20 minutes' THEN pending_return ELSE 0 END + _r,
            ticks_left = 5,
            fetched_at = now(),
            checked_at = now(),
            ok = true,
            message = NULL
        WHERE id = 1;
    ELSE
        UPDATE public.market_index
        SET checked_at = now(), ok = true, message = 'yeni veri yok'
        WHERE id = 1;
    END IF;

    RETURN jsonb_build_object('ok', true, 'new_bar', _new_bar, 'price', _last, 'bar_at', _bar_at, 'return', _r);
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_market_index() FROM PUBLIC, anon, authenticated;

-- Fiyat motoru: 0041'deki govdenin aynisi; yalnizca ortak yonun kaynagi eklendi.
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
    _idx public.market_index%ROWTYPE;
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

    -- Gercek borsa acikken ortak yon rastgele cekilis yerine BIST 100'un son hareketinden gelir:
    -- son okunan degisim, sonraki dakikalara esit paylarla dagitilir. Veri yoksa ya da eskiyse
    -- (aksam, hafta sonu, tatil, baglanti sorunu) yukaridaki rastgele cekilis gecerli kalir.
    IF coalesce(_cfg.real_market_enabled, false) THEN
        SELECT * INTO _idx FROM public.market_index WHERE id = 1 FOR UPDATE;
        IF FOUND AND _idx.ticks_left > 0 AND _idx.fetched_at > now() - INTERVAL '20 minutes' THEN
            _m := _idx.pending_return / _idx.ticks_left * coalesce(_cfg.real_market_scale, 1);
            UPDATE public.market_index
            SET pending_return = pending_return - pending_return / ticks_left,
                ticks_left = ticks_left - 1
            WHERE id = 1;
        END IF;
    END IF;

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

-- Oyuncu sayfasinin bilmesi gereken kurallar: gercek borsanin bugunku yonu de eklenir.
CREATE OR REPLACE FUNCTION public.get_game_rules()
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_build_object(
        'max_position_pct', e.max_position_pct,
        'daily_limit_pct', e.daily_limit_pct,
        'real_market', jsonb_build_object(
            'enabled', e.real_market_enabled,
            'live', e.real_market_enabled AND i.fetched_at > now() - INTERVAL '20 minutes',
            'day_change_pct', i.day_change_pct,
            'updated_at', i.fetched_at
        )
    )
    FROM public.engine_settings AS e
    LEFT JOIN public.market_index AS i ON i.id = 1
    WHERE e.id = 1;
$$;

REVOKE ALL ON FUNCTION public.get_game_rules() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_game_rules() TO anon, authenticated;

-- p_scale: gercek hareketin carpani (1 = oldugu gibi, 2 = iki kati, 0 = etkisiz).
CREATE OR REPLACE FUNCTION public.admin_set_real_market(p_enabled BOOLEAN, p_scale NUMERIC DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF p_enabled IS NULL THEN
        RAISE EXCEPTION 'Açık ya da kapalı seçilmeli.';
    END IF;
    IF p_scale IS NOT NULL AND (p_scale < 0 OR p_scale > 5) THEN
        RAISE EXCEPTION 'Çarpan 0 ile 5 arasında olmalı.';
    END IF;

    UPDATE public.engine_settings
    SET real_market_enabled = p_enabled,
        real_market_scale = coalesce(p_scale, real_market_scale)
    WHERE id = 1;

    RETURN (SELECT jsonb_build_object('enabled', real_market_enabled, 'scale', real_market_scale)
            FROM public.engine_settings WHERE id = 1);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_real_market(BOOLEAN, NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_real_market(BOOLEAN, NUMERIC) TO authenticated;

-- Hafta ici 10:00-18:55 (Turkiye) arasi 5 dakikada bir okunur.
SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'borsa-refresh-market-index';

SELECT cron.schedule(
    'borsa-refresh-market-index',
    '*/5 7-15 * * 1-5',
    $$ SELECT public.refresh_market_index(); $$
);

NOTIFY pgrst, 'reload schema';

-- Ilk okuma ve sonuc ("ok": true ise Yahoo'dan veri alinabildi)
SELECT public.refresh_market_index() AS ilk_okuma;
