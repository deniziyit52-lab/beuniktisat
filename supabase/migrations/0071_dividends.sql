-- Temettu: izlenen gercek sirket temettu dagittiginda, oyundaki hisseyi elinde tutanlara ayni oranda nakit yatar.
--
-- Neden gerekli: gercek hisse temettu gunu temettu kadar ucuzlar ve oyun fiyati bunu izler. Karsiligi
-- odenmezse oyuncu o gun sebepsiz zarar eder.
--
-- Nasil calisir: dagitim gunu sabahi (piyasa acilmadan) hisse fiyati temettu orani kadar dusurulur ve ayni
-- anda hisseyi tutan herkese "adet x fiyat x oran" kadar nakit yatar; toplam varlik degismez. Gercek
-- hissenin o sabahki dususu sonradan geldiginde ikinci kez uygulanmasin diye stock_links.pending_return'e
-- ters yonde yazilir. Fiyat ve odeme ayni anda yapildigi icin "temettuyu al, dusmeden sat" yapilamaz.
-- Bilgi gec gelirse (gercek dusus oyuna coktan yansimissa) fiyata dokunulmaz, yalnizca nakit yatar.
--
-- Hangi gercek sirketin izlendigi yine gizlidir; bu tablolarda gercek kod ya da hisse basi tutar tutulmaz.

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS dividends_enabled BOOLEAN NOT NULL DEFAULT true,
    -- Bu tarihten onceki dagitimlar odenmez (kurulumdan onceki temettuler geriye donuk yatmasin).
    ADD COLUMN IF NOT EXISTS dividends_since DATE NOT NULL DEFAULT ((now() AT TIME ZONE 'Europe/Istanbul')::date);

-- Son 12 ayda dagitilan temettunun guncel fiyata orani (%); Sirket Karnesi'nde gosterilir.
ALTER TABLE public.stock_links
    ADD COLUMN IF NOT EXISTS dividend_yield NUMERIC;

-- Dagitim kaydi (hisse basina bir gun bir kez).
CREATE TABLE IF NOT EXISTS public.stock_dividends (
    symbol TEXT NOT NULL,
    ex_date DATE NOT NULL,
    yield_pct NUMERIC NOT NULL,
    price_adjusted BOOLEAN NOT NULL DEFAULT false,
    players INTEGER NOT NULL DEFAULT 0,
    total NUMERIC NOT NULL DEFAULT 0,
    paid_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (symbol, ex_date)
);
ALTER TABLE public.stock_dividends ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.stock_dividends FROM PUBLIC, anon, authenticated;

