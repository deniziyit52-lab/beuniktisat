-- Oyun fiyati gercek hissenin izinden kopmasin.
--
-- Oyun, bagli gercek hissenin yuzde degisimini uyguluyor; ustune binen kucuk rastgele oynama ve oyuncu
-- etkisi zamanla birikip oyundaki getiriyi gercek getiriden uzaklastirabiliyordu. Artik her hisse icin bir
-- "golge fiyat" tutulur (yalnizca gercek hareketle oynayan fiyat) ve oyun fiyati her dakika aradaki farkin
-- kucuk bir kismi kadar ona geri cekilir. Buyuk bir alim-satim ya da haber fiyati yine oynatir, ama etkisi
-- kalici olmaz; fark birikmez.

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS link_pull_rate NUMERIC NOT NULL DEFAULT 0.03
        CHECK (link_pull_rate >= 0 AND link_pull_rate <= 0.5);

ALTER TABLE public.stock_links ADD COLUMN IF NOT EXISTS shadow_price NUMERIC;

-- Baslangic: golge fiyat bugunku oyun fiyatidir (bugune kadar birikmis fark sifir sayilir).
UPDATE public.stock_links AS l
SET shadow_price = s.current_price
FROM public.stocks AS s
WHERE s.symbol = l.symbol AND l.shadow_price IS NULL;

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
    _link_on BOOLEAN;
    _quiet DOUBLE PRECISION;
    _pull DOUBLE PRECISION;
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
    -- Hisseler gercek hisselere bagliyken rastgele kisim kisilir ve ani soklar kapatilir;
    -- fiyati asil oynatan, bagli gercek hissenin hareketi olur.
    _link_on := coalesce(_cfg.stock_link_enabled, false);
    _quiet := CASE WHEN _link_on THEN coalesce(_cfg.quiet_vol_scale, 0.15)::DOUBLE PRECISION ELSE 1 END;
    _pull := CASE WHEN _link_on THEN coalesce(_cfg.link_pull_rate, 0.03)::DOUBLE PRECISION ELSE 0 END;
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
            (NOT _link_on AND random() < t.shock_per_day::DOUBLE PRECISION / _n) AS shocked,
            (CASE WHEN random() < 0.5 THEN -1 ELSE 1 END)
                * (t.shock_min::DOUBLE PRECISION
                   + random() * (t.shock_max - t.shock_min)::DOUBLE PRECISION) AS shock,
            -- Bagli gercek hisseden taze veri varsa bu dakikaya dusen payi.
            coalesce(_link_on AND l.ticks_left > 0 AND l.fetched_at > now() - INTERVAL '20 minutes', false) AS linked,
            CASE WHEN l.ticks_left > 0 THEN l.pending_return / l.ticks_left ELSE 0 END AS real_piece,
            -- Golge fiyat: hisse yalnizca gercek hareketle oynasaydi olacagi fiyat.
            l.shadow_price::DOUBLE PRECISION AS shadow
        FROM public.stocks AS s
        JOIN public.stock_types AS t ON t.risk_type = s.risk_type
        LEFT JOIN public.stock_links AS l ON l.symbol = s.symbol
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
                    + vol_min * vol_mult * _quiet * gauss
                    -- Gercek veri varken yon bagli hisseden gelir (piyasanin genel yonu onun icindedir);
                    -- yokken (aksam, hafta sonu) kisilmis ortak yon kullanilir.
                    + CASE WHEN linked THEN real_piece ELSE beta * _m * _quiet END
                    - 0.5 * ((vol_min * vol_mult * _quiet) ^ 2
                             + CASE WHEN linked THEN 0 ELSE (beta * _sigma_m_min * _quiet) ^ 2 END)
                    + CASE WHEN shocked THEN shock ELSE 0 END
                    -- Geri cekme: rastgele oynama ve oyuncu etkisiyle golge fiyattan uzaklasan fiyat,
                    -- her dakika aradaki farkin kucuk bir kismi kadar ona dogru doner.
                    + CASE WHEN shadow > 0 AND price > 0
                           THEN _pull * ln(shadow / price)
                           ELSE 0 END
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
    consumed AS (
        -- Kullanilan pay bagli hissenin bekleyen hareketinden dusulur (durdurulmus hisseninki bekler).
        UPDATE public.stock_links AS l
        SET pending_return = l.pending_return - l.pending_return / l.ticks_left,
            ticks_left = l.ticks_left - 1,
            shadow_price = ROUND((l.shadow_price * exp(l.pending_return / l.ticks_left))::NUMERIC, 6)
        FROM draws AS d
        WHERE d.symbol = l.symbol AND d.linked
        RETURNING 1
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
                            ELSE 'gün sonuna kadar durduruldu; piyasa bir sonraki iş günü 10:00''da açılacak.'
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

-- Yonetici: baglama, rastgele kismin payi ve geri cekme hizi (dakikada farkin ne kadari kapansin).
DROP FUNCTION IF EXISTS public.admin_set_stock_links(BOOLEAN, NUMERIC);
CREATE OR REPLACE FUNCTION public.admin_set_stock_links(p_enabled BOOLEAN, p_quiet NUMERIC DEFAULT NULL, p_pull NUMERIC DEFAULT NULL)
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
    IF p_quiet IS NOT NULL AND (p_quiet < 0 OR p_quiet > 1) THEN
        RAISE EXCEPTION 'Rastgele kısmın payı %%0 ile %%100 arasında olmalı.';
    END IF;
    IF p_pull IS NOT NULL AND (p_pull < 0 OR p_pull > 0.5) THEN
        RAISE EXCEPTION 'Geri çekme hızı %%0 ile %%50 arasında olmalı.';
    END IF;

    UPDATE public.engine_settings
    SET stock_link_enabled = p_enabled,
        quiet_vol_scale = coalesce(p_quiet, quiet_vol_scale),
        link_pull_rate = coalesce(p_pull, link_pull_rate)
    WHERE id = 1;

    RETURN (SELECT jsonb_build_object('enabled', stock_link_enabled, 'quiet', quiet_vol_scale, 'pull', link_pull_rate)
            FROM public.engine_settings WHERE id = 1);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_stock_links(BOOLEAN, NUMERIC, NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_stock_links(BOOLEAN, NUMERIC, NUMERIC) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Sonuc: her hissenin oyun fiyati ile golge fiyati (ilk calistirmada ayni olmali)
SELECT l.symbol, s.current_price AS oyun_fiyati, l.shadow_price AS golge_fiyat
FROM public.stock_links AS l
JOIN public.stocks AS s ON s.symbol = l.symbol
ORDER BY l.symbol;
