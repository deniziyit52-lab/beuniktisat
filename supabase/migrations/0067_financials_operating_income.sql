-- Mali tablolara "faaliyet kari" eklenir.
--
-- Net kar tek basina yaniltabilir: sirket asil isinden zarar ederken tek seferlik bir gelirle (varlik
-- satisi gibi) net kar yazabilir. Faaliyet kari, sirketin asil isinden ne kazandigini gosterir; ikisi
-- yan yana durunca ogrenci bu farki gorebilir.

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
            -- Fiyat/Kazanc hazir gelmediyse son 4 ceyregin karindan hesaplanir (zarar varsa bos kalir).
            IF _pe IS NULL AND _n4 = 4 AND _net4 > 0 AND _cap > 0 THEN
                _pe := _cap / _net4;
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

-- Verileri simdi yenile: "updated" 12 olmali.
SELECT public.refresh_stock_financials() AS mali_tablolar;
