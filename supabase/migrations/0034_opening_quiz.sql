-- Acilis sinavi: 10 soru, tek seferlik, cevaplar yalnizca sunucuda.
-- Sonuca gore baslangic bakiyesine bonus eklenir; liderlik getiri yuzdesine gore siralanir.

CREATE TABLE IF NOT EXISTS public.quiz_questions (
    id            SERIAL PRIMARY KEY,
    question      TEXT NOT NULL,
    options       JSONB NOT NULL CHECK (jsonb_typeof(options) = 'array'),
    correct_index SMALLINT NOT NULL CHECK (correct_index >= 0),
    is_active     BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.quiz_attempts (
    user_id      UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    score        INTEGER NOT NULL,
    total        INTEGER NOT NULL,
    bonus        NUMERIC NOT NULL,
    answers      JSONB NOT NULL DEFAULT '{}'::jsonb,
    completed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.quiz_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quiz_attempts ENABLE ROW LEVEL SECURITY;

-- Sorulara siteden dogrudan erisim yok (dogru cevap sizmasin); yalnizca fonksiyonlar okur.
REVOKE ALL ON public.quiz_questions, public.quiz_attempts FROM anon, authenticated;

-- Bonus basamaklari: en az "min" dogru yapan "bonus" TL kazanir (en yuksek uyan basamak gecerli).
ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS quiz_bonus_tiers JSONB NOT NULL
    DEFAULT '[{"min": 4, "bonus": 10000}, {"min": 7, "bonus": 20000}, {"min": 9, "bonus": 30000}]'::jsonb;

-- Getiri yuzdesi bu tutara gore hesaplanir: 100.000 + sinav bonusu.
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS starting_balance NUMERIC NOT NULL DEFAULT 100000;

INSERT INTO public.quiz_questions (question, options, correct_index)
SELECT q.question, q.options::jsonb, q.correct_index
FROM (VALUES
    ('Diğer koşullar sabitken bir malın fiyatı artarsa, o mala olan talep miktarı genellikle ne olur?',
     '["Artar", "Azalır", "Değişmez", "Önce artar sonra sabitlenir"]', 1),
    ('Enflasyon nedir?',
     '["Fiyatlar genel düzeyinin sürekli artması", "İşsizlik oranının düşmesi", "Bir ülkenin ihracatının artması", "Faiz oranlarının sıfırlanması"]', 0),
    ('Merkez bankası politika faizini artırdığında genellikle hangisi beklenir?',
     '["Krediler ucuzlar, harcamalar artar", "Enflasyon hızlanır", "Borçlanma pahalılaşır, harcamalar yavaşlar", "Hisse senedi sayısı artar"]', 2),
    ('Bir şirketin hisse senedini satın alan kişi neye sahip olur?',
     '["Şirkete verdiği borcun alacağına", "Şirketin ürünlerinde indirim hakkına", "Sabit ve garantili bir faiz gelirine", "Şirkette bir ortaklık payına"]', 3),
    ('Yatırımcılar portföylerini neden çeşitlendirir?',
     '["Vergi ödememek için", "Riski farklı varlıklara dağıtarak azaltmak için", "Daha fazla komisyon ödemek için", "Getiriyi garanti altına almak için"]', 1),
    ('Fırsat maliyeti neyi ifade eder?',
     '["Bir seçim yapılırken vazgeçilen en iyi alternatifin değerini", "Bir ürünün üretim maliyetini", "Bankaya ödenen faiz tutarını", "Bir malın indirimli fiyatını"]', 0),
    ('Dolar kuru 40 TL''den 50 TL''ye çıkarsa Türk lirası için hangisi söylenir?',
     '["Dolar karşısında değer kazanmıştır", "Değeri değişmemiştir", "Dolar karşısında değer kaybetmiştir", "Enflasyon sıfırlanmıştır"]', 2),
    ('Gayri Safi Yurt İçi Hasıla (GSYH) neyi ölçer?',
     '["Bir ülkedeki toplam nüfusu", "Devletin topladığı vergileri", "Borsadaki hisselerin toplam değerini", "Bir ülkede belirli bir dönemde üretilen nihai mal ve hizmetlerin toplam değerini"]', 3),
    ('Bir ürünün arzı sabitken ürüne olan talep artarsa fiyatı genellikle ne olur?',
     '["Yükselir", "Düşer", "Değişmez", "Sıfıra iner"]', 0),
    ('Beklenen getirisi yüksek olan yatırımlar için genellikle hangisi geçerlidir?',
     '["Riskleri yoktur", "Riskleri de yüksektir", "Devlet garantisi altındadır", "Hiç değer kaybetmezler"]', 1)
) AS q(question, options, correct_index)
WHERE NOT EXISTS (SELECT 1 FROM public.quiz_questions);

-- Sinav durumu: cozulduyse sonuc, cozulmediyse sorular (dogru cevaplar olmadan, karisik sirada).
CREATE OR REPLACE FUNCTION public.get_quiz()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _attempt public.quiz_attempts%ROWTYPE;
    _questions JSONB;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO _attempt FROM public.quiz_attempts WHERE user_id = _uid;
    IF FOUND THEN
        RETURN jsonb_build_object(
            'taken', true,
            'score', _attempt.score,
            'total', _attempt.total,
            'bonus', _attempt.bonus
        );
    END IF;

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
        'tiers', (SELECT quiz_bonus_tiers FROM public.engine_settings WHERE id = 1)
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

    -- Tek seferlik: ikinci gonderim birincil anahtara takilir.
    BEGIN
        INSERT INTO public.quiz_attempts (user_id, score, total, bonus, answers)
        VALUES (_uid, _score, _total, coalesce(_bonus, 0), _answers);
    EXCEPTION WHEN unique_violation THEN
        RAISE EXCEPTION 'Sınavı daha önce çözdünüz.';
    END;

    UPDATE public.users
    SET balance = balance + coalesce(_bonus, 0),
        starting_balance = starting_balance + coalesce(_bonus, 0)
    WHERE id = _uid
    RETURNING balance INTO _balance;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Profil bulunamadı.';
    END IF;

    RETURN jsonb_build_object(
        'score', _score,
        'total', _total,
        'bonus', coalesce(_bonus, 0),
        'balance', _balance,
        'review', _review
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_quiz() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.submit_quiz(JSONB) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_quiz() TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_quiz(JSONB) TO authenticated;

-- Liderlik: getiri yuzdesine gore. Donus tipi degistigi icin fonksiyon yeniden olusturulur.
DROP FUNCTION IF EXISTS public.get_leaderboard();

CREATE FUNCTION public.get_leaderboard()
RETURNS TABLE(
    rank_id BIGINT,
    display_name TEXT,
    balance NUMERIC,
    stocks_value NUMERIC,
    total_net_worth NUMERIC,
    starting_balance NUMERIC,
    return_pct NUMERIC
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  WITH holdings AS (
    SELECT
        u.id,
        u.display_name::TEXT AS display_name,
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
  ),
  scored AS (
    SELECT
        h.*,
        CASE WHEN h.starting_balance > 0
             THEN (h.balance + h.holdings_value - h.starting_balance) / h.starting_balance * 100
             ELSE 0
        END AS pct
    FROM holdings h
  )
  SELECT
      ROW_NUMBER() OVER (ORDER BY pct DESC, id ASC),
      display_name,
      balance,
      ROUND(holdings_value, 2),
      ROUND(balance + holdings_value, 2),
      starting_balance,
      ROUND(pct, 2)
  FROM scored
  ORDER BY pct DESC, id ASC
  LIMIT 10;
$$;

REVOKE ALL ON FUNCTION public.get_leaderboard() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_leaderboard() TO anon, authenticated;

NOTIFY pgrst, 'reload schema';

SELECT count(*) AS soru_sayisi FROM public.quiz_questions WHERE is_active;
