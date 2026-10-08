-- Acilis sinavina sure: sure sunucuda tutulur (sayfayi yenilemek sureyi sifirlamaz).
-- Sure dolduktan sonra gelen cevaplar sayilmaz.

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS quiz_minutes INTEGER NOT NULL DEFAULT 10;

-- quiz_attempts satiri artik sinav baslayinca acilir, gonderilince tamamlanir.
ALTER TABLE public.quiz_attempts
    ADD COLUMN IF NOT EXISTS started_at TIMESTAMPTZ;
ALTER TABLE public.quiz_attempts ALTER COLUMN score DROP NOT NULL;
ALTER TABLE public.quiz_attempts ALTER COLUMN total DROP NOT NULL;
ALTER TABLE public.quiz_attempts ALTER COLUMN bonus DROP NOT NULL;
ALTER TABLE public.quiz_attempts ALTER COLUMN completed_at DROP NOT NULL;
ALTER TABLE public.quiz_attempts ALTER COLUMN completed_at DROP DEFAULT;

UPDATE public.quiz_attempts
SET started_at = completed_at
WHERE started_at IS NULL;

-- Sinav durumu: cozulduyse sonuc, cozulmediyse sorular (dogru cevaplar olmadan, karisik sirada).
-- Baslanmis ama bitmemisse kalan sure de doner.
CREATE OR REPLACE FUNCTION public.get_quiz()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _attempt public.quiz_attempts%ROWTYPE;
    _started BOOLEAN;
    _minutes INTEGER;
    _questions JSONB;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO _attempt FROM public.quiz_attempts WHERE user_id = _uid;
    _started := FOUND;
    IF _started AND _attempt.completed_at IS NOT NULL THEN
        RETURN jsonb_build_object(
            'taken', true,
            'score', _attempt.score,
            'total', _attempt.total,
            'bonus', _attempt.bonus
        );
    END IF;

    SELECT coalesce(quiz_minutes, 10) INTO _minutes FROM public.engine_settings WHERE id = 1;
    _minutes := coalesce(_minutes, 10);

    SELECT coalesce(jsonb_agg(q.item), '[]'::jsonb)
    INTO _questions
    FROM (
        SELECT jsonb_build_object('id', id, 'question', question, 'options', options) AS item
        FROM public.quiz_questions
        WHERE is_active
        ORDER BY random()
    ) AS q;

    RETURN jsonb_build_object(
        'taken', false,
        'questions', _questions,
        'tiers', (SELECT quiz_bonus_tiers FROM public.engine_settings WHERE id = 1),
        'minutes', _minutes,
        'started', _started,
        'seconds_left', CASE WHEN _started THEN
            GREATEST(0, CEIL(_minutes * 60 - EXTRACT(EPOCH FROM (now() - _attempt.started_at))))::INTEGER
        END
    );
END;
$$;

-- Sureyi baslatir (daha once baslatildiysa ayni sure devam eder) ve kalan saniyeyi dondurur.
CREATE OR REPLACE FUNCTION public.start_quiz()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _attempt public.quiz_attempts%ROWTYPE;
    _minutes INTEGER;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.quiz_attempts (user_id, started_at)
    VALUES (_uid, now())
    ON CONFLICT (user_id) DO NOTHING;

    SELECT * INTO _attempt FROM public.quiz_attempts WHERE user_id = _uid;
    IF _attempt.completed_at IS NOT NULL THEN
        RAISE EXCEPTION 'Sınavı daha önce çözdünüz.';
    END IF;

    SELECT coalesce(quiz_minutes, 10) INTO _minutes FROM public.engine_settings WHERE id = 1;
    _minutes := coalesce(_minutes, 10);

    RETURN jsonb_build_object(
        'minutes', _minutes,
        'seconds_left',
            GREATEST(0, CEIL(_minutes * 60 - EXTRACT(EPOCH FROM (now() - _attempt.started_at))))::INTEGER
    );
