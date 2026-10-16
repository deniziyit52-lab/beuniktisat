-- Yonetici paneline uc yeni bolum (yalnizca okur, hicbir seyi degistirmez):
-- 1) admin_game_overview: oyuncu sayilari, bugunku islem adedi ve hacmi, en cok islem goren hisse, getiri ozeti.
-- 2) admin_list_players / admin_player_detail: oyuncu listesi (arama ile) ve bir oyuncunun portfoyu, nakdi, son islemleri.
-- 3) admin_system_health: gercek hisse verisi, fiyat motoru, oyun fiyati = gercek fiyat, ZBEU 100, altin/doviz
--    ve zamanlanmis gorev hatalari icin yesil/sari/kirmizi durum. Gercek hisse kodlari bu ciktida yer almaz.

-- Turkiye saatine gore bugunun baslangici.
CREATE OR REPLACE FUNCTION public.borsa_today_start()
RETURNS TIMESTAMPTZ
LANGUAGE SQL
STABLE
AS $$
    SELECT (date_trunc('day', now() AT TIME ZONE 'Europe/Istanbul')) AT TIME ZONE 'Europe/Istanbul';
$$;

-- Hisse ve altin/doviz islemleri tek listede.
CREATE OR REPLACE FUNCTION public.borsa_all_trades()
RETURNS TABLE(user_id UUID, kind TEXT, symbol TEXT, side TEXT, qty NUMERIC, price NUMERIC, total NUMERIC, at TIMESTAMPTZ)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT t.user_id, 'stock', t.stock_symbol::TEXT, upper(t.type::TEXT), t.quantity::NUMERIC, t.price_per_share::NUMERIC,
           (t.quantity * t.price_per_share)::NUMERIC, t.created_at
    FROM public.transactions AS t
    UNION ALL
    SELECT a.user_id, 'asset', a.asset::TEXT, upper(a.side::TEXT), a.quantity::NUMERIC, a.price::NUMERIC,
           coalesce(a.total, a.quantity * a.price)::NUMERIC, a.created_at
    FROM public.asset_transactions AS a;
$$;
REVOKE ALL ON FUNCTION public.borsa_all_trades() FROM PUBLIC, anon, authenticated;

-- 1) Oyun ozeti
CREATE OR REPLACE FUNCTION public.admin_game_overview()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _today TIMESTAMPTZ := public.borsa_today_start();
    _out JSONB;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    WITH tr AS (SELECT * FROM public.borsa_all_trades()),
    active AS (SELECT DISTINCT user_id FROM tr),
    ret AS (
        SELECT r.user_id, r.wealth, r.return_pct, u.balance, coalesce(u.nickname, u.display_name) AS name
        FROM public.user_returns() AS r
        JOIN public.users AS u ON u.id = r.user_id
        WHERE r.user_id IN (SELECT user_id FROM active)
    ),
    top_stock AS (
        SELECT tr.symbol, s.name, count(*) AS trades, sum(tr.total) AS volume
        FROM tr JOIN public.stocks AS s ON s.symbol = tr.symbol
        WHERE tr.kind = 'stock' AND tr.at >= _today
        GROUP BY tr.symbol, s.name
        ORDER BY sum(tr.total) DESC
        LIMIT 1
    )
    SELECT jsonb_build_object(
        'players', (SELECT count(*) FROM public.users),
        'active', (SELECT count(*) FROM active),
        'today_traders', (SELECT count(DISTINCT user_id) FROM tr WHERE at >= _today),
        'week_traders', (SELECT count(DISTINCT user_id) FROM tr WHERE at >= now() - INTERVAL '7 days'),
        'today_trades', (SELECT count(*) FROM tr WHERE at >= _today),
        'today_volume', (SELECT coalesce(ROUND(sum(total), 2), 0) FROM tr WHERE at >= _today),
        'top_stock', (SELECT jsonb_build_object('symbol', symbol, 'name', name, 'trades', trades, 'volume', ROUND(volume, 2)) FROM top_stock),
        'avg_return', (SELECT ROUND(avg(return_pct), 2) FROM ret),
        'in_profit', (SELECT count(*) FROM ret WHERE return_pct > 0),
        'best', (SELECT jsonb_build_object('name', name, 'return_pct', ROUND(return_pct, 2)) FROM ret ORDER BY return_pct DESC LIMIT 1),
        'worst', (SELECT jsonb_build_object('name', name, 'return_pct', ROUND(return_pct, 2)) FROM ret ORDER BY return_pct ASC LIMIT 1),
        'cash_pct', (SELECT CASE WHEN sum(wealth) > 0 THEN ROUND(sum(balance) / sum(wealth) * 100, 1) END FROM ret)
    ) INTO _out;

    RETURN _out;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_game_overview() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_game_overview() TO authenticated;

