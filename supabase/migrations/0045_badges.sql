-- Rozetler: oyuncunun yaptiklarina gore kazanilir, bir kez kazanilan rozet kalicidir.
-- Rozetler sunucuda hesaplanir (get_my_badges cagrildiginda); liderlik tablosu rozetleri de gosterir.

CREATE TABLE IF NOT EXISTS public.user_badges (
    user_id   UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    badge     TEXT NOT NULL,
    earned_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, badge)
);

ALTER TABLE public.user_badges ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_badges_read_own" ON public.user_badges;
CREATE POLICY "user_badges_read_own"
    ON public.user_badges FOR SELECT TO authenticated
    USING (user_id = auth.uid());

REVOKE ALL ON public.user_badges FROM anon, authenticated;
GRANT SELECT ON public.user_badges TO authenticated;

-- Butun oyuncularin toplam varligi ve getiri yuzdesi (liderlik ve rozetler ayni hesabi kullanir).
CREATE OR REPLACE FUNCTION public.user_returns()
RETURNS TABLE(user_id UUID, wealth NUMERIC, return_pct NUMERIC)
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT
        h.id,
        h.balance + h.holdings_value,
        CASE WHEN h.starting_balance > 0
             THEN (h.balance + h.holdings_value - h.starting_balance) / h.starting_balance * 100
             ELSE 0
        END
    FROM (
        SELECT
            u.id,
            u.balance,
            u.starting_balance,
            COALESCE((
                SELECT SUM((kv.value ->> 'qty')::NUMERIC * s.current_price)
                FROM jsonb_each(CASE WHEN jsonb_typeof(u.portfolio) = 'object' THEN u.portfolio ELSE '{}'::JSONB END) AS kv
                JOIN public.stocks s ON s.symbol = kv.key
            ), 0)
            + COALESCE((
                SELECT SUM((kv.value ->> 'qty')::NUMERIC * (ap.prices ->> kv.key)::NUMERIC)
                FROM jsonb_each(CASE WHEN jsonb_typeof(u.assets) = 'object' THEN u.assets ELSE '{}'::JSONB END) AS kv
                CROSS JOIN public.asset_prices ap
                WHERE ap.id = 1
            ), 0) AS holdings_value
        FROM public.users u
    ) AS h;
$$;

REVOKE ALL ON FUNCTION public.user_returns() FROM PUBLIC, anon, authenticated;

-- Bir oyuncunun hak ettigi rozetleri kontrol eder ve eksik olanlari ekler.
CREATE OR REPLACE FUNCTION public.evaluate_badges(p_user UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _portfolio JSONB;
    _stock_trades INTEGER;
    _asset_trades INTEGER;
    _pct NUMERIC;
    _ahead INTEGER;
    _earned TEXT[] := ARRAY[]::TEXT[];
    _score INTEGER;
    _total INTEGER;
BEGIN
    IF p_user IS NULL THEN
        RETURN;
    END IF;

    SELECT CASE WHEN jsonb_typeof(u.portfolio) = 'object' THEN u.portfolio ELSE '{}'::JSONB END
    INTO _portfolio
    FROM public.users AS u
    WHERE u.id = p_user;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT count(*) INTO _stock_trades FROM public.transactions WHERE user_id = p_user;
    SELECT count(*) INTO _asset_trades FROM public.asset_transactions WHERE user_id = p_user;

    IF EXISTS (SELECT 1 FROM public.admins WHERE user_id = p_user) THEN
        _earned := array_append(_earned, 'developer');
    END IF;

    IF _stock_trades + _asset_trades >= 1 THEN _earned := array_append(_earned, 'first_trade'); END IF;
    IF _stock_trades + _asset_trades >= 25 THEN _earned := array_append(_earned, 'trader_25'); END IF;
    IF _stock_trades + _asset_trades >= 100 THEN _earned := array_append(_earned, 'trader_100'); END IF;

    -- Tek islemde 30.000 TL ve uzeri
    IF EXISTS (
        SELECT 1 FROM public.transactions
        WHERE user_id = p_user AND quantity * price_per_share >= 30000
    ) OR EXISTS (
        SELECT 1 FROM public.asset_transactions
        WHERE user_id = p_user AND total >= 30000
    ) THEN
        _earned := array_append(_earned, 'whale');
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.transactions AS t
        JOIN public.stocks AS s ON s.symbol = t.stock_symbol
        WHERE t.user_id = p_user AND upper(t.type::TEXT) = 'BUY' AND s.risk_type = 'riskli'
    ) THEN
        _earned := array_append(_earned, 'risk_taker');
    END IF;

    IF EXISTS (
        SELECT 1 FROM public.asset_transactions
        WHERE user_id = p_user AND asset = 'XAU' AND side = 'BUY'
    ) THEN
        _earned := array_append(_earned, 'gold');
    END IF;

    IF (
        SELECT count(DISTINCT asset) FROM public.asset_transactions
        WHERE user_id = p_user AND side = 'BUY' AND asset NOT IN ('XAU', 'XAG')
    ) >= 3 THEN
        _earned := array_append(_earned, 'fx');
    END IF;

    -- Ayni anda 5 farkli hisse
    IF (
        SELECT count(*) FROM jsonb_each(_portfolio) AS kv
        JOIN public.stocks AS s ON s.symbol = kv.key
        WHERE coalesce((kv.value ->> 'qty')::NUMERIC, 0) > 0
    ) >= 5 THEN
        _earned := array_append(_earned, 'diversified');
    END IF;

    -- Ayni anda guvenli, orta ve riskli hisse
    IF (
        SELECT count(DISTINCT s.risk_type) FROM jsonb_each(_portfolio) AS kv
        JOIN public.stocks AS s ON s.symbol = kv.key
        WHERE coalesce((kv.value ->> 'qty')::NUMERIC, 0) > 0
    ) >= 3 THEN
        _earned := array_append(_earned, 'balanced');
    END IF;

    SELECT score, total INTO _score, _total
    FROM public.quiz_attempts
    WHERE user_id = p_user AND completed_at IS NOT NULL;
    IF FOUND THEN
        _earned := array_append(_earned, 'quiz_done');
        IF _total > 0 AND _score >= _total - 1 THEN
            _earned := array_append(_earned, 'quiz_master');
        END IF;
    END IF;

    SELECT r.return_pct INTO _pct FROM public.user_returns() AS r WHERE r.user_id = p_user;
    _pct := coalesce(_pct, 0);
    IF _pct >= 10 THEN _earned := array_append(_earned, 'rising'); END IF;
    IF _pct >= 25 THEN _earned := array_append(_earned, 'bull'); END IF;
    IF _pct <= -10 THEN _earned := array_append(_earned, 'bear'); END IF;

    -- Podyum: en az bir islem yapmis, kardaki ve getiride ilk 3'teki oyuncu
    IF _pct > 0 AND _stock_trades + _asset_trades >= 1 THEN
        SELECT count(*) INTO _ahead FROM public.user_returns() AS r WHERE r.return_pct > _pct;
        IF _ahead < 3 THEN
            _earned := array_append(_earned, 'podium');
        END IF;
    END IF;

    INSERT INTO public.user_badges (user_id, badge)
    SELECT p_user, b FROM unnest(_earned) AS b
    ON CONFLICT (user_id, badge) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public.evaluate_badges(UUID) FROM PUBLIC, anon, authenticated;

