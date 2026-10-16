-- Gunun sorulari odulu getiriyi sisirmesin (kullanici karari 17.10.2026).
-- Onceden odul yalnizca bakiyeye ekleniyordu; baslangic sermayesi ayni kaldigi icin kar gibi sayiliyor,
-- hic islem yapmayan oyuncu soru cozerek siralamada yukseliyordu. Artik acilis sinavi bonusu gibi
-- hem bakiyeye hem starting_balance'a eklenir: para yatirimda kullanilir, getiri yuzdesi degismez.
-- Bugune kadar verilmis oduller de bir kez baslangic sermayesine eklenir (bayrakla, iki kez calismaz).

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS daily_reward_in_start BOOLEAN NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.answer_daily_question(p_question_id INTEGER, p_choice INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _today DATE := public.daily_quiz_today();
    _attempt public.daily_quiz_attempts%ROWTYPE;
    _question public.daily_questions%ROWTYPE;
    _reward NUMERIC;
    _chosen INTEGER;
    _correct BOOLEAN;
    _added NUMERIC := 0;
    _done BOOLEAN;
    _balance NUMERIC;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO _attempt
    FROM public.daily_quiz_attempts
    WHERE user_id = _uid AND quiz_date = _today
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Bugünün soruları değişti. Pencereyi kapatıp yeniden açın.';
    END IF;
    IF NOT (p_question_id = ANY(_attempt.question_ids)) THEN
        RAISE EXCEPTION 'Bu soru bugünün soruları arasında değil.';
    END IF;

    SELECT * INTO _question FROM public.daily_questions WHERE id = p_question_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Soru bulunamadı.';
    END IF;

    IF _attempt.answers ? p_question_id::text THEN
        -- Daha once isaretlenmis: ilk cevap gecerlidir, odul tekrar verilmez.
        _chosen := (_attempt.answers ->> p_question_id::text)::INTEGER;
        _correct := _chosen = _question.correct_index;
    ELSE
        IF p_choice IS NULL OR p_choice < 0 OR p_choice >= jsonb_array_length(_question.options) THEN
            RAISE EXCEPTION 'Geçersiz şık.';
        END IF;
        _chosen := p_choice;
        _correct := _chosen = _question.correct_index;

        IF _correct THEN
            SELECT coalesce(daily_quiz_reward, 500) INTO _reward FROM public.engine_settings WHERE id = 1;
            _added := coalesce(_reward, 500);
        END IF;

        UPDATE public.daily_quiz_attempts
        SET answers = answers || jsonb_build_object(p_question_id::text, _chosen),
            correct_count = correct_count + CASE WHEN _correct THEN 1 ELSE 0 END,
            reward = reward + _added,
            completed_at = CASE
                WHEN (SELECT count(*) FROM jsonb_object_keys(answers || jsonb_build_object(p_question_id::text, _chosen)))
                     >= coalesce(array_length(question_ids, 1), 0)
                THEN now() ELSE completed_at END
        WHERE user_id = _uid AND quiz_date = _today
        RETURNING * INTO _attempt;

        IF _added > 0 THEN
            -- Odul baslangic sermayesine de eklenir: getiri yuzdesini degistirmez.
            UPDATE public.users
            SET balance = balance + _added,
                starting_balance = starting_balance + _added
            WHERE id = _uid;
        END IF;
    END IF;

    _done := _attempt.completed_at IS NOT NULL;
    SELECT balance INTO _balance FROM public.users WHERE id = _uid;

    RETURN jsonb_build_object(
        'id', _question.id,
        'chosen', _chosen,
        'correct', _correct,
        'correct_index', _question.correct_index,
        'explanation', _question.explanation,
        'reward_added', _added,
        'correct_count', _attempt.correct_count,
        'reward', _attempt.reward,
        'done', _done,
        'balance', _balance
    );
END;
$$;

-- Bugune kadarki oduller (oyun sifirlaninca daily_quiz_attempts da silindigi icin yalnizca bu sezonunkiler).
DO $$
BEGIN
    IF NOT coalesce((SELECT daily_reward_in_start FROM public.engine_settings WHERE id = 1), false) THEN
        UPDATE public.users u
        SET starting_balance = u.starting_balance + s.total
        FROM (
            SELECT user_id, sum(reward) AS total
            FROM public.daily_quiz_attempts
            GROUP BY user_id
            HAVING sum(reward) > 0
        ) s
        WHERE u.id = s.user_id;
        UPDATE public.engine_settings SET daily_reward_in_start = true WHERE id = 1;
    END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
