-- 1) On ikinci hisse: Filyos Lojistik (orta risk).
-- 2) Dort yeni doviz: sterlin, Isvicre frangi, Kanada dolari, Avustralya dolari.
--    Fiyatlar yine Yahoo'dan, 30 dakikada bir, tek istekle cekilir.

INSERT INTO public.stocks (symbol, name, color, current_price, previous_close, change, change_pct, shares, risk_type)
VALUES ('FLYLJ', 'Filyos Lojistik', '#0ea5e9', 58.40, 58.40, 0, 0, 100000, 'orta')
ON CONFLICT (symbol) DO NOTHING;

UPDATE public.stocks SET breaker_ref = current_price WHERE symbol = 'FLYLJ' AND breaker_ref IS NULL;

INSERT INTO public.price_history (symbol, price, recorded_at)
SELECT 'FLYLJ', 58.40, now()
WHERE NOT EXISTS (SELECT 1 FROM public.price_history WHERE symbol = 'FLYLJ');

CREATE OR REPLACE FUNCTION public.refresh_asset_prices()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _fx CONSTANT TEXT[] := ARRAY['USD', 'EUR', 'GBP', 'CHF', 'CAD', 'AUD'];
    _url CONSTANT TEXT := 'https://query1.finance.yahoo.com/v8/finance/spark?symbols=GC%3DF,SI%3DF,USDTRY%3DX,EURTRY%3DX,GBPTRY%3DX,CHFTRY%3DX,CADTRY%3DX,AUDTRY%3DX&range=1d&interval=1d';
    _oz CONSTANT NUMERIC := 31.1034768;
    _status INTEGER;
    _body TEXT;
    _j JSONB;
    _gold NUMERIC;
    _silver NUMERIC;
    _usd NUMERIC;
    _gold_prev NUMERIC;
    _silver_prev NUMERIC;
    _usd_prev NUMERIC;
    _rate NUMERIC;
    _rate_prev NUMERIC;
    _prices JSONB := '{}'::jsonb;
    _prev JSONB := '{}'::jsonb;
    _old JSONB;
    _key TEXT;
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

        _j := _body::JSONB;

        -- Dovizler: her biri icin <KOD>TRY=X
        FOREACH _key IN ARRAY _fx LOOP
            _rate := public.spark_last_close(_j, _key || 'TRY=X');
            IF coalesce(_rate, 0) <= 0 THEN
                RAISE EXCEPTION 'Yahoo cevabinda % fiyati yok.', _key;
            END IF;
            _rate_prev := coalesce((_j -> (_key || 'TRY=X') ->> 'chartPreviousClose')::NUMERIC, _rate);
            _prices := _prices || jsonb_build_object(_key, ROUND(_rate, 4));
            _prev := _prev || jsonb_build_object(_key, ROUND(_rate_prev, 4));
        END LOOP;

        -- Altin ve gumus: ons dolar fiyati * dolar kuru / 31,1
        _gold := public.spark_last_close(_j, 'GC=F');
        _silver := public.spark_last_close(_j, 'SI=F');
        IF coalesce(_gold, 0) <= 0 OR coalesce(_silver, 0) <= 0 THEN
            RAISE EXCEPTION 'Yahoo cevabinda altin veya gumus fiyati yok.';
        END IF;
        _usd := (_prices ->> 'USD')::NUMERIC;
        _usd_prev := (_prev ->> 'USD')::NUMERIC;
        _gold_prev := coalesce((_j -> 'GC=F' ->> 'chartPreviousClose')::NUMERIC, _gold);
        _silver_prev := coalesce((_j -> 'SI=F' ->> 'chartPreviousClose')::NUMERIC, _silver);

        _prices := _prices || jsonb_build_object(
            'XAU', ROUND(_gold * _usd / _oz, 2),
            'XAG', ROUND(_silver * _usd / _oz, 2)
        );
        _prev := _prev || jsonb_build_object(
            'XAU', ROUND(_gold_prev * _usd_prev / _oz, 2),
            'XAG', ROUND(_silver_prev * _usd_prev / _oz, 2)
        );

        -- Bozuk veriye karsi: tek guncellemede %20'den buyuk sicrama kabul edilmez.
        SELECT prices INTO _old FROM public.asset_prices WHERE id = 1;
        FOR _key IN SELECT jsonb_object_keys(_prices) LOOP
            IF coalesce((_old ->> _key)::NUMERIC, 0) > 0
               AND abs((_prices ->> _key)::NUMERIC / (_old ->> _key)::NUMERIC - 1) > 0.20 THEN
                RAISE EXCEPTION '% fiyati bir anda %% 20den fazla degisti; guncelleme reddedildi.', _key;
            END IF;
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        UPDATE public.asset_fetch_status
        SET checked_at = now(), ok = false, message = left(SQLERRM, 300)
        WHERE id = 1;
        RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;

    -- Fiyat degismediyse satira dokunulmaz; bos yere realtime mesaji gitmez.
    UPDATE public.asset_prices
    SET prices = _prices, prev_close = _prev, updated_at = now()
    WHERE id = 1
      AND (prices IS DISTINCT FROM _prices OR prev_close IS DISTINCT FROM _prev);

    UPDATE public.asset_fetch_status
    SET checked_at = now(), ok = true, message = NULL
    WHERE id = 1;

    RETURN jsonb_build_object('ok', true, 'prices', _prices);
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_asset_prices() FROM PUBLIC, anon, authenticated;

