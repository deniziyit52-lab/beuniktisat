-- Son degisikliklerin denetiminde bulunan dort eksik giderilir.
--
-- 1) ACIK: Bir oyuncu buyuk bir alimla fiyati yukseltip hemen yuksek fiyattan satarak, komisyon
--    dusurulduktan sonra her dongude para kazanabiliyordu. Artik gercek borsadaki gibi "fiyat kaymasi"
--    var: emir fiyati kendisi oynatir, oyuncu (yaklasik olarak) emirden onceki ve sonraki fiyatin
--    ortalamasindan islem yapar. Alim ve satis ayni egri uzerinden hesaplandigi icin dongunun tersi
--    ("sat, dusur, geri al") ve parca parca denemeler de kazandirmaz.
-- 2) Piyasa kapandiktan sonra gelen son dakikalarin gercek hareketi siliniyordu; artik ertesi seansin
--    basinda uygulanir. Oyun fiyati gercek getiriden kopmaz.
-- 3) Fiyat/Kazanc orani, karnede gorunen son 4 ceyregin karindan hesaplanir; zarar eden sirkette bos kalir.
-- 4) "Oyunu Sifirla" grafik gecmisini bos birakmak yerine gercek gecmisten yeniden yazar.

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS slippage_enabled BOOLEAN NOT NULL DEFAULT true;

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
    _fee NUMERIC;
    _slip NUMERIC := 0;
    _impact_raw NUMERIC;
    _need NUMERIC;
    _slip_on BOOLEAN;
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
        WHERE u.id = p_user_id
        FOR UPDATE;

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
            -- Alim ve satis ayni egrinin iki yonudur: ayni adedi geri almak fiyati eski yerine getirir.
            CASE WHEN _side = 'BUY' THEN _execution_price / (1 - LEAST(_impact_fraction, 0.5))
                 ELSE _execution_price / (1 + _impact_fraction)
            END
        ),
        4
    );

    -- Fiyat kaymasi: emir fiyati kendisi oynatir; oyuncu emrin basindaki fiyattan degil, emir ilerledikce
    -- olusan fiyatlarin ortalamasindan islem yapmis sayilir (yaklasik olarak emirden onceki ve sonraki
    -- fiyatin ortasi). Hesaplasma eskisi gibi emirden onceki fiyattan yapilir, aradaki fark islemden
    -- sonra bakiyeden dusulur.
    --
    -- Alim fiyati 1/(1 - etki) ile, satis 1/(1 + etki) ile carpar; ikisi ayni egrinin iki yonudur
    -- (1/fiyat, alinan-satilan adetle dogrusal degisir). Kayma da bu egrinin altindaki alandan hesaplanir:
    --   alim maliyeti = -derinlik x ln(1 - tutar/derinlik),  satis geliri = derinlik x ln(1 + tutar/derinlik)
    -- Bu yuzden hicbir al-sat sirasi (al-sat, sat-geri al, parca parca) komisyondan once bile kazandirmaz.
    -- Etki siniri (max_trade_impact) yalnizca fiyatin ne kadar oynayacagini sinirlar; maliyet emrin
    -- tamamina gore hesaplanir, yoksa "kucuk emirlerle yukselt, tek dev emirle sat" yolu acik kalirdi.
    _slip_on := coalesce(_cfg.slippage_enabled, true);
    _fee := ROUND(_trade_volume * coalesce(_cfg.commission_rate, 0.002), 2);
    _impact_raw := _trade_volume / coalesce(_depth, 5000000);
    IF _slip_on THEN
        IF _impact_raw >= 0.5 THEN
            RAISE EXCEPTION 'Bu emir tek seferde verilemeyecek kadar büyük. Daha küçük parçalara bölerek ver.';
        END IF;
        _slip := GREATEST(ROUND(
            CASE WHEN _side = 'BUY'
                 THEN -coalesce(_depth, 5000000) * ln(1 - _impact_raw) - _trade_volume
                 ELSE _trade_volume - coalesce(_depth, 5000000) * ln(1 + _impact_raw)
            END,
            2
        ), 0);
    END IF;
    IF _slip_on AND _side = 'BUY' THEN
        _need := _trade_volume + _fee + _slip;
        IF _balance < _need THEN
            RAISE EXCEPTION 'Bakiye yetersiz. Bu emir için komisyon ve fiyat kayması dahil yaklaşık % ₺ gerekiyor.',
                ROUND(_need, 2);
        END IF;
    END IF;

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

    -- Tavan/taban kurali fiyati sinirladiysa, geri donecek etki de gercekten olusan harekete gore duzeltilir.
    IF _updated_stock.current_price IS DISTINCT FROM _new_price THEN
        UPDATE public.stocks
        SET impact_pending = ROUND(
                impact_pending
                + coalesce(_cfg.impact_revert_share, 0.50)
                  * (ln(_updated_stock.current_price / _execution_price) - ln(_new_price / _execution_price)),
                6
            )
        WHERE symbol = _symbol;
    END IF;

    -- Fiyat kaymasi bakiyeden dusulur. Alimda on denetim sayesinde bakiye yeter; yuvarlamadan kalan
    -- kurus farki bakiyeyi eksiye dusurmesin.
    IF _slip > 0 THEN
        UPDATE public.users SET balance = GREATEST(balance - _slip, 0) WHERE id = p_user_id RETURNING balance INTO _balance;
        IF jsonb_typeof(_trade_result) = 'object' THEN
            _trade_result := jsonb_set(_trade_result, '{balance}', to_jsonb(_balance), true);
        END IF;
    END IF;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    VALUES (_symbol, _updated_stock.current_price, now());

    _circuit_breaker_triggered :=
        _updated_stock.halt_until IS NOT NULL AND _updated_stock.halt_until > now();

    RETURN jsonb_build_object(
        'trade', _trade_result,
        'execution_price', _execution_price,
        -- Oyuncunun odedigi / aldigi kesin tutarlar (komisyon ve fiyat kaymasi dahil)
        'fee', _fee,
        'slippage', _slip,
        'slippage_pct', CASE WHEN _trade_volume > 0 THEN ROUND(_slip / _trade_volume * 100, 3) ELSE 0 END,
        'total', ROUND(CASE WHEN _side = 'BUY' THEN _trade_volume + _fee + _slip ELSE _trade_volume - _fee - _slip END, 2),
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
        'new_price', _updated_stock.current_price,
        'stock', to_jsonb(_updated_stock)
    );
