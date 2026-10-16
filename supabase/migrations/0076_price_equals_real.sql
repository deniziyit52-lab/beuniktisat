-- Her oyun hissesinin fiyati, bagli oldugu gercek hissenin fiyatina birebir esit olsun (kullanici karari).
--
-- 0074'ten beri yuzdeler aynidir ama fiyatlar farkliydi (oyun fiyati = golge fiyat x sabit). Bu dosya:
-- 1) rebase_stock_to_real(sembol): hisseyi gercek fiyatina tasir. Gercek borsadaki hisse bolunmesi gibi
--    calisir: oyuncunun o hissedeki degeri degismez. Adet yeni fiyata gore ayarlanir (tam sayiya asagi),
--    kalan kusurat o anki fiyattan nakit olarak bakiyeye yatar; birim maliyet ayni oranda olceklenir.
--    Grafik gecmisi, acilis fiyati ve golge fiyat da ayni oranla carpilir; gunluk yuzde degismez.
--    Bagli gercek hisse degistirildiginde ya da gercek hisse bolundugunde (bedelsiz) yeniden calistirilir.
-- 2) sync_linked_closes her aksam fiyati gercek kapanisa esitler (kucuk yuvarlama farklari birikmesin).
--    Fark %3'ten buyukse (bolunme ya da bozuk veri) dokunmaz; o hisse icin rebase_stock_to_real elle calistirilir.
--
-- Bu dosya fonksiyonlari kurar, hicbir fiyati degistirmez. Asil gecis gizli dosyadan yapilir (0076b).

