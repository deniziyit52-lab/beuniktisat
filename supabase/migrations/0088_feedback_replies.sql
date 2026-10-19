-- Oneri kutusuna cevap: yonetici bir mesaja cevap yazar (admin_reply_feedback); oyuncu cevabi oneri penceresinde,
-- kendi mesajinin altinda gorur (my_feedback). Gorulmemis cevap varsa oneri dugmesinde nokta cikar; pencere
-- acilinca cevaplar goruldu sayilir (mark_feedback_replies_seen). Bildirimleri acik oyuncuya telefon bildirimi de gider.

ALTER TABLE public.feedback ADD COLUMN IF NOT EXISTS reply TEXT;
ALTER TABLE public.feedback ADD COLUMN IF NOT EXISTS replied_at TIMESTAMPTZ;
ALTER TABLE public.feedback ADD COLUMN IF NOT EXISTS reply_seen BOOLEAN NOT NULL DEFAULT false;

-- Yonetici: 0072'deki liste; fark: cevap, cevap zamani ve oyuncunun cevabi gorup gormedigi.
CREATE OR REPLACE FUNCTION public.admin_list_feedback()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    RETURN coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                   'id', f.id, 'kind', f.kind, 'message', f.message, 'is_read', f.is_read,
                   'created_at', f.created_at, 'name', u.display_name, 'nickname', u.nickname, 'email', u.email,
                   'reply', f.reply, 'replied_at', f.replied_at, 'reply_seen', f.reply_seen)
               ORDER BY f.created_at DESC)
        FROM (SELECT * FROM public.feedback ORDER BY created_at DESC LIMIT 300) AS f
        LEFT JOIN public.users AS u ON u.id = f.user_id
    ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_feedback() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_feedback() TO authenticated;

-- Yonetici cevap yazar ya da duzeltir; bos cevap mevcut cevabi kaldirir. Cevaplanan mesaj okundu sayilir.
CREATE OR REPLACE FUNCTION public.admin_reply_feedback(p_id BIGINT, p_reply TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _reply TEXT := nullif(btrim(coalesce(p_reply, '')), '');
    _user UUID;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF char_length(_reply) > 1000 THEN
        RAISE EXCEPTION 'Cevap en fazla 1000 karakter olabilir.';
    END IF;

    UPDATE public.feedback
    SET reply = _reply,
        replied_at = CASE WHEN _reply IS NULL THEN NULL ELSE now() END,
        reply_seen = _reply IS NULL,
        is_read = true
    WHERE id = p_id
    RETURNING user_id INTO _user;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Mesaj bulunamadı.';
    END IF;

    -- Telefon bildirimi; yazilamasa bile cevap kaydedilmis kalir.
    IF _reply IS NOT NULL AND _user IS NOT NULL THEN
        BEGIN
            INSERT INTO public.push_queue (user_id, title, body, url)
            SELECT DISTINCT _user, '💬 Mesajına cevap geldi',
                   left(_reply, 140) || CASE WHEN char_length(_reply) > 140 THEN '…' ELSE '' END,
                   '/?oneri=1'
            FROM public.push_subscriptions WHERE user_id = _user;
            IF FOUND THEN
                PERFORM public.push_dispatch();
            END IF;
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END IF;
    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reply_feedback(BIGINT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reply_feedback(BIGINT, TEXT) TO authenticated;

-- Oyuncu: kendi son 20 mesaji ve cevaplari.
CREATE OR REPLACE FUNCTION public.my_feedback()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN '[]'::jsonb;
    END IF;
    RETURN coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                   'id', f.id, 'kind', f.kind, 'message', f.message, 'created_at', f.created_at,
                   'reply', f.reply, 'replied_at', f.replied_at, 'reply_seen', f.reply_seen)
               ORDER BY f.created_at DESC)
        FROM (SELECT * FROM public.feedback WHERE user_id = auth.uid() ORDER BY created_at DESC LIMIT 20) AS f
    ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.my_feedback() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_feedback() TO authenticated;

CREATE OR REPLACE FUNCTION public.mark_feedback_replies_seen()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _n INTEGER;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN 0;
    END IF;
    UPDATE public.feedback SET reply_seen = true
    WHERE user_id = auth.uid() AND reply IS NOT NULL AND NOT reply_seen;
    GET DIAGNOSTICS _n = ROW_COUNT;
    RETURN _n;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_feedback_replies_seen() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_feedback_replies_seen() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT 'Öneri kutusu cevapları' AS konu,
       CASE WHEN to_regprocedure('public.admin_reply_feedback(bigint,text)') IS NOT NULL
             AND to_regprocedure('public.my_feedback()') IS NOT NULL THEN 'kuruldu' ELSE 'KURULAMADI' END AS sonuc;
