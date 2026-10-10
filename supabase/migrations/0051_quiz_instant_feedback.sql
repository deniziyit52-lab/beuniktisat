-- Ogretici sinav: her soru isaretlendigi anda dogru/yanlis ve aciklamasi gosterilir.
-- Cevap sunucuda kilitlenir (ilk isaretlenen gecerlidir), dogru cevap ancak ondan sonra aciklanir.

ALTER TABLE public.quiz_questions ADD COLUMN IF NOT EXISTS explanation TEXT;

-- Hazir 10 sorunun aciklamalari (soru metni degistirilmediyse eslesir; yonetici panelinden duzenlenebilir).
UPDATE public.quiz_questions AS q
SET explanation = e.explanation
FROM (VALUES
    ('Diğer koşullar sabitken bir malın fiyatı artarsa, o mala olan talep miktarı genellikle ne olur?',
     'Talep kanunu: fiyat yükseldikçe tüketiciler o maldan daha az almak ister. Fiyat ile talep edilen miktar ters yönde hareket eder.'),
    ('Enflasyon nedir?',
     'Enflasyon tek bir malın pahalanması değil, fiyatların genelinin sürekli yükselmesidir. Paranın satın alma gücü düşer.'),
    ('Merkez bankası politika faizini artırdığında genellikle hangisi beklenir?',
     'Faiz artınca kredi kullanmak pahalılaşır; tüketim ve yatırım yavaşlar. Merkez bankaları enflasyonu düşürmek için bu yola başvurur.'),
    ('Bir şirketin hisse senedini satın alan kişi neye sahip olur?',
     'Hisse senedi ortaklık payıdır: şirketin kârına ve zararına ortak olursun. Sabit ve garantili bir gelir vermez; o özellik tahvile aittir.'),
    ('Yatırımcılar portföylerini neden çeşitlendirir?',
     'Parayı farklı varlıklara dağıtmak, tek bir yatırımın kötü gitmesinin toplam etkisini azaltır. Çeşitlendirme riski düşürür ama getiriyi garanti etmez.'),
    ('Fırsat maliyeti neyi ifade eder?',
     'Bir seçim yaptığında vazgeçtiğin en iyi alternatifin değeridir. Paranı bir hisseye yatırdıysan, fırsat maliyetin o parayla yapabileceğin en iyi diğer yatırımın getirisidir.'),
    ('Dolar kuru 40 TL''den 50 TL''ye çıkarsa Türk lirası için hangisi söylenir?',
     'Bir dolar almak için daha fazla lira gerekiyorsa lira dolar karşısında değer kaybetmiştir. Kur yükselişi, yerli paranın ucuzlaması demektir.'),
    ('Gayri Safi Yurt İçi Hasıla (GSYH) neyi ölçer?',
     'GSYH, bir ülkede belirli bir dönemde üretilen nihai mal ve hizmetlerin toplam değeridir; ekonominin büyüklüğünü gösterir. Ara mallar çifte sayım olmasın diye dahil edilmez.'),
    ('Bir ürünün arzı sabitken ürüne olan talep artarsa fiyatı genellikle ne olur?',
     'Aynı miktardaki ürünü daha çok kişi isterse alıcılar birbiriyle yarışır ve fiyat yükselir. Bu oyunda da bir hisseye yoğun alım gelince fiyatı artar.'),
    ('Beklenen getirisi yüksek olan yatırımlar için genellikle hangisi geçerlidir?',
     'Risk ve getiri birlikte hareket eder: yüksek getiri beklentisi, yüksek kayıp ihtimaliyle birlikte gelir. Bu oyundaki "Riskli" hisseler bunun örneğidir.')
) AS e(question, explanation)
WHERE q.question = e.question
  AND q.explanation IS NULL;

-- Sinav durumu: sorular, sure bilgisi ve (sinav yarida kaldiysa) daha once isaretlenen sorularin sonuclari.
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
    _answered JSONB := '[]'::jsonb;
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

    SELECT coalesce(quiz_minutes, 5) INTO _minutes FROM public.engine_settings WHERE id = 1;
    _minutes := coalesce(_minutes, 5);

    SELECT coalesce(jsonb_agg(q.item), '[]'::jsonb)
    INTO _questions
    FROM (
        SELECT jsonb_build_object('id', id, 'question', question, 'options', options) AS item
        FROM public.quiz_questions
        WHERE is_active
        ORDER BY random()
    ) AS q;

    -- Yalnizca oyuncunun zaten isaretledigi sorularin dogru cevabi doner.
    IF _started THEN
        SELECT coalesce(jsonb_agg(jsonb_build_object(
            'id', q.id,
            'chosen', (_attempt.answers ->> q.id::text)::INTEGER,
            'correct_index', q.correct_index,
            'explanation', q.explanation
        )), '[]'::jsonb)
        INTO _answered
        FROM public.quiz_questions AS q
        WHERE q.is_active AND _attempt.answers ? q.id::text;
    END IF;

    RETURN jsonb_build_object(
        'taken', false,
        'questions', _questions,
        'tiers', (SELECT quiz_bonus_tiers FROM public.engine_settings WHERE id = 1),
        'minutes', _minutes,
        'started', _started,
        'seconds_left', CASE WHEN _started THEN
            GREATEST(0, CEIL(_minutes * 60 - EXTRACT(EPOCH FROM (now() - _attempt.started_at))))::INTEGER
        END,
        'answered', _answered,
        'instant_feedback', true
    );