-- Oyuncuya yatan temettuler; oyuncu yalnizca kendininkini gorur.
CREATE TABLE IF NOT EXISTS public.dividend_payments (
    id BIGSERIAL PRIMARY KEY,
    user_id UUID NOT NULL,
    symbol TEXT NOT NULL,
    ex_date DATE NOT NULL,
    qty NUMERIC NOT NULL,
    amount NUMERIC NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS dividend_payments_user_idx ON public.dividend_payments (user_id, created_at DESC);
ALTER TABLE public.dividend_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.dividend_payments FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.dividend_payments TO authenticated;
DROP POLICY IF EXISTS dividend_payments_select_own ON public.dividend_payments;
CREATE POLICY dividend_payments_select_own ON public.dividend_payments
    FOR SELECT TO authenticated USING (user_id = auth.uid());

-- Tek bir dagitimi oder. p_adjust_price: gercek dusus oyuna henuz yansimadiysa true.
CREATE OR REPLACE FUNCTION public.pay_stock_dividend(p_symbol TEXT, p_ex_date DATE, p_yield NUMERIC, p_adjust_price BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _stock public.stocks%ROWTYPE;
    _after public.stocks%ROWTYPE;
    _price NUMERIC;
    _new NUMERIC;
    _ratio NUMERIC;
    _players INTEGER := 0;
    _total NUMERIC := 0;
BEGIN
    IF p_yield IS NULL OR p_yield <= 0 OR p_yield > 0.15 THEN
        RAISE EXCEPTION 'Temettu orani gecersiz: %', p_yield;
    END IF;

    SELECT * INTO _stock FROM public.stocks WHERE symbol = p_symbol FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', p_symbol;
    END IF;
    _price := _stock.current_price;

    -- Ayni dagitim ikinci kez odenmez.
    INSERT INTO public.stock_dividends (symbol, ex_date, yield_pct, price_adjusted)
    VALUES (p_symbol, p_ex_date, ROUND(p_yield * 100, 2), coalesce(p_adjust_price, false))
    ON CONFLICT DO NOTHING;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('paid', false);
    END IF;

    -- Hisseyi elinde tutan herkese nakit: adet x (dusmeden onceki) fiyat x oran.
    WITH holders AS (
        SELECT u.id,
               (u.portfolio -> p_symbol ->> 'qty')::NUMERIC AS qty,
               ROUND((u.portfolio -> p_symbol ->> 'qty')::NUMERIC * _price * p_yield, 2) AS amount
        FROM public.users AS u
        WHERE jsonb_typeof(u.portfolio) = 'object'
          AND coalesce((u.portfolio -> p_symbol ->> 'qty')::NUMERIC, 0) > 0
        FOR UPDATE
    ), credited AS (
        UPDATE public.users AS u
        SET balance = ROUND(u.balance + h.amount, 2)
        FROM holders AS h
        WHERE u.id = h.id AND h.amount > 0
        RETURNING h.id, h.qty, h.amount
    ), logged AS (
        INSERT INTO public.dividend_payments (user_id, symbol, ex_date, qty, amount)
        SELECT c.id, p_symbol, p_ex_date, c.qty, c.amount FROM credited AS c
        RETURNING amount
    )
    SELECT count(*), coalesce(sum(amount), 0) INTO _players, _total FROM logged;

    IF coalesce(p_adjust_price, false) THEN
        _new := ROUND(GREATEST(1, _price * (1 - p_yield)), 4);
        UPDATE public.stocks
        SET current_price = _new,
            change = ROUND(_new - previous_close, 4),
            change_pct = ROUND(CASE WHEN previous_close = 0 THEN 0 ELSE (_new - previous_close) / previous_close * 100 END, 4),
            updated_at = now()
        WHERE symbol = p_symbol
        RETURNING * INTO _after;

        -- Temettu dususu bir "sert hareket" degildir: devre kesiciyi tetiklemesin.
        UPDATE public.stocks
        SET halt_until = _stock.halt_until, breaker_ref = current_price
        WHERE symbol = p_symbol;

        -- Gercek hissenin ayni dususu sonradan geldiginde ikinci kez uygulanmasin; golge fiyat da birlikte iner.
        _ratio := _after.current_price / _price;
        UPDATE public.stock_links
        SET shadow_price = ROUND((shadow_price * _ratio)::NUMERIC, 6),
            pending_return = pending_return - ln(_ratio::DOUBLE PRECISION)
        WHERE symbol = p_symbol;

        INSERT INTO public.price_history (symbol, price, recorded_at)
        VALUES (p_symbol, _after.current_price, now());
    END IF;

    UPDATE public.stock_dividends SET players = _players, total = _total
    WHERE symbol = p_symbol AND ex_date = p_ex_date;

    INSERT INTO public.news_feed (id, title, summary, stock_symbol, impact_pct, created_at)
    VALUES (
        floor(extract(epoch FROM clock_timestamp()) * 1000000)::BIGINT,
        '💰 ' || coalesce(_stock.name, p_symbol) || ' temettü dağıttı',
        'Şirket kârının bir kısmını ortaklarına dağıttı: hisseyi elinde tutanlara, hisse değerinin %'
            || replace(ROUND(p_yield * 100, 1)::TEXT, '.', ',')
            || '''i kadar nakit yatırıldı. Temettü dağıtan hissenin fiyatı aynı oranda düşer; toplam varlığın değişmez.',
        p_symbol,
        0,
        now()
    );

    RETURN jsonb_build_object('paid', true, 'players', _players, 'total', _total, 'price_adjusted', coalesce(p_adjust_price, false));
END;
$$;

REVOKE ALL ON FUNCTION public.pay_stock_dividend(TEXT, DATE, NUMERIC, BOOLEAN) FROM PUBLIC, anon, authenticated;

-- Izlenen gercek hisselerin temettulerini okur: karnedeki verimi yeniler, bugune denk gelen dagitimi oder.
CREATE OR REPLACE FUNCTION public.refresh_stock_dividends()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _cfg public.engine_settings%ROWTYPE;
    _today DATE := (now() AT TIME ZONE 'Europe/Istanbul')::date;
    _link RECORD;
    _d RECORD;
    _status INTEGER;
    _body TEXT;
    _res JSONB;
    _divs JSONB;
    _sum NUMERIC;
    _prev NUMERIC;
    _yield NUMERIC;
    _bar_at TIMESTAMPTZ;
    _checked INTEGER := 0;
    _paid TEXT[] := '{}';
    _failed TEXT[] := '{}';
BEGIN
    SELECT * INTO _cfg FROM public.engine_settings WHERE id = 1;
    BEGIN
        PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS', '8000');
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    FOR _link IN SELECT symbol, yahoo_symbol, last_price, last_bar_at FROM public.stock_links ORDER BY symbol LOOP
        BEGIN
            SELECT r.status, r.content
            INTO _status, _body
            FROM extensions.http((
                'GET',
                'https://query1.finance.yahoo.com/v8/finance/chart/' || _link.yahoo_symbol || '?range=1y&interval=1d&events=div',
                ARRAY[extensions.http_header('User-Agent', 'Mozilla/5.0')],
                NULL,
                NULL
            )::extensions.http_request) AS r;
            IF _status IS DISTINCT FROM 200 THEN
                RAISE EXCEPTION 'HTTP %', _status;
            END IF;
            _res := _body::JSONB #> '{chart,result,0}';
            IF _res IS NULL OR jsonb_typeof(_res) <> 'object' THEN
                RAISE EXCEPTION 'veri yok';
            END IF;
            _divs := CASE WHEN jsonb_typeof(_res #> '{events,dividends}') = 'object' THEN _res #> '{events,dividends}' ELSE '{}'::jsonb END;

            -- Karne: son 12 ayin temettusu / guncel gercek fiyat
            SELECT coalesce(sum((kv.value ->> 'amount')::NUMERIC), 0) INTO _sum
            FROM jsonb_each(_divs) AS kv
            WHERE to_timestamp((kv.value ->> 'date')::DOUBLE PRECISION) > now() - INTERVAL '365 days';
            UPDATE public.stock_links
            SET dividend_yield = CASE WHEN coalesce(_link.last_price, 0) > 0 THEN ROUND(_sum / _link.last_price * 100, 1) END
            WHERE symbol = _link.symbol;
            _checked := _checked + 1;

            IF coalesce(_cfg.dividends_enabled, true) THEN
                FOR _d IN
                    SELECT (kv.value ->> 'amount')::NUMERIC AS amount,
                           (to_timestamp((kv.value ->> 'date')::DOUBLE PRECISION) AT TIME ZONE 'Europe/Istanbul')::date AS ex_date
                    FROM jsonb_each(_divs) AS kv
                LOOP
                    CONTINUE WHEN _d.ex_date > _today OR _d.ex_date < _today - 4 OR _d.ex_date < _cfg.dividends_since;
                    CONTINUE WHEN EXISTS (SELECT 1 FROM public.stock_dividends WHERE symbol = _link.symbol AND ex_date = _d.ex_date);

                    -- Dagitimdan onceki son gercek kapanis: oran = hisse basi temettu / o kapanis
                    SELECT (c.val #>> '{}')::NUMERIC INTO _prev
                    FROM jsonb_array_elements(_res #> '{indicators,quote,0,close}') WITH ORDINALITY AS c(val, ord)
                    JOIN jsonb_array_elements(_res -> 'timestamp') WITH ORDINALITY AS t(val, ord) ON t.ord = c.ord
                    WHERE jsonb_typeof(c.val) = 'number'
                      AND (to_timestamp((t.val #>> '{}')::DOUBLE PRECISION) AT TIME ZONE 'Europe/Istanbul')::date < _d.ex_date
                    ORDER BY c.ord DESC
                    LIMIT 1;

                    _yield := CASE WHEN coalesce(_prev, 0) > 0 THEN _d.amount / _prev END;
                    CONTINUE WHEN _yield IS NULL OR _yield <= 0 OR _yield > 0.15;

                    -- Satir kilitlenip yeniden okunur: fiyat yenileme gorevi ayni anda calisiyorsa en guncel durum gorulur.
                    SELECT l.last_bar_at INTO _bar_at FROM public.stock_links AS l WHERE l.symbol = _link.symbol FOR UPDATE;
                    PERFORM public.pay_stock_dividend(
                        _link.symbol, _d.ex_date, _yield,
                        -- Gercek hissenin dagitim gunu fiyati oyuna henuz gelmediyse fiyat simdi dusurulur.
                        _bar_at IS NULL OR (_bar_at AT TIME ZONE 'Europe/Istanbul')::date < _d.ex_date
                    );
                    _paid := array_append(_paid, _link.symbol::TEXT);
                END LOOP;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            _failed := array_append(_failed, _link.symbol::TEXT);
        END;
    END LOOP;

    RETURN jsonb_build_object('ok', _checked > 0, 'checked', _checked, 'paid', to_jsonb(_paid), 'failed', to_jsonb(_failed));
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_stock_dividends() FROM PUBLIC, anon, authenticated;

-- Sirket Karnesi: temettu verimi eklenir.
CREATE OR REPLACE FUNCTION public.get_stock_reports()
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_build_object(
        'enabled', (SELECT stock_link_enabled FROM public.engine_settings WHERE id = 1),
        'reports', coalesce((
            SELECT jsonb_object_agg(l.symbol, jsonb_build_object(
                'sector', l.sector,
                'summary', l.summary,
                'sensitivities', l.sensitivities,
                'stats', l.stats,
                'financials', l.financials,
                'dividend_yield', l.dividend_yield,
                'live', l.fetched_at > now() - INTERVAL '20 minutes'
            ))
            FROM public.stock_links AS l
        ), '{}'::jsonb)
    );
$$;

REVOKE ALL ON FUNCTION public.get_stock_reports() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_stock_reports() TO anon, authenticated;

-- Yonetici: temettuyu ac/kapat.
CREATE OR REPLACE FUNCTION public.admin_set_dividends(p_enabled BOOLEAN)
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
    UPDATE public.engine_settings SET dividends_enabled = p_enabled WHERE id = 1;
    RETURN p_enabled;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_dividends(BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_dividends(BOOLEAN) TO authenticated;

-- Hafta ici: acilistan once (09:50) ve acilistan sonraki uc saat boyunca yarim saatte bir bakilir (Turkiye saati).
-- Dakikalar, bes dakikada bir calisan fiyat yenileme goreviyle cakismayacak sekilde secildi.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('borsa-refresh-stock-dividends', 'borsa-refresh-stock-dividends-late');
SELECT cron.schedule('borsa-refresh-stock-dividends', '52 6 * * 1-5', $$ SELECT public.refresh_stock_dividends(); $$);
SELECT cron.schedule('borsa-refresh-stock-dividends-late', '17,47 7-9 * * 1-5', $$ SELECT public.refresh_stock_dividends(); $$);

NOTIFY pgrst, 'reload schema';

-- Ilk okuma: "checked" 12 olmali, "paid" bos olmali (bugun dagitim yoksa).
SELECT public.refresh_stock_dividends() AS temettu;
