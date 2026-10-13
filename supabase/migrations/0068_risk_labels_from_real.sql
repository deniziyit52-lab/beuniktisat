-- Risk etiketleri (Guvenli / Orta / Riskli) gercek oynakliga gore verilir.
--
-- Hisseler gercek hisselere baglandigi icin eski etiketler anlamini yitirdi. Her hissenin etiketi,
-- bagli oldugu gercek hissenin son bir yildaki gunluk oynakligina gore yeniden belirlenir:
-- en sakin ucte biri Guvenli, en oynak dortte biri Riskli, kalani Orta.
-- (Hangi hissenin hangi gercek hisseye baglandigi depoya girmeyen supabase/gizli/ altindadir.)

CREATE OR REPLACE FUNCTION public.refresh_stock_stats()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _j JSONB;
    _link RECORD;
    _c NUMERIC[];
    _n INTEGER;
    _sigma NUMERIC;
    _lo NUMERIC;
    _hi NUMERIC;
    _updated INTEGER := 0;
BEGIN
    BEGIN
        SELECT public.fetch_yahoo_spark(array_agg(DISTINCT yahoo_symbol), '1y', '1d') INTO _j FROM public.stock_links;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
    END;

    FOR _link IN SELECT symbol, yahoo_symbol FROM public.stock_links ORDER BY symbol LOOP
        BEGIN
            SELECT array_agg((c.val #>> '{}')::NUMERIC ORDER BY c.ord)
            INTO _c
            FROM jsonb_array_elements(_j -> _link.yahoo_symbol -> 'close') WITH ORDINALITY AS c(val, ord)
            WHERE jsonb_typeof(c.val) = 'number' AND (c.val #>> '{}')::NUMERIC > 0;

            _n := coalesce(array_length(_c, 1), 0);
            IF _n < 70 THEN
                CONTINUE;
            END IF;

            SELECT stddev_pop(ln((_c[i] / _c[i - 1])::DOUBLE PRECISION))::NUMERIC
            INTO _sigma
            FROM generate_series(2, _n) AS i;
            SELECT min(v), max(v) INTO _lo, _hi FROM unnest(_c) AS v;

            UPDATE public.stock_links
            SET stats = jsonb_build_object(
                    'w1', ROUND((_c[_n] / _c[_n - 5] - 1) * 100),
                    'm1', ROUND((_c[_n] / _c[_n - 21] - 1) * 100),
                    'm3', ROUND((_c[_n] / _c[_n - 63] - 1) * 100),
                    'pos52', CASE WHEN _hi > _lo THEN ROUND((_c[_n] - _lo) / (_hi - _lo) * 100) END,
                    'vol', CASE WHEN _sigma < 0.025 THEN 'low' WHEN _sigma < 0.035 THEN 'mid' ELSE 'high' END,
                    -- Gunluk oynaklik (%); risk etiketleri buna gore verilir.
                    'sigma', ROUND(_sigma * 100, 2)
                ),
                stats_at = now()
            WHERE symbol = _link.symbol;
            _updated := _updated + 1;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'updated', _updated);
END;
$$;

REVOKE ALL ON FUNCTION public.refresh_stock_stats() FROM PUBLIC, anon, authenticated;

-- Etiketleri gercek oynakliga gore yeniden dagitir. Bir hissenin bile oynakligi bilinmiyorsa hicbir sey degistirmez.
CREATE OR REPLACE FUNCTION public.relabel_stock_risk_from_real()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _total INTEGER;
    _known INTEGER;
    _result JSONB;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE (l.stats ->> 'sigma') IS NOT NULL)
    INTO _total, _known
    FROM public.stock_links AS l;

    IF _total = 0 OR _known < _total THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'oynakligi bilinmeyen hisse var', 'known', _known, 'total', _total);
    END IF;

    WITH ranked AS (
        SELECT l.symbol,
               (l.stats ->> 'sigma')::NUMERIC AS sigma,
               row_number() OVER (ORDER BY (l.stats ->> 'sigma')::NUMERIC, l.symbol) AS rn
        FROM public.stock_links AS l
    ),
    labeled AS (
        SELECT symbol, sigma,
               CASE WHEN rn <= ceil(_total / 3.0) THEN 'guvenli'
                    WHEN rn <= ceil(_total * 0.75) THEN 'orta'
                    ELSE 'riskli' END AS risk_type
        FROM ranked
    ),
    changed AS (
        UPDATE public.stocks AS s
        SET risk_type = b.risk_type, updated_at = now()
        FROM labeled AS b
        WHERE s.symbol = b.symbol AND s.risk_type IS DISTINCT FROM b.risk_type
        RETURNING s.symbol
    )
    SELECT jsonb_build_object(
        'ok', true,
        'changed', (SELECT count(*) FROM changed),
        'labels', (SELECT jsonb_object_agg(symbol, risk_type || ' (%' || sigma || ')') FROM labeled)
    ) INTO _result;

    RETURN _result;
END;
$$;

REVOKE ALL ON FUNCTION public.relabel_stock_risk_from_real() FROM PUBLIC, anon, authenticated;

SELECT 'Hazir: simdi supabase/gizli/0068b_sakin_eslesmeler.sql dosyasini calistir.' AS sonraki_adim;