END;
$$;

REVOKE ALL ON FUNCTION public.execute_hybrid_trade(UUID, VARCHAR(16), INTEGER, TEXT)
    FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_hybrid_trade(UUID, VARCHAR(16), INTEGER, TEXT)
    TO authenticated;

CREATE OR REPLACE FUNCTION public.refresh_stock_links()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _j JSONB;
    _link RECORD;
    _x JSONB;
    _last NUMERIC;
    _bar_at TIMESTAMPTZ;
    _r DOUBLE PRECISION;
    _updated INTEGER := 0;
    _skipped TEXT[] := '{}';
BEGIN
    BEGIN
        SELECT public.fetch_yahoo_spark(array_agg(DISTINCT yahoo_symbol), '1d', '5m') INTO _j FROM public.stock_links;
        IF _j IS NULL OR jsonb_typeof(_j) <> 'object' THEN
            RAISE EXCEPTION 'Yahoo cevabi bos.';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        UPDATE public.stock_link_status SET checked_at = now(), ok = false, message = left(SQLERRM, 300) WHERE id = 1;
        RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;

    FOR _link IN SELECT * FROM public.stock_links ORDER BY symbol FOR UPDATE LOOP
        BEGIN
            _x := _j -> _link.yahoo_symbol;
            _last := NULL;
            _bar_at := NULL;

            -- Fiyati dolu olan son veri noktasi ve zamani
            SELECT (c.val #>> '{}')::NUMERIC, to_timestamp((t.val #>> '{}')::DOUBLE PRECISION)
            INTO _last, _bar_at
            FROM jsonb_array_elements(_x -> 'close') WITH ORDINALITY AS c(val, ord)
            JOIN jsonb_array_elements(_x -> 'timestamp') WITH ORDINALITY AS t(val, ord) ON t.ord = c.ord
            WHERE jsonb_typeof(c.val) = 'number'
            ORDER BY c.ord DESC
            LIMIT 1;

            IF coalesce(_last, 0) <= 0 OR _bar_at IS NULL THEN
                RAISE EXCEPTION 'deger yok';
            END IF;
            IF _link.last_bar_at IS NOT NULL AND _bar_at <= _link.last_bar_at THEN
                CONTINUE;
            END IF;

            _r := 0;
            IF coalesce(_link.last_price, 0) > 0 THEN
                -- Bozuk veriye (ya da hisse bolunmesine) karsi: %25'ten buyuk sicrama hareket sayilmaz.
                IF abs(_last / _link.last_price - 1) <= 0.25 THEN
                    -- Gercek borsanin gunluk siniri %10'dur; acilis farki da en fazla bu kadar yansir.
                    _r := GREATEST(-0.10, LEAST(0.10, ln((_last / _link.last_price)::DOUBLE PRECISION)));
                END IF;
            END IF;

            UPDATE public.stock_links
            SET last_price = _last,
                last_bar_at = _bar_at,
                -- Henuz oyuna yansimamis gercek hareket (ornegin piyasa kapandiktan sonra gelen son dakikalar)
                -- silinmez, bir sonraki seansin basinda uygulanir. Boylece oyun gercek getiriden kopmaz.
                pending_return = GREATEST(-0.25, LEAST(0.25, pending_return + _r)),
                ticks_left = 5,
                fetched_at = now()
            WHERE symbol = _link.symbol;
            _updated := _updated + 1;
        EXCEPTION WHEN OTHERS THEN
            _skipped := array_append(_skipped, _link.symbol::TEXT);
        END;
    END LOOP;

    UPDATE public.stock_link_status
    SET checked_at = now(), ok = true,
        message = _updated || ' hisse guncellendi'
                  || CASE WHEN cardinality(_skipped) > 0 THEN '; okunamayan: ' || array_to_string(_skipped, ', ') ELSE '' END
    WHERE id = 1;

    RETURN jsonb_build_object('ok', true, 'updated', _updated, 'skipped', to_jsonb(_skipped));
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_stock_links() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_stock_financials()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _types CONSTANT TEXT := 'quarterlyTotalRevenue,quarterlyOperatingIncome,quarterlyNetIncome,quarterlyTotalAssets,quarterlyStockholdersEquity,'
        || 'quarterlyTotalDebt,quarterlyTotalLiabilitiesNetMinorityInterest,quarterlyCashAndCashEquivalents,'
        || 'quarterlyOrdinarySharesNumber,trailingPeRatio';
    _link RECORD;
    _status INTEGER;
    _body TEXT;
    _j JSONB;
    _quarters JSONB;
    _latest DATE;
    _old_latest DATE;
    _assets NUMERIC;
    _liab NUMERIC;
    _debt NUMERIC;
    _equity NUMERIC;
    _cash NUMERIC;
    _shares NUMERIC;
    _pe NUMERIC;
    _rev4 NUMERIC;
    _net4 NUMERIC;
    _n4 INTEGER;
    _cap NUMERIC;
    _name TEXT;
    _updated INTEGER := 0;
    _failed TEXT[] := '{}';
BEGIN
    BEGIN
        PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    FOR _link IN SELECT symbol, yahoo_symbol, last_price, financials FROM public.stock_links ORDER BY symbol LOOP
        BEGIN
            SELECT r.status, r.content
            INTO _status, _body
            FROM extensions.http((
                'GET',
                'https://query1.finance.yahoo.com/ws/fundamentals-timeseries/v1/finance/timeseries/' || _link.yahoo_symbol
                    || '?symbol=' || _link.yahoo_symbol || '&type=' || _types
                    || '&period1=' || floor(extract(epoch FROM now() - INTERVAL '800 days'))::BIGINT
                    || '&period2=' || floor(extract(epoch FROM now()))::BIGINT,
                ARRAY[extensions.http_header('User-Agent', 'Mozilla/5.0')],
                NULL,
                NULL
            )::extensions.http_request) AS r;

            IF _status IS DISTINCT FROM 200 THEN
                RAISE EXCEPTION 'HTTP %', _status;
            END IF;
            _j := _body::JSONB;

            -- Son 4 ceyrek: satislar ve net kar (eskiden yeniye)
            SELECT jsonb_agg(jsonb_build_object('d', q.as_of, 'rev', q.rev, 'op', q.op, 'net', q.net) ORDER BY q.as_of),
                   max(q.as_of), sum(q.rev), sum(q.net), count(*)
            INTO _quarters, _latest, _rev4, _net4, _n4
            FROM (
                SELECT coalesce(r.as_of, n.as_of) AS as_of, r.val AS rev, n.val AS net, o.val AS op
                FROM public.yahoo_series(_j, 'quarterlyTotalRevenue') AS r
                FULL JOIN public.yahoo_series(_j, 'quarterlyNetIncome') AS n ON n.as_of = r.as_of
                -- Faaliyet kari: sirketin asil isinden kazandigi para (bankalarda bulunmayabilir).
                LEFT JOIN public.yahoo_series(_j, 'quarterlyOperatingIncome') AS o ON o.as_of = coalesce(r.as_of, n.as_of)
                ORDER BY 1 DESC
                LIMIT 4
            ) AS q;

            IF _latest IS NULL THEN
                RAISE EXCEPTION 'veri yok';
            END IF;

            SELECT val INTO _assets FROM public.yahoo_series(_j, 'quarterlyTotalAssets') ORDER BY as_of DESC LIMIT 1;
            SELECT val INTO _liab FROM public.yahoo_series(_j, 'quarterlyTotalLiabilitiesNetMinorityInterest') ORDER BY as_of DESC LIMIT 1;
            SELECT val INTO _debt FROM public.yahoo_series(_j, 'quarterlyTotalDebt') ORDER BY as_of DESC LIMIT 1;
            SELECT val INTO _equity FROM public.yahoo_series(_j, 'quarterlyStockholdersEquity') ORDER BY as_of DESC LIMIT 1;
            SELECT val INTO _cash FROM public.yahoo_series(_j, 'quarterlyCashAndCashEquivalents') ORDER BY as_of DESC LIMIT 1;
            SELECT val INTO _shares FROM public.yahoo_series(_j, 'quarterlyOrdinarySharesNumber') ORDER BY as_of DESC LIMIT 1;
            SELECT val INTO _pe FROM public.yahoo_series(_j, 'trailingPeRatio') ORDER BY as_of DESC LIMIT 1;

            _cap := _link.last_price * _shares;
            -- Fiyat/Kazanc, tabloda gorunen son 4 ceyregin net karindan hesaplanir ki karneyle tutsun;
            -- sirket bu donemde zarar ettiyse hesaplanmaz. 4 ceyrek yoksa Yahoo'nun hazir degeri kullanilir.
            IF _n4 = 4 THEN
                _pe := CASE WHEN _net4 > 0 AND _cap > 0 THEN _cap / _net4 END;
            END IF;

            _old_latest := (_link.financials ->> 'latest')::DATE;

            UPDATE public.stock_links
            SET financials = jsonb_build_object(
                    'latest', _latest,
                    'quarters', _quarters,
                    'assets', _assets,
                    'liabilities', coalesce(_liab, _assets - _equity),
                    'equity', _equity,
                    'cash', _cash,
                    'pe', CASE WHEN _pe > 0 AND _pe < 1000 THEN ROUND(_pe, 1) END,
                    'pb', CASE WHEN _cap > 0 AND _equity > 0 THEN ROUND(_cap / _equity, 2) END,
                    'margin', CASE WHEN _rev4 > 0 AND _net4 IS NOT NULL THEN ROUND(_net4 / _rev4 * 100, 1) END,
                    'debt_equity', CASE WHEN _equity > 0 AND coalesce(_liab, _assets - _equity) IS NOT NULL
                                        THEN ROUND(coalesce(_liab, _assets - _equity) / _equity, 2) END
                ),
                financials_at = now()
            WHERE symbol = _link.symbol;
            _updated := _updated + 1;

            -- Yeni bir ceyrek aciklandiysa haber akisina dusulur (ilk yuklemede degil).
            IF _old_latest IS NOT NULL AND _latest > _old_latest THEN
                SELECT name INTO _name FROM public.stocks WHERE symbol = _link.symbol;
                INSERT INTO public.news_feed (id, title, summary, stock_symbol, impact_pct, created_at)
                VALUES (
                    floor(extract(epoch FROM clock_timestamp()) * 1000000)::BIGINT,
                    '📑 ' || coalesce(_name, _link.symbol) || ' yeni bilançosunu açıkladı',
                    'Şirketin son çeyrek mali tabloları yayınlandı. Satışlarını, kârını ve borçluluğunu hissenin "Şirket Karnesi" bölümünden inceleyebilirsin.',
                    _link.symbol,
                    0,
                    now()
                );
            END IF;
        EXCEPTION WHEN OTHERS THEN
            _failed := array_append(_failed, _link.symbol::TEXT);
        END;
    END LOOP;

    RETURN jsonb_build_object('ok', _updated > 0, 'updated', _updated, 'failed', to_jsonb(_failed));
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_stock_financials() FROM PUBLIC, anon, authenticated;

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
    DELETE FROM public.daily_quiz_attempts WHERE true;
    DELETE FROM public.user_badges WHERE true;
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

    -- Grafik gecmisi, bagli gercek hisselerin gecmisinden yeniden yazilir; golge fiyat guncel fiyattan baslar.
    BEGIN
        UPDATE public.stock_links AS l
        SET shadow_price = s.current_price
        FROM public.stocks AS s
        WHERE s.symbol = l.symbol;
        PERFORM public.rebuild_price_history_from_real();
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    RETURN jsonb_build_object('users', _users);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_game() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_game() TO authenticated;

-- Oyuncu sayfasinin bilmesi gereken kurallar: fiyat kaymasini onceden gosterebilmek icin derinlikler eklenir.
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
        'breaker_pct', e.breaker_pct,
        'commission_rate', LEAST(e.commission_rate, e.legacy_commission_rate),
        'slippage', e.slippage_enabled,
        'impact', jsonb_build_object(
            'max', e.max_trade_impact,
            'depth', (SELECT jsonb_object_agg(t.risk_type, t.impact_depth) FROM public.stock_types AS t)
        ),
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

-- Yonetici: fiyat kaymasini ac/kapat.
CREATE OR REPLACE FUNCTION public.admin_set_slippage(p_enabled BOOLEAN)
RETURNS BOOLEAN
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
    UPDATE public.engine_settings SET slippage_enabled = p_enabled WHERE id = 1;
    RETURN p_enabled;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_slippage(BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_slippage(BOOLEAN) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Mali tablolar yeni F/K hesabiyla yenilenir: "updated" 12 olmali.
SELECT public.refresh_stock_financials() AS mali_tablolar;