-- Oyuncunun rozetleri: once yeni kazanilanlar eklenir, sonra liste doner.
CREATE OR REPLACE FUNCTION public.get_my_badges()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    PERFORM public.evaluate_badges(_uid);

    RETURN (
        SELECT coalesce(
            jsonb_agg(jsonb_build_object('badge', b.badge, 'earned_at', b.earned_at) ORDER BY b.earned_at),
            '[]'::jsonb
        )
        FROM public.user_badges AS b
        WHERE b.user_id = _uid
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_my_badges() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_badges() TO authenticated;

-- Liderlik: rozetler de doner. Donus tipi degistigi icin fonksiyon yeniden olusturulur.
DROP FUNCTION IF EXISTS public.get_leaderboard();

CREATE FUNCTION public.get_leaderboard()
RETURNS TABLE(
    rank_id BIGINT,
    display_name TEXT,
    balance NUMERIC,
    stocks_value NUMERIC,
    total_net_worth NUMERIC,
    starting_balance NUMERIC,
    return_pct NUMERIC,
    badges TEXT[]
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
      ROW_NUMBER() OVER (ORDER BY r.return_pct DESC, u.id ASC),
      u.display_name::TEXT,
      u.balance,
      ROUND(r.wealth - u.balance, 2),
      ROUND(r.wealth, 2),
      u.starting_balance,
      ROUND(r.return_pct, 2),
      COALESCE((
          SELECT array_agg(b.badge ORDER BY b.earned_at)
          FROM public.user_badges AS b
          WHERE b.user_id = u.id
      ), ARRAY[]::TEXT[])
  FROM public.user_returns() AS r
  JOIN public.users AS u ON u.id = r.user_id
  ORDER BY r.return_pct DESC, u.id ASC
  LIMIT 10;
$$;

REVOKE ALL ON FUNCTION public.get_leaderboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_leaderboard() TO anon, authenticated;

-- Oyunu sifirlama: rozetler de silinir (gelistirici rozeti ilk giriste kendiliginden geri gelir).
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
    DELETE FROM public.user_badges WHERE true;
    DELETE FROM public.market_tips WHERE true;
    DELETE FROM public.news_feed WHERE true;
    DELETE FROM public.price_history WHERE true;
    DELETE FROM public.price_history_hourly WHERE true;

    UPDATE public.stocks
    SET previous_close = current_price,
        change = 0,
        change_pct = 0,
        vol_mult = 1,
        breaker_ref = current_price,
        halt_until = NULL,
        impact_pending = 0,
        updated_at = now()
    WHERE symbol IS NOT NULL;

    UPDATE public.market_settings
    SET halt_until = NULL, halt_level = 0
    WHERE id = 1;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM public.stocks;

    INSERT INTO public.price_history_hourly (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM public.stocks;

    RETURN jsonb_build_object('users', _users);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_game() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_game() TO authenticated;

-- Mevcut oyuncularin rozetleri bir kez hesaplanir.
DO $$
DECLARE
    _u RECORD;
BEGIN
    FOR _u IN SELECT id FROM public.users LOOP
        PERFORM public.evaluate_badges(_u.id);
    END LOOP;
END
$$;

NOTIFY pgrst, 'reload schema';

SELECT badge AS rozet, count(*) AS kazanan_sayisi
FROM public.user_badges
GROUP BY badge
ORDER BY count(*) DESC, badge;
