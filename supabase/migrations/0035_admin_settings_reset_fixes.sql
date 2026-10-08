-- 1) Hisse silme: baska tablolardaki baglar silmeyi engellemez, elinde tutanlara parasi iade edilir.
-- 2) Elle fiyat belirlemede taban fiyat ayardan okunur.
-- 3) Oyunu sifirlama (acilis gunu icin) ve ayarlarin admin panelinden degistirilmesi.

-- stocks.symbol'e bagli butun yabanci anahtarlar "sembol degisirse/silinirse beraber degis/silin" yapilir.
DO $$
DECLARE
    _fk RECORD;
    _def TEXT;
BEGIN
    FOR _fk IN
        SELECT c.conname, c.conrelid::regclass AS tbl, pg_get_constraintdef(c.oid) AS def
        FROM pg_constraint AS c
        WHERE c.contype = 'f'
          AND c.confrelid = 'public.stocks'::regclass
    LOOP
        _def := regexp_replace(
            _fk.def,
            '\s+ON (UPDATE|DELETE) (CASCADE|RESTRICT|NO ACTION|SET NULL|SET DEFAULT)',
            '',
            'g'
        );
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', _fk.tbl, _fk.conname);
        EXECUTE format(
            'ALTER TABLE %s ADD CONSTRAINT %I %s ON UPDATE CASCADE ON DELETE CASCADE',
            _fk.tbl, _fk.conname, _def
        );
    END LOOP;
END
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_stock(p_symbol TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _symbol TEXT := upper(trim(coalesce(p_symbol, '')));
    _price NUMERIC;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT current_price INTO _price
    FROM public.stocks
    WHERE symbol = _symbol
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', _symbol;
    END IF;

    -- Elinde bu hisseden olanlara o anki fiyattan (komisyonsuz) iade yapilir.
    UPDATE public.users AS u
    SET balance = u.balance + ROUND(coalesce((u.portfolio -> _symbol ->> 'qty')::NUMERIC, 0) * _price, 2),
        portfolio = u.portfolio - _symbol
    WHERE jsonb_typeof(u.portfolio) = 'object'
      AND u.portfolio ? _symbol;

    DELETE FROM public.market_tips WHERE stock_symbol = _symbol;
    DELETE FROM public.price_history WHERE symbol = _symbol;
    DELETE FROM public.stocks WHERE symbol = _symbol;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_stock(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_stock(TEXT) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_stock_price(
    p_symbol VARCHAR(16),
    p_price NUMERIC
)
RETURNS SETOF public.stocks
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _symbol VARCHAR(16) := upper(trim(p_symbol));
    _new_price NUMERIC(18,4);
    _previous_close NUMERIC(18,4);
    _floor NUMERIC;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT coalesce(price_floor, 1) INTO _floor FROM public.engine_settings WHERE id = 1;
    _floor := coalesce(_floor, 1);

    IF p_price IS NULL OR p_price < _floor THEN
        RAISE EXCEPTION 'Fiyat en az % TL olmalıdır.', _floor;
    END IF;

    _new_price := ROUND(p_price, 4);
    UPDATE public.stocks
    SET current_price = _new_price,
        change = ROUND(_new_price - previous_close, 4),
        change_pct = ROUND(
            CASE WHEN previous_close = 0 THEN 0
                 ELSE ((_new_price - previous_close) / previous_close) * 100
            END,
            4
        ),
        updated_at = now()
    WHERE symbol = _symbol
    RETURNING previous_close INTO _previous_close;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Hisse bulunamadi: %', p_symbol;
    END IF;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    VALUES (_symbol, _new_price, now());

    RETURN QUERY SELECT * FROM public.stocks WHERE symbol = _symbol;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_stock_price(VARCHAR(16), NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_stock_price(VARCHAR(16), NUMERIC) TO authenticated;

-- Temiz baslangic: cuzdanlar, islem gecmisi, sinav, haberler, tuyolar ve grafik gecmisi sifirlanir.
-- Hisselerin kendisi ve guncel fiyatlari korunur.
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
    DELETE FROM public.market_tips WHERE true;
    DELETE FROM public.news_feed WHERE true;
    DELETE FROM public.price_history WHERE true;

    UPDATE public.stocks
    SET previous_close = current_price,
        change = 0,
        change_pct = 0,
        vol_mult = 1,
        breaker_ref = current_price,
        halt_until = NULL,
        updated_at = now()
    WHERE symbol IS NOT NULL;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM public.stocks;

    RETURN jsonb_build_object('users', _users);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_game() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_game() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_get_settings()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    RETURN jsonb_build_object(
        'types', (SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.sort_order), '[]'::jsonb) FROM public.stock_types AS t),
        'engine', (SELECT to_jsonb(e) FROM public.engine_settings AS e WHERE e.id = 1),
        'asset_spread', (SELECT spread FROM public.asset_prices WHERE id = 1),
        'questions', (SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.id), '[]'::jsonb)
                      FROM public.quiz_questions AS q WHERE q.is_active)
    );