CREATE OR REPLACE FUNCTION public.rebase_stock_to_real(p_symbol TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _s public.stocks%ROWTYPE;
    _l public.stock_links%ROWTYPE;
    _floor NUMERIC;
    _old NUMERIC;
    _new NUMERIC;
    _f NUMERIC;
    _holders INTEGER := 0;
    _cash NUMERIC := 0;
BEGIN
    SELECT * INTO _s FROM public.stocks WHERE symbol = p_symbol FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('symbol', p_symbol, 'ok', false, 'error', 'hisse yok');
    END IF;
    SELECT * INTO _l FROM public.stock_links WHERE symbol = p_symbol FOR UPDATE;
    IF NOT FOUND OR coalesce(_l.last_price, 0) <= 0 THEN
        RETURN jsonb_build_object('symbol', p_symbol, 'ok', false, 'error', 'gercek fiyat okunmamis');
    END IF;

    SELECT coalesce(price_floor, 1) INTO _floor FROM public.engine_settings WHERE id = 1;
    _old := _s.current_price;
    _new := ROUND(_l.last_price, 4);
    IF _new < coalesce(_floor, 1) THEN
        RETURN jsonb_build_object('symbol', p_symbol, 'ok', false, 'error', 'gercek fiyat oyunun taban fiyatindan dusuk');
    END IF;
    IF coalesce(_old, 0) <= 0 THEN
        RETURN jsonb_build_object('symbol', p_symbol, 'ok', false, 'error', 'oyun fiyati gecersiz');
    END IF;
    _f := _new / _old;

    IF _new <> _old THEN
        -- Oyuncular: deger korunur. Yeni adet = eski adet x eski fiyat / yeni fiyat (asagi yuvarlanir),
        -- kusurat nakit odenir. Adet sifira inerse hisse portfoyden cikar.
        WITH h AS (
            SELECT u.id,
                   (u.portfolio -> p_symbol) AS e,
                   (u.portfolio -> p_symbol ->> 'qty')::NUMERIC AS q
            FROM public.users AS u
            WHERE jsonb_typeof(u.portfolio) = 'object'
              AND jsonb_typeof(u.portfolio -> p_symbol) = 'object'
              AND coalesce((u.portfolio -> p_symbol ->> 'qty')::NUMERIC, 0) > 0
            FOR UPDATE OF u
        ),
        c AS (
            SELECT id, e, q,
                   floor(q * _old / _new) AS qn
            FROM h
        ),
        c2 AS (
            SELECT id, qn,
                   GREATEST(ROUND(q * _old - qn * _new, 2), 0) AS cash,
                   -- Birim maliyet alanlari (sayfa costBasis, avg ya da cost okur) ayni oranla olceklenir.
                   (SELECT coalesce(jsonb_object_agg(
                               k.key,
                               CASE WHEN k.key = 'qty' THEN to_jsonb(qn)
                                    WHEN k.key IN ('costBasis', 'avg', 'cost') AND jsonb_typeof(k.value) = 'number'
                                        THEN to_jsonb(ROUND((k.value #>> '{}')::NUMERIC * _f, 4))
                                    ELSE k.value END), '{}'::jsonb)
                    FROM jsonb_each(e) AS k) AS e_new
            FROM c
        ),
        upd AS (
            UPDATE public.users AS u
            SET balance = u.balance + c2.cash,
                portfolio = CASE WHEN c2.qn > 0 THEN jsonb_set(u.portfolio, ARRAY[p_symbol], c2.e_new)
                                 ELSE u.portfolio - p_symbol END
            FROM c2
            WHERE u.id = c2.id
            RETURNING c2.cash
        )
        SELECT count(*), coalesce(sum(cash), 0) INTO _holders, _cash FROM upd;

        -- Hisse: fiyat ve acilis fiyati ayni oranla; gunluk yuzde ayni kalir.
        -- Acilis fiyati korumasi bu bakim icin gecici olarak acilir.
        PERFORM set_config('borsa.prev_close_mode', 'allow', true);
        UPDATE public.stocks
        SET current_price = _new,
            previous_close = CASE WHEN previous_close > 0 THEN ROUND(previous_close * _f, 4) ELSE previous_close END,
            change = CASE WHEN previous_close > 0 THEN ROUND(_new - ROUND(previous_close * _f, 4), 4) ELSE change END,
            impact_pending = 0,
            breaker_ref = _new,
            updated_at = now()
        WHERE symbol = p_symbol;
        PERFORM set_config('borsa.prev_close_mode', '', true);
        -- Devre kesici tetikleyicisi buyuk "hareketi" gorup hisseyi durdurmus olabilir; eski durum geri yazilir
        -- (bu guncelleme fiyata dokunmadigi icin tetikleyici calismaz).
        UPDATE public.stocks
        SET halt_until = _s.halt_until, breaker_ref = _new
        WHERE symbol = p_symbol;

        UPDATE public.price_history SET price = ROUND(price * _f, 4) WHERE symbol = p_symbol;
        UPDATE public.price_history_hourly SET price = ROUND(price * _f, 4) WHERE symbol = p_symbol;
    END IF;

    -- Golge fiyat artik gercek fiyatin kendisi; bekleyen hareket zaten last_price'in icinde.
    UPDATE public.stock_links
    SET shadow_price = _new, pending_return = 0, ticks_left = 0
    WHERE symbol = p_symbol;

    RETURN jsonb_build_object(
        'symbol', p_symbol, 'ok', true,
        'eski_fiyat', _old, 'yeni_fiyat', _new, 'oran', ROUND(_f, 6),
        'oyuncu', _holders, 'odenen_kusurat_tl', _cash
    );
END;
$$;

REVOKE ALL ON FUNCTION public.rebase_stock_to_real(TEXT) FROM PUBLIC, anon, authenticated;

-- 0074'teki surum; tek fark: bekleyen hareket islendikten sonra golge fiyat, %3'ten yakinsa
-- gercek fiyatin kendisine (last_price) esitlenir. Boylece yuvarlama ve sinirlamalardan kalan
-- kucuk farklar her aksam sifirlanir ve oyun fiyati gercek kapanisla ayni olur.
CREATE OR REPLACE FUNCTION public.sync_linked_closes(p_force BOOLEAN DEFAULT false)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _cfg public.engine_settings%ROWTYPE;
    _open BOOLEAN;
    _r RECORD;
    _shadow NUMERIC;
    _price NUMERIC;
    _close_at TIMESTAMPTZ;
    _changed INTEGER := 0;
BEGIN
    SELECT * INTO _cfg FROM public.engine_settings WHERE id = 1;
    IF NOT FOUND OR NOT coalesce(_cfg.stock_link_enabled, false) THEN
        RETURN 0;
    END IF;
    SELECT is_market_open INTO _open FROM public.market_settings WHERE id = 1;
    _open := coalesce(_open, false);
    IF _open AND NOT coalesce(p_force, false) THEN
        RETURN 0;
    END IF;
    -- Bugunun 18:00'i (Turkiye): kapanistan sonraki saatlik kayitlar tek bir kapanis noktasi olarak tutulur.
    _close_at := (date_trunc('day', now() AT TIME ZONE 'Europe/Istanbul') + INTERVAL '18 hours') AT TIME ZONE 'Europe/Istanbul';

    FOR _r IN
        SELECT l.symbol, l.shadow_price, l.last_price, coalesce(l.pending_return, 0) AS pending, s.current_price
        FROM public.stock_links AS l
        JOIN public.stocks AS s ON s.symbol = l.symbol
        WHERE l.shadow_price > 0
        ORDER BY l.symbol
        FOR UPDATE OF l, s
    LOOP
        _shadow := ROUND((_r.shadow_price * exp(_r.pending::DOUBLE PRECISION))::NUMERIC, 6);
        IF coalesce(_r.last_price, 0) > 0
           AND abs(ln((_r.last_price / _shadow)::DOUBLE PRECISION)) < 0.03 THEN
            _shadow := _r.last_price;
        END IF;
        _price := GREATEST(_cfg.price_floor, ROUND(_shadow, 4));

        UPDATE public.stock_links
        SET shadow_price = _shadow, pending_return = 0, ticks_left = 0
        WHERE symbol = _r.symbol;

        IF _price IS DISTINCT FROM _r.current_price THEN
            UPDATE public.stocks
            SET current_price = _price,
                change = ROUND(_price - previous_close, 4),
                change_pct = CASE WHEN previous_close = 0 THEN 0
                                  ELSE ROUND((_price - previous_close) / previous_close * 100, 4) END,
                impact_pending = 0,
                updated_at = now()
            WHERE symbol = _r.symbol;

            INSERT INTO public.price_history (symbol, price, recorded_at)
            SELECT symbol, current_price, now() FROM public.stocks WHERE symbol = _r.symbol;

            IF NOT _open AND now() >= _close_at THEN
                DELETE FROM public.price_history_hourly WHERE symbol = _r.symbol AND recorded_at >= _close_at;
                INSERT INTO public.price_history_hourly (symbol, price, recorded_at)
                SELECT symbol, current_price, now() FROM public.stocks WHERE symbol = _r.symbol;
            END IF;
            _changed := _changed + 1;
        END IF;
    END LOOP;

    RETURN _changed;
END;
$$;

REVOKE ALL ON FUNCTION public.sync_linked_closes(BOOLEAN) FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
