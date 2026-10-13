-- Sirket Karnesi'ne mali tablolar: her hissenin bagli oldugu gercek sirketin ozet gelir tablosu,
-- bilanco ozeti ve birkac temel orani. Ogrenci yalnizca fiyata degil sirketin mali durumuna da bakabilsin.
-- Veri Yahoo'dan gunde bir kez okunur; sirket yeni bilanco aciklayinca haber akisina bir haber duser.

ALTER TABLE public.stock_links ADD COLUMN IF NOT EXISTS financials JSONB;
ALTER TABLE public.stock_links ADD COLUMN IF NOT EXISTS financials_at TIMESTAMPTZ;

-- Yahoo cevabindaki bir kalemin (ornegin quarterlyNetIncome) tarih-deger satirlari.
CREATE OR REPLACE FUNCTION public.yahoo_series(p_json JSONB, p_type TEXT)
RETURNS TABLE (as_of DATE, val NUMERIC)
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT (o.item ->> 'asOfDate')::DATE, (o.item -> 'reportedValue' ->> 'raw')::NUMERIC
    FROM jsonb_array_elements(coalesce(p_json -> 'timeseries' -> 'result', '[]'::jsonb)) AS r(res)
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(r.res -> p_type) = 'array' THEN r.res -> p_type ELSE '[]'::jsonb END
    ) AS o(item)
    WHERE jsonb_typeof(o.item) = 'object'
      AND o.item ->> 'asOfDate' IS NOT NULL
      AND o.item -> 'reportedValue' ->> 'raw' IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.yahoo_series(JSONB, TEXT) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.refresh_stock_financials()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _types CONSTANT TEXT := 'quarterlyTotalRevenue,quarterlyNetIncome,quarterlyTotalAssets,quarterlyStockholdersEquity,'
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
            SELECT jsonb_agg(jsonb_build_object('d', q.as_of, 'rev', q.rev, 'net', q.net) ORDER BY q.as_of),
                   max(q.as_of), sum(q.rev), sum(q.net), count(*)
            INTO _quarters, _latest, _rev4, _net4, _n4
            FROM (
                SELECT coalesce(r.as_of, n.as_of) AS as_of, r.val AS rev, n.val AS net
                FROM public.yahoo_series(_j, 'quarterlyTotalRevenue') AS r
                FULL JOIN public.yahoo_series(_j, 'quarterlyNetIncome') AS n ON n.as_of = r.as_of
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

-- Oyuncunun gordugu sirket karneleri: mali tablolar eklendi. Gercek hisse kodu ve fiyati DONMEZ.
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
                'live', l.fetched_at > now() - INTERVAL '20 minutes'
            ))
            FROM public.stock_links AS l
        ), '{}'::jsonb)
    );
$$;

REVOKE ALL ON FUNCTION public.get_stock_reports() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_stock_reports() TO anon, authenticated;

-- Hafta ici her aksam 19:25'te (Turkiye) yenilenir.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'borsa-refresh-stock-financials';
SELECT cron.schedule('borsa-refresh-stock-financials', '25 16 * * 1-5', $$ SELECT public.refresh_stock_financials(); $$);

NOTIFY pgrst, 'reload schema';

-- Ilk okuma: "updated" 12 olmali; "failed" listesinde hisse varsa o sirketin verisi alinamamistir.
SELECT public.refresh_stock_financials() AS mali_tablolar;
