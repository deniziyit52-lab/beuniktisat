-- Oneri kutusu: oyuncular istek, oneri, hata bildirimi ve gorus yazar; yalnizca yoneticiler okur.
-- Tabloya istemciden dogrudan erisilmez; yazma submit_feedback, okuma ve yonetim admin_* fonksiyonlariyla.

CREATE TABLE IF NOT EXISTS public.feedback (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    -- Oyuncu silinse de mesaj kalir (yazan bos gorunur).
    user_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
    kind TEXT NOT NULL CHECK (kind IN ('oneri', 'hata', 'gorus')),
    message TEXT NOT NULL CHECK (char_length(message) BETWEEN 3 AND 1000),
    is_read BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS feedback_created_idx ON public.feedback (created_at DESC);
CREATE INDEX IF NOT EXISTS feedback_user_created_idx ON public.feedback (user_id, created_at);

ALTER TABLE public.feedback ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.feedback FROM anon, authenticated;

-- Oyuncu mesaj gonderir. Kotuye kullanima karsi kisi basi son 24 saatte en fazla 10 mesaj.
CREATE OR REPLACE FUNCTION public.submit_feedback(p_kind TEXT, p_message TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _kind TEXT := lower(btrim(coalesce(p_kind, '')));
    _msg TEXT := btrim(coalesce(p_message, ''));
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Mesaj göndermek için giriş yapmalısın.' USING ERRCODE = '42501';
    END IF;
    IF _kind NOT IN ('oneri', 'hata', 'gorus') THEN
        RAISE EXCEPTION 'Mesaj türü seçilmeli.';
    END IF;
    IF char_length(_msg) < 3 THEN
        RAISE EXCEPTION 'Mesaj çok kısa.';
    END IF;
    IF char_length(_msg) > 1000 THEN
        RAISE EXCEPTION 'Mesaj en fazla 1000 karakter olabilir.';
    END IF;
    IF (SELECT count(*) FROM public.feedback
        WHERE user_id = _uid AND created_at > now() - INTERVAL '24 hours') >= 10 THEN
        RAISE EXCEPTION 'Bugün yeterince mesaj gönderdin, teşekkürler! Yarın yine yazabilirsin.';
    END IF;

    INSERT INTO public.feedback (user_id, kind, message) VALUES (_uid, _kind, _msg);
    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.submit_feedback(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_feedback(TEXT, TEXT) TO authenticated;

-- Yonetici: son 300 mesaj, yazanin gercek adi, takma adi ve e-postasiyla.
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
                   'created_at', f.created_at, 'name', u.display_name, 'nickname', u.nickname, 'email', u.email)
               ORDER BY f.created_at DESC)
        FROM (SELECT * FROM public.feedback ORDER BY created_at DESC LIMIT 300) AS f
        LEFT JOIN public.users AS u ON u.id = f.user_id
    ), '[]'::jsonb);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_list_feedback() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_feedback() TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_feedback_read(p_id BIGINT, p_read BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    UPDATE public.feedback SET is_read = coalesce(p_read, true) WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Mesaj bulunamadı.';
    END IF;
    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_feedback_read(BIGINT, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_feedback_read(BIGINT, BOOLEAN) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_delete_feedback(p_id BIGINT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    DELETE FROM public.feedback WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Mesaj bulunamadı.';
    END IF;
    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_feedback(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_feedback(BIGINT) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT 'Öneri kutusu' AS konu,
       CASE WHEN to_regprocedure('public.submit_feedback(text,text)') IS NOT NULL THEN 'kuruldu' ELSE 'KURULAMADI' END AS sonuc;