-- 2a) Oyuncu listesi: islem yapanlar getiri sirasina gore, sonra hic islem yapmayanlar.
CREATE OR REPLACE FUNCTION public.admin_list_players(p_search TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _q TEXT := nullif(btrim(coalesce(p_search, '')), '');
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    RETURN coalesce((
        WITH tr AS (
            SELECT user_id, count(*) AS trades, max(at) AS last_at
            FROM public.borsa_all_trades()
            GROUP BY user_id
        ),
        p AS (
            SELECT u.id, u.display_name, u.nickname, u.email, r.wealth, r.return_pct,
                   coalesce(tr.trades, 0) AS trades, tr.last_at,
                   CASE WHEN tr.trades > 0
                        THEN rank() OVER (PARTITION BY tr.trades > 0 ORDER BY r.return_pct DESC) END AS rnk
            FROM public.users AS u
            JOIN public.user_returns() AS r ON r.user_id = u.id
            LEFT JOIN tr ON tr.user_id = u.id
        )
        SELECT jsonb_agg(jsonb_build_object(
                   'id', id, 'name', display_name, 'nickname', nickname, 'email', email,
                   'wealth', ROUND(wealth, 2), 'return_pct', ROUND(return_pct, 2),
                   'trades', trades, 'last_trade_at', last_at, 'rank', rnk)
               ORDER BY rnk NULLS LAST, lower(coalesce(display_name, email)))
        FROM (
            SELECT * FROM p
            WHERE _q IS NULL
               OR coalesce(display_name, '') ILIKE '%' || _q || '%'
               OR coalesce(nickname, '') ILIKE '%' || _q || '%'
               OR coalesce(email, '') ILIKE '%' || _q || '%'
            ORDER BY rnk NULLS LAST, lower(coalesce(display_name, email))
            LIMIT 100
        ) AS x
    ), '[]'::jsonb);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_list_players(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_players(TEXT) TO authenticated;

-- 2b) Bir oyuncunun ayrintisi
CREATE OR REPLACE FUNCTION public.admin_player_detail(p_user_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _u public.users%ROWTYPE;
    _r RECORD;
    _rank BIGINT;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO _u FROM public.users WHERE id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Oyuncu bulunamadi.';
    END IF;
    SELECT * INTO _r FROM public.user_returns() WHERE user_id = p_user_id;
    SELECT 1 + count(*) INTO _rank
    FROM public.user_returns() AS o
    WHERE o.return_pct > _r.return_pct
      AND o.user_id IN (SELECT user_id FROM public.borsa_all_trades());

    RETURN jsonb_build_object(
        'name', _u.display_name,
        'nickname', _u.nickname,
        'email', _u.email,
        'balance', ROUND(_u.balance, 2),
        'starting_balance', _u.starting_balance,
        'wealth', ROUND(_r.wealth, 2),
        'return_pct', ROUND(_r.return_pct, 2),
        'rank', CASE WHEN EXISTS (SELECT 1 FROM public.borsa_all_trades() WHERE user_id = p_user_id) THEN _rank END,
        'stocks', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'symbol', s.symbol, 'name', s.name,
                       'qty', (kv.value ->> 'qty')::NUMERIC,
                       'cost', nullif(coalesce(kv.value ->> 'costBasis', kv.value ->> 'avg', kv.value ->> 'cost'), '')::NUMERIC,
                       'price', s.current_price,
                       'value', ROUND((kv.value ->> 'qty')::NUMERIC * s.current_price, 2))
                   ORDER BY (kv.value ->> 'qty')::NUMERIC * s.current_price DESC)
            FROM jsonb_each(CASE WHEN jsonb_typeof(_u.portfolio) = 'object' THEN _u.portfolio ELSE '{}'::jsonb END) AS kv
            JOIN public.stocks AS s ON s.symbol = kv.key
            WHERE coalesce((kv.value ->> 'qty')::NUMERIC, 0) > 0
        ), '[]'::jsonb),
        'assets', coalesce((
            SELECT jsonb_agg(jsonb_build_object(
                       'asset', kv.key,
                       'qty', (kv.value ->> 'qty')::NUMERIC,
                       'price', (ap.prices ->> kv.key)::NUMERIC,
                       'value', ROUND((kv.value ->> 'qty')::NUMERIC * (ap.prices ->> kv.key)::NUMERIC, 2)))
            FROM jsonb_each(CASE WHEN jsonb_typeof(_u.assets) = 'object' THEN _u.assets ELSE '{}'::jsonb END) AS kv
            CROSS JOIN public.asset_prices AS ap
            WHERE ap.id = 1 AND coalesce((kv.value ->> 'qty')::NUMERIC, 0) > 0
        ), '[]'::jsonb),
        'trades', coalesce((
            SELECT jsonb_agg(to_jsonb(t) ORDER BY t.at DESC)
            FROM (
                SELECT kind, symbol, side, qty, price, ROUND(total, 2) AS total, at
                FROM public.borsa_all_trades()
                WHERE user_id = p_user_id
                ORDER BY at DESC
                LIMIT 30
            ) AS t
        ), '[]'::jsonb),
        'trade_count', (SELECT count(*) FROM public.borsa_all_trades() WHERE user_id = p_user_id)
    );
