-- 1) Piyasa saatleri gercek borsa gibi: hafta ici 10:00-18:00 (hafta sonu kapali).
-- 2) Komisyon orani ayarlanabilir; varsayilan binde 2 (%0,2). Onceden %1 idi.
--
-- Komisyonu kesen hesaplasma fonksiyonu (execute_trade) depoda olmayan eski bir fonksiyon ve sabit oran
-- kesiyor. Ona dokunulmaz: kestigi oran bu dosyada bir deneme islemiyle (geri alinir) olculur, alim-satim
-- fonksiyonu aradaki farki islemden once bakiyeye ekler.

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS commission_rate NUMERIC NOT NULL DEFAULT 0.002
        CHECK (commission_rate >= 0 AND commission_rate <= 0.05);
ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS legacy_commission_rate NUMERIC NOT NULL DEFAULT 0.01;

-- Gunde 8 saat = 480 dakika; dakikalik oynaklik buna gore olceklenir.
UPDATE public.engine_settings SET minutes_per_day = 480 WHERE id = 1;

-- Eski fonksiyonun kestigi orani olc: en zengin oyuncuya kucuk bir deneme alimi yapilir ve GERI ALINIR.
DO $$
DECLARE
    _uid UUID;
    _before NUMERIC;
    _after NUMERIC;
    _symbol VARCHAR(16);
    _price NUMERIC;
    _qty INTEGER;
    _rate NUMERIC;
    _note TEXT := 'olculemedi; varsayilan %1 kullaniliyor';
BEGIN
    BEGIN
        SELECT id, balance INTO _uid, _before FROM public.users WHERE balance >= 2000 ORDER BY balance DESC LIMIT 1;
        SELECT symbol, current_price INTO _symbol, _price FROM public.stocks WHERE current_price > 0 ORDER BY symbol LIMIT 1;
        _qty := GREATEST(1, floor(1000 / _price)::INTEGER);

        EXECUTE 'SELECT to_jsonb(t) FROM public.execute_trade($1::uuid, $2::varchar(16), $3::integer, $4::numeric, $5::text) AS t'
        USING _uid, _symbol, _qty, _price, 'BUY';

        SELECT balance INTO _after FROM public.users WHERE id = _uid;
        _rate := ROUND((_before - _after) / (_qty * _price) - 1, 3);
        RAISE EXCEPTION 'BORSA_SIM_ROLLBACK';
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM <> 'BORSA_SIM_ROLLBACK' THEN
            _note := 'olculemedi (' || left(SQLERRM, 120) || '); varsayilan %1 kullaniliyor';
        END IF;
    END;

    IF _rate IS NOT NULL AND _rate >= 0 AND _rate <= 0.05 THEN
        UPDATE public.engine_settings SET legacy_commission_rate = _rate WHERE id = 1;
        _note := 'olculdu: %' || trim(to_char(_rate * 100, 'FM990.0'));
    END IF;

    INSERT INTO public.engine_diagnostics (topic, summary)
    VALUES ('commission', jsonb_build_object('eski_oran', _note));
END
$$;

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
    _fee_adjust NUMERIC;
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

    -- Komisyon: hesaplasmayi yapan eski fonksiyon sabit bir oran (legacy_commission_rate) keser.
    -- Ayarlanan oranla arasindaki fark islemden once bakiyeye eklenir; oyuncudan net olarak
    -- commission_rate kadar komisyon kesilmis olur. Islem basarisiz olursa bu ekleme de geri alinir.
    _fee_adjust := ROUND(
        _trade_volume * (coalesce(_cfg.legacy_commission_rate, 0.01) - coalesce(_cfg.commission_rate, 0.002)),
        2
    );
    IF _fee_adjust > 0 THEN
        UPDATE public.users SET balance = balance + _fee_adjust WHERE id = p_user_id;
    END IF;

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
            CASE WHEN l.ticks_left > 0 THEN l.pending_return / l.ticks_left ELSE 0 END AS real_piece
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
            ticks_left = l.ticks_left - 1
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

-- Oyuncu sayfasinin bilmesi gereken kurallar: komisyon orani da eklenir.
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
        'commission_rate', LEAST(e.commission_rate, e.legacy_commission_rate),
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

-- Yonetici: komisyon orani (kesir; 0.002 = binde 2). Eski fonksiyonun kestigi orandan buyuk olamaz.
CREATE OR REPLACE FUNCTION public.admin_set_commission(p_rate NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _max NUMERIC;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    SELECT legacy_commission_rate INTO _max FROM public.engine_settings WHERE id = 1;
    IF p_rate IS NULL OR p_rate < 0 OR p_rate > _max THEN
        RAISE EXCEPTION 'Komisyon %%0 ile %%% arasında olmalı.', trim(to_char(_max * 100, 'FM990.0'));
    END IF;

    UPDATE public.engine_settings SET commission_rate = p_rate WHERE id = 1;
    RETURN p_rate;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_commission(NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_commission(NUMERIC) TO authenticated;

-- Acilis 10:00, kapanis 18:00 (Turkiye; UTC 07:00 ve 15:00), yalnizca hafta ici.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('borsa-market-open', 'borsa-market-close');

SELECT cron.schedule('borsa-market-open', '0 7 * * 1-5', $$ SELECT public.apply_market_open(true); $$);
SELECT cron.schedule('borsa-market-close', '0 15 * * 1-5', $$ SELECT public.apply_market_open(false); $$);

-- Su an yeni saatlerin disindaysa piyasa hemen kapanir.
DO $$
DECLARE
    _now TIMESTAMP := now() AT TIME ZONE 'Europe/Istanbul';
BEGIN
    IF extract(isodow FROM _now) > 5 OR extract(hour FROM _now) < 10 OR extract(hour FROM _now) >= 18 THEN
        PERFORM public.apply_market_open(false);
    END IF;
END
$$;

NOTIFY pgrst, 'reload schema';

-- Sonuc
SELECT r.konu, r.sonuc
FROM (
    SELECT 1 AS sira, 'Piyasa saatleri' AS konu,
           (SELECT string_agg(jobname || ' [' || schedule || ']', '; ' ORDER BY jobname)
            FROM cron.job WHERE jobname IN ('borsa-market-open', 'borsa-market-close')) AS sonuc
    UNION ALL
    SELECT 2, 'Piyasa su an', (SELECT CASE WHEN is_market_open THEN 'acik' ELSE 'kapali' END FROM public.market_settings WHERE id = 1)
    UNION ALL
    SELECT 3, 'Eski komisyon orani', (SELECT d.summary ->> 'eski_oran' FROM public.engine_diagnostics AS d WHERE d.topic = 'commission' ORDER BY d.id DESC LIMIT 1)
    UNION ALL
    SELECT 4, 'Yeni komisyon orani', (SELECT '%' || trim(to_char(commission_rate * 100, 'FM990.00')) FROM public.engine_settings WHERE id = 1)
) AS r
ORDER BY r.sira;