END;
$$;

-- p_settings: {"types": [{risk_type, daily_sigma, shock_per_day, shock_min, shock_max, impact_depth}],
--              "engine": {breaker_pct, breaker_minutes, max_trade_impact, quiz_bonus_tiers},
--              "asset_spread": 0.005}   (oranlar kesir: 0.05 = %5)
CREATE OR REPLACE FUNCTION public.admin_save_settings(p_settings JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _t JSONB;
    _engine JSONB := p_settings -> 'engine';
    _tier JSONB;
    _sigma NUMERIC;
    _shocks NUMERIC;
    _smin NUMERIC;
    _smax NUMERIC;
    _depth NUMERIC;
    _breaker_pct NUMERIC;
    _breaker_minutes INTEGER;
    _max_impact NUMERIC;
    _spread NUMERIC;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    FOR _t IN SELECT * FROM jsonb_array_elements(coalesce(p_settings -> 'types', '[]'::jsonb)) LOOP
        _sigma := (_t ->> 'daily_sigma')::NUMERIC;
        _shocks := (_t ->> 'shock_per_day')::NUMERIC;
        _smin := (_t ->> 'shock_min')::NUMERIC;
        _smax := (_t ->> 'shock_max')::NUMERIC;
        _depth := (_t ->> 'impact_depth')::NUMERIC;

        IF _sigma IS NULL OR _sigma < 0 OR _sigma > 0.5 THEN
            RAISE EXCEPTION 'Günlük oynaklık %%0 ile %%50 arasında olmalı.';
        END IF;
        IF _shocks IS NULL OR _shocks < 0 OR _shocks > 50 THEN
            RAISE EXCEPTION 'Günlük şok sayısı 0 ile 50 arasında olmalı.';
        END IF;
        IF _smin IS NULL OR _smax IS NULL OR _smin < 0 OR _smax < _smin OR _smax > 0.5 THEN
            RAISE EXCEPTION 'Şok aralığı geçersiz (en az ≤ en çok ≤ %%50).';
        END IF;
        IF _depth IS NULL OR _depth < 100000 THEN
            RAISE EXCEPTION 'İşlem etkisi çok yüksek; 100.000 TL''lik işlem en fazla %%100 oynatabilir.';
        END IF;

        UPDATE public.stock_types
        SET daily_sigma = _sigma,
            shock_per_day = _shocks,
            shock_min = _smin,
            shock_max = _smax,
            impact_depth = _depth
        WHERE risk_type = _t ->> 'risk_type';
    END LOOP;

    IF _engine IS NOT NULL THEN
        _breaker_pct := (_engine ->> 'breaker_pct')::NUMERIC;
        _breaker_minutes := (_engine ->> 'breaker_minutes')::INTEGER;
        _max_impact := (_engine ->> 'max_trade_impact')::NUMERIC;

        IF _breaker_pct IS NULL OR _breaker_pct < 0.01 OR _breaker_pct > 0.5 THEN
            RAISE EXCEPTION 'Devre kesici eşiği %%1 ile %%50 arasında olmalı.';
        END IF;
        IF _breaker_minutes IS NULL OR _breaker_minutes < 1 OR _breaker_minutes > 120 THEN
            RAISE EXCEPTION 'Devre kesici süresi 1 ile 120 dakika arasında olmalı.';
        END IF;
        IF _max_impact IS NULL OR _max_impact < 0.005 OR _max_impact > 0.5 THEN
            RAISE EXCEPTION 'Tek işlemdeki en fazla etki %%0,5 ile %%50 arasında olmalı.';
        END IF;

        IF jsonb_typeof(_engine -> 'quiz_bonus_tiers') = 'array' THEN
            FOR _tier IN SELECT * FROM jsonb_array_elements(_engine -> 'quiz_bonus_tiers') LOOP
                IF (_tier ->> 'min')::INTEGER IS NULL OR (_tier ->> 'min')::INTEGER < 0
                   OR (_tier ->> 'bonus')::NUMERIC IS NULL OR (_tier ->> 'bonus')::NUMERIC < 0
                   OR (_tier ->> 'bonus')::NUMERIC > 1000000 THEN
                    RAISE EXCEPTION 'Sınav bonus basamakları geçersiz.';
                END IF;
            END LOOP;
        END IF;

        UPDATE public.engine_settings
        SET breaker_pct = _breaker_pct,
            breaker_minutes = _breaker_minutes,
            max_trade_impact = _max_impact,
            quiz_bonus_tiers = CASE
                WHEN jsonb_typeof(_engine -> 'quiz_bonus_tiers') = 'array' THEN _engine -> 'quiz_bonus_tiers'
                ELSE quiz_bonus_tiers
            END
        WHERE id = 1;
    END IF;

    IF p_settings ? 'asset_spread' THEN
        _spread := (p_settings ->> 'asset_spread')::NUMERIC;
        IF _spread IS NULL OR _spread < 0 OR _spread > 0.2 THEN
            RAISE EXCEPTION 'Altın/döviz alış-satış farkı %%0 ile %%20 arasında olmalı.';
        END IF;
        -- prices degismedigi icin bu guncelleme de oyunculara tek mesaj olarak gider.
        UPDATE public.asset_prices SET spread = _spread WHERE id = 1;
    END IF;

    RETURN public.admin_get_settings();
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_save_quiz_question(
    p_id INTEGER,
    p_question TEXT,
    p_options JSONB,
    p_correct_index INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _question TEXT := trim(coalesce(p_question, ''));
    _count INTEGER;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF _question = '' THEN
        RAISE EXCEPTION 'Soru metni boş olamaz.';
    END IF;
    IF jsonb_typeof(p_options) IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION 'Şıklar geçersiz.';
    END IF;

    _count := jsonb_array_length(p_options);
    IF _count < 2 OR _count > 6 THEN
        RAISE EXCEPTION 'Soruda 2 ile 6 arasında şık olmalı.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements_text(p_options) AS opt WHERE trim(opt) = ''
    ) THEN
        RAISE EXCEPTION 'Şıklar boş bırakılamaz.';
    END IF;
    IF p_correct_index IS NULL OR p_correct_index < 0 OR p_correct_index >= _count THEN
        RAISE EXCEPTION 'Doğru cevap işaretlenmeli.';
    END IF;

    UPDATE public.quiz_questions
    SET question = _question,
        options = p_options,
        correct_index = p_correct_index
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Soru bulunamadı.';
    END IF;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_get_settings() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_save_settings(JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_save_quiz_question(INTEGER, TEXT, JSONB, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_get_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_settings(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_quiz_question(INTEGER, TEXT, JSONB, INTEGER) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT c.conrelid::regclass AS tablo, c.conname AS bag, pg_get_constraintdef(c.oid) AS tanim
FROM pg_constraint AS c
WHERE c.contype = 'f' AND c.confrelid = 'public.stocks'::regclass;
