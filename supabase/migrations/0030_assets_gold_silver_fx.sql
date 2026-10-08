-- Altin, gumus, dolar ve euro: fiyatlar Yahoo'dan 30 dakikada bir tek istekle cekilir.
-- Fiyati admin degistiremez, alim satim fiyati etkilemez, alis-satis farki (spread) uygulanir.

CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;

-- Dort fiyat tek satirda tutulur (her guncellemede tek realtime mesaji).
-- prices / prev_close: {"XAU": gram TL, "XAG": gram TL, "USD": TL, "EUR": TL}
CREATE TABLE IF NOT EXISTS public.asset_prices (
    id         INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    prices     JSONB NOT NULL DEFAULT '{}'::jsonb,
    prev_close JSONB NOT NULL DEFAULT '{}'::jsonb,
    spread     NUMERIC NOT NULL DEFAULT 0.005 CHECK (spread >= 0 AND spread < 0.5),
    updated_at TIMESTAMPTZ
);

INSERT INTO public.asset_prices (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Son cekme denemesinin durumu (realtime yayininda degil).
CREATE TABLE IF NOT EXISTS public.asset_fetch_status (
    id         INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    checked_at TIMESTAMPTZ,
    ok         BOOLEAN,
    message    TEXT
);

INSERT INTO public.asset_fetch_status (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.asset_transactions (
    id         BIGSERIAL PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    asset      TEXT NOT NULL,
    side       TEXT NOT NULL CHECK (side IN ('BUY', 'SELL')),
    quantity   NUMERIC(18,4) NOT NULL,
    price      NUMERIC(18,4) NOT NULL,
    total      NUMERIC(18,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_asset_transactions_user_created
    ON public.asset_transactions (user_id, created_at DESC);

ALTER TABLE public.asset_prices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asset_fetch_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asset_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.asset_prices REPLICA IDENTITY FULL;

DROP POLICY IF EXISTS "asset_prices herkes okur" ON public.asset_prices;
CREATE POLICY "asset_prices herkes okur"
    ON public.asset_prices FOR SELECT USING (true);

DROP POLICY IF EXISTS "asset_transactions_read_own" ON public.asset_transactions;
CREATE POLICY "asset_transactions_read_own"
    ON public.asset_transactions FOR SELECT TO authenticated
    USING (user_id = auth.uid());

REVOKE ALL ON public.asset_prices, public.asset_fetch_status, public.asset_transactions
    FROM anon, authenticated;
GRANT SELECT ON public.asset_prices TO anon, authenticated;
GRANT SELECT ON public.asset_transactions TO authenticated;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'asset_prices'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.asset_prices;
    END IF;
END
$$;

-- Oyuncunun elindeki varliklar: {"XAU": {"qty": 2.5, "cost": 16400.00}, ...}
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS assets JSONB NOT NULL DEFAULT '{}'::jsonb;

-- Yahoo spark cevabindan bir semboldeki son gecerli kapanis degerini okur.
CREATE OR REPLACE FUNCTION public.spark_last_close(p_json JSONB, p_symbol TEXT)
RETURNS NUMERIC
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT (e.val #>> '{}')::NUMERIC
    FROM jsonb_array_elements(p_json -> p_symbol -> 'close') WITH ORDINALITY AS e(val, ord)
    WHERE jsonb_typeof(e.val) = 'number'
    ORDER BY e.ord DESC
    LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.spark_last_close(JSONB, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_asset_prices()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _url CONSTANT TEXT := 'https://query1.finance.yahoo.com/v8/finance/spark?symbols=GC%3DF,SI%3DF,USDTRY%3DX,EURTRY%3DX&range=1d&interval=1d';
    _oz CONSTANT NUMERIC := 31.1034768;
    _status INTEGER;
    _body TEXT;
    _j JSONB;
    _gold NUMERIC;
    _silver NUMERIC;
    _usd NUMERIC;
    _eur NUMERIC;
    _gold_prev NUMERIC;
    _silver_prev NUMERIC;
    _usd_prev NUMERIC;
    _eur_prev NUMERIC;
    _prices JSONB;
    _prev JSONB;
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
        _gold := public.spark_last_close(_j, 'GC=F');
        _silver := public.spark_last_close(_j, 'SI=F');
        _usd := public.spark_last_close(_j, 'USDTRY=X');
        _eur := public.spark_last_close(_j, 'EURTRY=X');

        IF coalesce(_gold, 0) <= 0 OR coalesce(_silver, 0) <= 0
           OR coalesce(_usd, 0) <= 0 OR coalesce(_eur, 0) <= 0 THEN
            RAISE EXCEPTION 'Yahoo cevabinda eksik fiyat var.';
        END IF;

        _gold_prev := coalesce((_j -> 'GC=F' ->> 'chartPreviousClose')::NUMERIC, _gold);
        _silver_prev := coalesce((_j -> 'SI=F' ->> 'chartPreviousClose')::NUMERIC, _silver);
        _usd_prev := coalesce((_j -> 'USDTRY=X' ->> 'chartPreviousClose')::NUMERIC, _usd);
        _eur_prev := coalesce((_j -> 'EURTRY=X' ->> 'chartPreviousClose')::NUMERIC, _eur);

        _prices := jsonb_build_object(
            'XAU', ROUND(_gold * _usd / _oz, 2),
            'XAG', ROUND(_silver * _usd / _oz, 2),
            'USD', ROUND(_usd, 4),
            'EUR', ROUND(_eur, 4)
        );
        _prev := jsonb_build_object(
            'XAU', ROUND(_gold_prev * _usd_prev / _oz, 2),
            'XAG', ROUND(_silver_prev * _usd_prev / _oz, 2),
            'USD', ROUND(_usd_prev, 4),
            'EUR', ROUND(_eur_prev, 4)
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
    IF _asset NOT IN ('XAU', 'XAG', 'USD', 'EUR') THEN
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

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'borsa-refresh-asset-prices';

SELECT cron.schedule(
    'borsa-refresh-asset-prices',
    '*/30 * * * *',
    $$ SELECT public.refresh_asset_prices(); $$
);

NOTIFY pgrst, 'reload schema';

-- Ilk fiyatlari hemen cek; sonuc SQL Editor'de gorunur.
SELECT public.refresh_asset_prices() AS ilk_cekim;