END;
$$;
REVOKE ALL ON FUNCTION public.admin_player_detail(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_player_detail(UUID) TO authenticated;

-- 3) Sistem sagligi. Durum: ok (yesil), warn (sari), bad (kirmizi), idle (gri: piyasa kapali, beklenen sessizlik).
CREATE OR REPLACE FUNCTION public.admin_system_health()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _open BOOLEAN;
    _checks JSONB := '[]'::jsonb;
    _ls public.stock_link_status%ROWTYPE;
    _mi public.market_index%ROWTYPE;
    _as public.asset_fetch_status%ROWTYPE;
    _tick TIMESTAMPTZ;
    _gap NUMERIC;
    _gaps JSONB;
    _cron JSONB;
    _st TEXT;
    _min NUMERIC;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT coalesce(is_market_open, false) INTO _open FROM public.market_settings WHERE id = 1;
    _open := coalesce(_open, false);

    -- Gercek hisse verisi (her dakika okunur)
    SELECT * INTO _ls FROM public.stock_link_status WHERE id = 1;
    _min := ROUND(extract(epoch FROM now() - _ls.checked_at)::NUMERIC / 60, 0);
    _st := CASE
        WHEN _ls.checked_at IS NULL THEN 'bad'
        WHEN NOT _open THEN 'idle'
        WHEN _ls.ok IS NOT TRUE OR _min > 5 THEN 'bad'
        WHEN _ls.message ILIKE '%okunamayan%' THEN 'warn'
        ELSE 'ok' END;
    _checks := _checks || jsonb_build_object('label', 'Hisse verisi okuma', 'status', _st,
        'detail', CASE WHEN _ls.checked_at IS NULL THEN 'Hiç okunmamış.'
                       ELSE 'Son okuma ' || _min || ' dk önce: ' || coalesce(_ls.message, '') END);

    -- Fiyat motoru (piyasa acikken her dakika grafik gecmisine yazar)
    SELECT max(recorded_at) INTO _tick FROM public.price_history;
    _min := ROUND(extract(epoch FROM now() - _tick)::NUMERIC / 60, 0);
    _st := CASE WHEN NOT _open THEN 'idle' WHEN _tick IS NULL OR _min > 3 THEN 'bad' ELSE 'ok' END;
    _checks := _checks || jsonb_build_object('label', 'Fiyat motoru (dakikalık)', 'status', _st,
        'detail', CASE WHEN _tick IS NULL THEN 'Kayıt yok.' ELSE 'Son fiyat güncellemesi ' || _min || ' dk önce.' END);

    -- Oyun fiyati ile bagli hissenin fiyati arasindaki fark. Acikken alim-satim etkisi ve ~1 dk gecikme
    -- kisa sureli fark yaratir; kapaliyken aksam esitlemesinden sonra sifir olmalidir.
    SELECT max(abs(s.current_price / l.last_price - 1)) * 100,
           jsonb_agg(jsonb_build_object('symbol', s.symbol, 'name', s.name,
                     'gap_pct', ROUND((s.current_price / l.last_price - 1) * 100, 2),
                     'fetched_min', ROUND(extract(epoch FROM now() - l.fetched_at)::NUMERIC / 60, 0))
                     ORDER BY abs(s.current_price / l.last_price - 1) DESC)
    INTO _gap, _gaps
    FROM public.stocks AS s
    JOIN public.stock_links AS l ON l.symbol = s.symbol
    WHERE l.last_price > 0;
    _st := CASE
        WHEN _gap IS NULL THEN 'bad'
        WHEN _open AND _gap < 1 THEN 'ok'
        WHEN _open AND _gap < 5 THEN 'warn'
        WHEN NOT _open AND _gap < 0.5 THEN 'ok'
        WHEN NOT _open AND _gap < 3 THEN 'warn'
        ELSE 'bad' END;
    _checks := _checks || jsonb_build_object('label', 'Oyun fiyatı = gerçek fiyat', 'status', _st,
        'detail', CASE WHEN _gap IS NULL THEN 'Bağlı hisse fiyatı yok.'
                       ELSE 'En büyük fark %' || replace(ROUND(_gap, 2)::TEXT, '.', ',')
                            || CASE WHEN _open THEN ' (piyasa açıkken büyük işlemler birkaç dakikalık fark yaratabilir).'
                                    ELSE ' (akşam eşitlemesinden sonra sıfır olmalı).' END END,
        'stocks', coalesce(_gaps, '[]'::jsonb));

    -- ZBEU 100 (piyasanin genel yonu)
    SELECT * INTO _mi FROM public.market_index WHERE id = 1;
    _min := ROUND(extract(epoch FROM now() - _mi.checked_at)::NUMERIC / 60, 0);
    _st := CASE WHEN _mi.checked_at IS NULL THEN 'bad' WHEN NOT _open THEN 'idle'
                WHEN _mi.ok IS NOT TRUE OR _min > 15 THEN 'bad' ELSE 'ok' END;
    _checks := _checks || jsonb_build_object('label', 'ZBEÜ 100 verisi', 'status', _st,
        'detail', CASE WHEN _mi.checked_at IS NULL THEN 'Hiç okunmamış.'
                       ELSE 'Son okuma ' || _min || ' dk önce' || CASE WHEN _mi.ok IS NOT TRUE THEN ': ' || coalesce(_mi.message, 'hata') ELSE '.' END END);

    -- Altin ve doviz
    SELECT * INTO _as FROM public.asset_fetch_status WHERE id = 1;
    _min := ROUND(extract(epoch FROM now() - _as.checked_at)::NUMERIC / 60, 0);
    _st := CASE WHEN _as.checked_at IS NULL THEN 'bad' WHEN _as.ok IS NOT TRUE THEN 'bad'
                WHEN NOT _open THEN 'idle' WHEN _min > 30 THEN 'warn' ELSE 'ok' END;
    _checks := _checks || jsonb_build_object('label', 'Altın ve döviz verisi', 'status', _st,
        'detail', CASE WHEN _as.checked_at IS NULL THEN 'Hiç okunmamış.'
                       ELSE 'Son okuma ' || _min || ' dk önce' || CASE WHEN _as.ok IS NOT TRUE THEN ': ' || coalesce(_as.message, 'hata') ELSE '.' END END);

    -- Zamanlanmis gorevler: son 24 saatteki basarisiz calismalar
    BEGIN
        SELECT jsonb_agg(jsonb_build_object('job', jobname, 'count', n, 'last_at', last_at, 'message', left(msg, 200)) ORDER BY last_at DESC)
        INTO _cron
        FROM (
            SELECT j.jobname, count(*) AS n, max(d.start_time) AS last_at,
                   (array_agg(d.return_message ORDER BY d.start_time DESC))[1] AS msg
            FROM cron.job_run_details AS d
            JOIN cron.job AS j ON j.jobid = d.jobid
            WHERE d.status = 'failed' AND d.start_time > now() - INTERVAL '24 hours'
            GROUP BY j.jobname
        ) AS f;
        _checks := _checks || jsonb_build_object('label', 'Zamanlanmış görevler (son 24 saat)',
            'status', CASE WHEN _cron IS NULL THEN 'ok' ELSE 'warn' END,
            'detail', CASE WHEN _cron IS NULL THEN 'Başarısız çalışma yok.'
                           ELSE jsonb_array_length(_cron) || ' görevde hata var.' END,
            'jobs', coalesce(_cron, '[]'::jsonb));
    EXCEPTION WHEN OTHERS THEN
        _checks := _checks || jsonb_build_object('label', 'Zamanlanmış görevler (son 24 saat)', 'status', 'warn',
            'detail', 'Görev kayıtları okunamadı: ' || left(SQLERRM, 150));
    END;

    RETURN jsonb_build_object('checked_at', now(), 'market_open', _open, 'checks', _checks);
END;
$$;
REVOKE ALL ON FUNCTION public.admin_system_health() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_system_health() TO authenticated;

NOTIFY pgrst, 'reload schema';
