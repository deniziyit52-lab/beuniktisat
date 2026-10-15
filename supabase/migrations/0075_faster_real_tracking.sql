-- Oyunun gercek hisseyi izleme gecikmesi ~25 dakikadan ~16 dakikaya iner.
-- Yahoo'nun BIST verisi zaten ~15 dakika gecikmelidir; buna eskiden 5 dakikada bir okuma ve okunan hareketi
-- 5 dakikaya yayma ekleniyordu. Artik gercek veri her dakika okunur ve hareket bir sonraki dakikada uygulanir.
-- Yuzdeler degismez (0074): yalnizca gecikme kisalir. Yahoo'ya gunde ~540 istek gider.

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
                -- Okunan hareket bir sonraki dakikada tek seferde uygulanir (eskiden 5 dakikaya yayiliyordu).
                ticks_left = 1,
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

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'borsa-refresh-stock-links';
SELECT cron.schedule('borsa-refresh-stock-links', '* 7-15 * * 1-5', $$ SELECT public.refresh_stock_links(); $$);

NOTIFY pgrst, 'reload schema';

-- Hemen bir okuma: "ok" true olmali; piyasa acikken "updated" 12'ye yakin olur.
SELECT public.refresh_stock_links() AS ilk_okuma,
       (SELECT schedule FROM cron.job WHERE jobname = 'borsa-refresh-stock-links') AS zamanlama;