-- Alim satim: yalnizca izin verilen varlik listesi genisledi.
CREATE OR REPLACE FUNCTION public.execute_asset_trade(
    p_asset TEXT,
    p_quantity NUMERIC,
    p_side TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _asset TEXT := upper(trim(coalesce(p_asset, '')));
    _side TEXT := upper(trim(coalesce(p_side, '')));
    _qty NUMERIC(18,4) := ROUND(coalesce(p_quantity, 0), 4);
    _market_open BOOLEAN;
    _mid NUMERIC;
    _spread NUMERIC;
    _price NUMERIC(18,4);
    _total NUMERIC(18,2);
    _balance NUMERIC;
    _assets JSONB;
    _held NUMERIC;
    _cost NUMERIC;
    _new_held NUMERIC;
    _new_cost NUMERIC;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;
    IF _asset NOT IN ('XAU', 'XAG', 'USD', 'EUR', 'GBP', 'CHF', 'CAD', 'AUD') THEN
        RAISE EXCEPTION 'Gecersiz varlik: %', p_asset;
    END IF;
    IF _side NOT IN ('BUY', 'SELL') THEN
        RAISE EXCEPTION 'Islem yonu BUY veya SELL olmali.';
    END IF;
    IF _qty <= 0 THEN
        RAISE EXCEPTION 'Miktar sifirdan buyuk olmali.';
    END IF;

    SELECT is_market_open INTO _market_open
    FROM public.market_settings
    WHERE id = 1
    FOR SHARE;

    IF NOT FOUND OR NOT _market_open THEN
        RAISE EXCEPTION 'Piyasa kapalı. Alım-satım yapılamaz.';
    END IF;

    SELECT (prices ->> _asset)::NUMERIC, spread
    INTO _mid, _spread
    FROM public.asset_prices
    WHERE id = 1;

    IF coalesce(_mid, 0) <= 0 THEN
        RAISE EXCEPTION 'Fiyat henüz alınamadı. Biraz sonra tekrar deneyin.';
    END IF;

    -- Alirken yarim spread pahali, satarken yarim spread ucuz.
    -- Kurus yuvarlamasi her zaman oyuncunun aleyhine yapilir.
    IF _side = 'BUY' THEN
        _price := ROUND(_mid * (1 + _spread / 2), 4);
        _total := CEIL(_qty * _price * 100) / 100;
    ELSE
        _price := ROUND(_mid * (1 - _spread / 2), 4);
        _total := FLOOR(_qty * _price * 100) / 100;
    END IF;

    IF _total < 1 THEN
        RAISE EXCEPTION 'İşlem tutarı en az 1 TL olmalı.';
    END IF;

    SELECT balance, coalesce(assets, '{}'::jsonb)
    INTO _balance, _assets
    FROM public.users
    WHERE id = _uid
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profil bulunamadı.';
    END IF;

    _held := coalesce((_assets -> _asset ->> 'qty')::NUMERIC, 0);
    _cost := coalesce((_assets -> _asset ->> 'cost')::NUMERIC, 0);

    IF _side = 'BUY' THEN
        IF _balance < _total THEN
            RAISE EXCEPTION 'Yetersiz bakiye.';
        END IF;
        _balance := _balance - _total;
        _new_held := _held + _qty;
        _new_cost := _cost + _total;
    ELSE
        IF _held < _qty THEN
            RAISE EXCEPTION 'Elinizde yeterli miktar yok.';
        END IF;
        _balance := _balance + _total;
        _new_held := _held - _qty;
        _new_cost := CASE WHEN _new_held <= 0 THEN 0 ELSE ROUND(_cost * _new_held / _held, 2) END;
    END IF;

    IF _new_held > 0 THEN
        _assets := jsonb_set(_assets, ARRAY[_asset], jsonb_build_object('qty', _new_held, 'cost', _new_cost));
    ELSE
        _assets := _assets - _asset;
    END IF;

    UPDATE public.users
    SET balance = _balance, assets = _assets
    WHERE id = _uid;

    INSERT INTO public.asset_transactions (user_id, asset, side, quantity, price, total)
    VALUES (_uid, _asset, _side, _qty, _price, _total);

    RETURN jsonb_build_object(
        'balance', _balance,
        'assets', _assets,
        'asset', _asset,
        'side', _side,
        'quantity', _qty,
        'price', _price,
        'total', _total
    );
END;
$$;

REVOKE ALL ON FUNCTION public.execute_asset_trade(TEXT, NUMERIC, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_asset_trade(TEXT, NUMERIC, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Yeni fiyatlar hemen cekilir; sonucta "ok": true ve sekiz fiyat gorunmeli.
SELECT public.refresh_asset_prices() AS sonuc;