END;
$$;

-- p_answers: {"<soru id>": secilen sik sirasi (0'dan baslar), ...}
CREATE OR REPLACE FUNCTION public.submit_quiz(p_answers JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _answers JSONB := coalesce(p_answers, '{}'::jsonb);
    _attempt public.quiz_attempts%ROWTYPE;
    _minutes INTEGER;
    _late BOOLEAN;
    _score INTEGER;
    _total INTEGER;
    _bonus NUMERIC;
    _balance NUMERIC;
    _review JSONB;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;
    IF jsonb_typeof(_answers) <> 'object' THEN
        RAISE EXCEPTION 'Cevaplar gecersiz.';
    END IF;

    -- Sure baslatilmadan gonderildiyse simdi baslamis sayilir.
    INSERT INTO public.quiz_attempts (user_id, started_at)
    VALUES (_uid, now())
    ON CONFLICT (user_id) DO NOTHING;

    -- Tek seferlik: satir kilitlenir, ikinci gonderim tamamlanmis satira takilir.
    SELECT * INTO _attempt FROM public.quiz_attempts WHERE user_id = _uid FOR UPDATE;
    IF _attempt.completed_at IS NOT NULL THEN
        RAISE EXCEPTION 'Sınavı daha önce çözdünüz.';
    END IF;

    SELECT coalesce(quiz_minutes, 10) INTO _minutes FROM public.engine_settings WHERE id = 1;
    _minutes := coalesce(_minutes, 10);

    -- Sure dolduktan sonra (30 sn tolerans) gelen cevaplar sayilmaz.
    _late := now() > _attempt.started_at + make_interval(secs => _minutes * 60 + 30);
    IF _late THEN
        _answers := '{}'::jsonb;
    END IF;

    SELECT
        count(*),
        count(*) FILTER (WHERE (_answers ->> q.id::text) = q.correct_index::text),
        coalesce(jsonb_agg(jsonb_build_object(
            'id', q.id,
            'correct_index', q.correct_index,
            'chosen', _answers -> q.id::text
        ) ORDER BY q.id), '[]'::jsonb)
    INTO _total, _score, _review
    FROM public.quiz_questions AS q
    WHERE q.is_active;

    SELECT coalesce(max((tier ->> 'bonus')::NUMERIC), 0)
    INTO _bonus
    FROM public.engine_settings AS s,
         jsonb_array_elements(s.quiz_bonus_tiers) AS tier
    WHERE s.id = 1
      AND _score >= (tier ->> 'min')::INTEGER;
    _bonus := coalesce(_bonus, 0);

    UPDATE public.quiz_attempts
    SET score = _score,
        total = _total,
        bonus = _bonus,
        answers = _answers,
        completed_at = now()
    WHERE user_id = _uid;

    UPDATE public.users
    SET balance = balance + _bonus,
        starting_balance = starting_balance + _bonus
    WHERE id = _uid
    RETURNING balance INTO _balance;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profil bulunamadı.';
    END IF;

    RETURN jsonb_build_object(
        'score', _score,
        'total', _total,
        'bonus', _bonus,
        'balance', _balance,
        'review', _review,
        'late', _late
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_quiz_minutes(p_minutes INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF p_minutes IS NULL OR p_minutes < 1 OR p_minutes > 120 THEN
        RAISE EXCEPTION 'Sınav süresi 1 ile 120 dakika arasında olmalı.';
    END IF;

    UPDATE public.engine_settings SET quiz_minutes = p_minutes WHERE id = 1;
    RETURN p_minutes;
END;
$$;

REVOKE ALL ON FUNCTION public.get_quiz() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.start_quiz() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_quiz(JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_quiz_minutes(INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_quiz() TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_quiz() TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_quiz(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_quiz_minutes(INTEGER) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT quiz_minutes AS sinav_suresi_dakika FROM public.engine_settings WHERE id = 1;
