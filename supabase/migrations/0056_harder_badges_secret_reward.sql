-- 1) Rozetler zorlastirildi (birkac islemle toplanamasin) ve gunun sorulari icin iki rozet eklendi.
-- 2) Gizli jenerigi bulan oyuncuya bir kereligine 10.000 TL odul ve gizli "Kasif" rozeti.
-- Eski kurallarla kazanilmis rozetler silinir ve yeni kurallara gore yeniden hesaplanir
-- (gelistirici ve kasif rozetleri korunur).

CREATE OR REPLACE FUNCTION public.evaluate_badges(p_user UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _portfolio JSONB;
    _assets JSONB;
    _trades INTEGER;
    _pct NUMERIC;
    _ahead INTEGER;
    _active INTEGER;
    _earned TEXT[] := ARRAY[]::TEXT[];
    _score INTEGER;
    _total INTEGER;
    _streak INTEGER := 0;
    _day DATE;
BEGIN
    IF p_user IS NULL THEN
        RETURN;
    END IF;

    SELECT CASE WHEN jsonb_typeof(u.portfolio) = 'object' THEN u.portfolio ELSE '{}'::JSONB END,
           CASE WHEN jsonb_typeof(u.assets) = 'object' THEN u.assets ELSE '{}'::JSONB END
    INTO _portfolio, _assets
    FROM public.users AS u
    WHERE u.id = p_user;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT (SELECT count(*) FROM public.transactions WHERE user_id = p_user)
         + (SELECT count(*) FROM public.asset_transactions WHERE user_id = p_user)
    INTO _trades;

    IF EXISTS (SELECT 1 FROM public.admins WHERE user_id = p_user) THEN
        _earned := array_append(_earned, 'developer');
    END IF;

    -- Islem sayisi
    IF _trades >= 1 THEN _earned := array_append(_earned, 'first_trade'); END IF;
    IF _trades >= 50 THEN _earned := array_append(_earned, 'trader_25'); END IF;
    IF _trades >= 250 THEN _earned := array_append(_earned, 'trader_100'); END IF;

    -- Balina: tek islemde 60.000 TL ve uzeri
    IF EXISTS (
        SELECT 1 FROM public.transactions
        WHERE user_id = p_user AND quantity * price_per_share >= 60000
    ) OR EXISTS (
        SELECT 1 FROM public.asset_transactions
        WHERE user_id = p_user AND total >= 60000
    ) THEN
        _earned := array_append(_earned, 'whale');
    END IF;

    -- Cesur Yurek: riskli hisselere toplam 150.000 TL'lik alim
    IF (
        SELECT coalesce(sum(t.quantity * t.price_per_share), 0)
        FROM public.transactions AS t
        JOIN public.stocks AS s ON s.symbol = t.stock_symbol
        WHERE t.user_id = p_user AND upper(t.type::TEXT) = 'BUY' AND s.risk_type = 'riskli'
    ) >= 150000 THEN
        _earned := array_append(_earned, 'risk_taker');
    END IF;

    -- Altin Avcisi: ayni anda en az 5 gram altin
    IF coalesce((_assets -> 'XAU' ->> 'qty')::NUMERIC, 0) >= 5 THEN
        _earned := array_append(_earned, 'gold');
    END IF;

    -- Doviz Burosu: ayni anda 5 farkli dovizde, her biri en az 1.000 TL
    IF (
        SELECT count(*)
        FROM jsonb_each(_assets) AS kv
        CROSS JOIN public.asset_prices AS ap
        WHERE ap.id = 1
          AND kv.key NOT IN ('XAU', 'XAG')
          AND coalesce((kv.value ->> 'qty')::NUMERIC, 0) * coalesce((ap.prices ->> kv.key)::NUMERIC, 0) >= 1000
    ) >= 5 THEN
        _earned := array_append(_earned, 'fx');
    END IF;

    -- Sepetci: ayni anda 8 farkli hissede, her biri en az 2.000 TL
    IF (
        SELECT count(*) FROM jsonb_each(_portfolio) AS kv
        JOIN public.stocks AS s ON s.symbol = kv.key
        WHERE coalesce((kv.value ->> 'qty')::NUMERIC, 0) * s.current_price >= 2000
    ) >= 8 THEN
        _earned := array_append(_earned, 'diversified');
    END IF;

    -- Dengeli Portfoy: ayni anda her turden (guvenli, orta, riskli) en az 2 hisse, her biri en az 2.000 TL
    IF (
        SELECT count(*) FROM (
            SELECT s.risk_type
            FROM jsonb_each(_portfolio) AS kv
            JOIN public.stocks AS s ON s.symbol = kv.key
            WHERE coalesce((kv.value ->> 'qty')::NUMERIC, 0) * s.current_price >= 2000
            GROUP BY s.risk_type
            HAVING count(*) >= 2
        ) AS per_type
    ) >= 3 THEN
        _earned := array_append(_earned, 'balanced');
    END IF;

    -- Acilis sinavi
    SELECT score, total INTO _score, _total
    FROM public.quiz_attempts
    WHERE user_id = p_user AND completed_at IS NOT NULL;
    IF FOUND THEN
        _earned := array_append(_earned, 'quiz_done');
        IF _total > 0 AND _score >= _total THEN
            _earned := array_append(_earned, 'quiz_master');
        END IF;
    END IF;

    -- Gunun sorulari: bir gunde tam puan ve 7 gunluk seri
    IF EXISTS (
        SELECT 1 FROM public.daily_quiz_attempts
        WHERE user_id = p_user AND completed_at IS NOT NULL
          AND correct_count >= coalesce(array_length(question_ids, 1), 0)
          AND coalesce(array_length(question_ids, 1), 0) > 0
    ) THEN
        _earned := array_append(_earned, 'daily_perfect');
    END IF;

    _day := public.daily_quiz_today();
    IF NOT EXISTS (
        SELECT 1 FROM public.daily_quiz_attempts
        WHERE user_id = p_user AND quiz_date = _day AND completed_at IS NOT NULL
    ) THEN
        _day := _day - 1;
    END IF;
    WHILE _streak < 7 AND EXISTS (
        SELECT 1 FROM public.daily_quiz_attempts
        WHERE user_id = p_user AND quiz_date = _day AND completed_at IS NOT NULL
    ) LOOP
        _streak := _streak + 1;
        _day := _day - 1;
    END LOOP;
    IF _streak >= 7 THEN
        _earned := array_append(_earned, 'streak_7');
    END IF;

    -- Getiri
    SELECT r.return_pct INTO _pct FROM public.user_returns() AS r WHERE r.user_id = p_user;
    _pct := coalesce(_pct, 0);
    IF _pct >= 15 THEN _earned := array_append(_earned, 'rising'); END IF;
    IF _pct >= 40 THEN _earned := array_append(_earned, 'bull'); END IF;
    IF _pct <= -20 THEN _earned := array_append(_earned, 'bear'); END IF;

    -- Podyum: en az 10 oyuncunun islem yaptigi bir tabloda, en az %5 getiriyle ilk 3
    IF _pct >= 5 AND _trades >= 1 THEN
        SELECT count(*), count(*) FILTER (WHERE r.return_pct > _pct)
        INTO _active, _ahead
        FROM public.user_returns() AS r
        WHERE EXISTS (SELECT 1 FROM public.transactions AS t WHERE t.user_id = r.user_id)
           OR EXISTS (SELECT 1 FROM public.asset_transactions AS a WHERE a.user_id = r.user_id);
        IF _active >= 10 AND _ahead < 3 THEN
            _earned := array_append(_earned, 'podium');
        END IF;
    END IF;

    INSERT INTO public.user_badges (user_id, badge)
    SELECT p_user, b FROM unnest(_earned) AS b
    ON CONFLICT (user_id, badge) DO NOTHING;
END;
$$;

REVOKE ALL ON FUNCTION public.evaluate_badges(UUID) FROM PUBLIC, anon, authenticated;

-- Gizli jenerik odulu: oyuncu basina bir kez. "Kasif" rozeti odulun alindigini da kaydeder.
CREATE OR REPLACE FUNCTION public.claim_secret_reward()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _reward CONSTANT NUMERIC := 10000;
    _inserted INTEGER;
    _balance NUMERIC;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = _uid) THEN
        RAISE EXCEPTION 'Profil bulunamadı.';
    END IF;

    INSERT INTO public.user_badges (user_id, badge)
    VALUES (_uid, 'explorer')
    ON CONFLICT (user_id, badge) DO NOTHING;
    GET DIAGNOSTICS _inserted = ROW_COUNT;

    IF _inserted = 1 THEN
        UPDATE public.users SET balance = balance + _reward WHERE id = _uid;
    END IF;

    SELECT balance INTO _balance FROM public.users WHERE id = _uid;

    RETURN jsonb_build_object(
        'claimed', _inserted = 1,
        'reward', _reward,
        'balance', _balance
    );
END;
$$;

REVOKE ALL ON FUNCTION public.claim_secret_reward() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_secret_reward() TO authenticated;

-- Eski kurallarla kazanilan rozetler temizlenir, yeni kurallarla yeniden hesaplanir.
DELETE FROM public.user_badges WHERE badge NOT IN ('developer', 'explorer');

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