END;
$$;

-- Tek bir soruyu cevaplar: cevap kilitlenir, dogru sik ve aciklama doner.
CREATE OR REPLACE FUNCTION public.answer_quiz_question(p_question_id INTEGER, p_choice INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _attempt public.quiz_attempts%ROWTYPE;
    _question public.quiz_questions%ROWTYPE;
    _minutes INTEGER;
    _chosen INTEGER;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    INSERT INTO public.quiz_attempts (user_id, started_at)
    VALUES (_uid, now())
    ON CONFLICT (user_id) DO NOTHING;

    SELECT * INTO _attempt FROM public.quiz_attempts WHERE user_id = _uid FOR UPDATE;
    IF _attempt.completed_at IS NOT NULL THEN
        RAISE EXCEPTION 'Sınavı daha önce çözdünüz.';
    END IF;

    SELECT coalesce(quiz_minutes, 5) INTO _minutes FROM public.engine_settings WHERE id = 1;
    _minutes := coalesce(_minutes, 5);
    IF now() > _attempt.started_at + make_interval(secs => _minutes * 60 + 30) THEN
        RAISE EXCEPTION 'Süre doldu; bu soru artık cevaplanamaz.';
    END IF;

    SELECT * INTO _question
    FROM public.quiz_questions
    WHERE id = p_question_id AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Soru bulunamadı.';
    END IF;

    IF _attempt.answers ? p_question_id::text THEN
        -- Daha once isaretlenmis: ilk cevap gecerlidir, degistirilemez.
        _chosen := (_attempt.answers ->> p_question_id::text)::INTEGER;
    ELSE
        IF p_choice IS NULL OR p_choice < 0 OR p_choice >= jsonb_array_length(_question.options) THEN
            RAISE EXCEPTION 'Geçersiz şık.';
        END IF;
        _chosen := p_choice;
        UPDATE public.quiz_attempts
        SET answers = coalesce(answers, '{}'::jsonb) || jsonb_build_object(p_question_id::text, _chosen)
        WHERE user_id = _uid;
    END IF;

    RETURN jsonb_build_object(
        'id', _question.id,
        'chosen', _chosen,
        'correct', _chosen = _question.correct_index,
        'correct_index', _question.correct_index,
        'explanation', _question.explanation
    );
END;
$$;

-- Sinavi bitirir. Tek tek isaretlenen (kilitli) cevaplar esas alinir.
-- p_answers yalnizca henuz isaretlenmemis sorular icin ve sure dolmadiysa dikkate alinir.
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

    SELECT coalesce(quiz_minutes, 5) INTO _minutes FROM public.engine_settings WHERE id = 1;
    _minutes := coalesce(_minutes, 5);

    -- Sure dolduktan sonra (30 sn tolerans) yalnizca suresi icinde kilitlenmis cevaplar sayilir.
    _late := now() > _attempt.started_at + make_interval(secs => _minutes * 60 + 30);
    IF _late THEN
        _answers := coalesce(_attempt.answers, '{}'::jsonb);
    ELSE
        _answers := _answers || coalesce(_attempt.answers, '{}'::jsonb);
    END IF;

    SELECT
        count(*),
        count(*) FILTER (WHERE (_answers ->> q.id::text) = q.correct_index::text),
        coalesce(jsonb_agg(jsonb_build_object(
            'id', q.id,
            'correct_index', q.correct_index,
            'chosen', _answers -> q.id::text,
            'explanation', q.explanation
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

-- Soru duzenleme: aciklama alani eklendi.
DROP FUNCTION IF EXISTS public.admin_save_quiz_question(INTEGER, TEXT, JSONB, INTEGER);

CREATE OR REPLACE FUNCTION public.admin_save_quiz_question(
    p_id INTEGER,
    p_question TEXT,
    p_options JSONB,
    p_correct_index INTEGER,
    p_explanation TEXT DEFAULT NULL
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
        correct_index = p_correct_index,
        explanation = nullif(left(trim(coalesce(p_explanation, '')), 600), '')
    WHERE id = p_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Soru bulunamadı.';
    END IF;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.get_quiz() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.answer_quiz_question(INTEGER, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_quiz(JSONB) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_save_quiz_question(INTEGER, TEXT, JSONB, INTEGER, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_quiz() TO authenticated;
GRANT EXECUTE ON FUNCTION public.answer_quiz_question(INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_quiz(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_quiz_question(INTEGER, TEXT, JSONB, INTEGER, TEXT) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT id, left(question, 50) AS soru, explanation IS NOT NULL AS aciklama_var
FROM public.quiz_questions
WHERE is_active
ORDER BY id;
