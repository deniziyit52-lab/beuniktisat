-- 1) Gazetede en fazla 20 haber durur: yeni haber eklenince en eskiler kendiliginden silinir.
-- 2) Admin panelinden gercek ekonomi haberlerini cekme (fetch-economy-news fonksiyonunu tetikler).

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.trim_news_feed()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    DELETE FROM public.news_feed
    WHERE id IN (
        SELECT id
        FROM public.news_feed
        ORDER BY created_at DESC, id DESC
        OFFSET 20
    );
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS news_feed_keep_latest ON public.news_feed;
CREATE TRIGGER news_feed_keep_latest
    AFTER INSERT ON public.news_feed
    FOR EACH STATEMENT
    EXECUTE FUNCTION public.trim_news_feed();

-- Su an 20'den fazla haber varsa fazlasi hemen silinir.
DELETE FROM public.news_feed
WHERE id IN (
    SELECT id
    FROM public.news_feed
    ORDER BY created_at DESC, id DESC
    OFFSET 20
);

-- Istegi gonderir ve istek numarasini dondurur; cevap birkac saniye sonra admin_news_fetch_result ile okunur.
-- Gizli anahtar veritabaninda (vault) kalir, siteye hic gitmez.
CREATE OR REPLACE FUNCTION public.admin_fetch_real_news()
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _secret TEXT;
    _request_id BIGINT;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT decrypted_secret INTO _secret
    FROM vault.decrypted_secrets
    WHERE name = 'borsa_news_cron_secret';

    IF _secret IS NULL THEN
        RAISE EXCEPTION 'Haber servisinin gizli anahtarı (borsa_news_cron_secret) veritabanında bulunamadı.';
    END IF;

    SELECT net.http_post(
        url := 'https://zhjdbpokoyitvwlkncdd.supabase.co/functions/v1/fetch-economy-news',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'x-cron-secret', _secret
        ),
        body := '{}'::jsonb,
        timeout_milliseconds := 20000
    ) INTO _request_id;

    RETURN _request_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_news_fetch_result(p_request_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _status INTEGER;
    _content TEXT;
    _timed_out BOOLEAN;
    _error TEXT;
    _body JSONB;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT r.status_code, r.content, r.timed_out, r.error_msg
    INTO _status, _content, _timed_out, _error
    FROM net._http_response AS r
    WHERE r.id = p_request_id;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('done', false);
    END IF;

    BEGIN
        _body := _content::jsonb;
    EXCEPTION WHEN OTHERS THEN
        _body := NULL;
    END;

    RETURN jsonb_build_object(
        'done', true,
        'ok', coalesce(_status BETWEEN 200 AND 299, false),
        'status', _status,
        'body', _body,
        'error', CASE WHEN coalesce(_timed_out, false) THEN 'Haber servisi zamanında cevap vermedi.' ELSE _error END
    );
END;
$$;

REVOKE ALL ON FUNCTION public.trim_news_feed() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_fetch_real_news() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_news_fetch_result(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_fetch_real_news() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_news_fetch_result(BIGINT) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT
    (SELECT count(*) FROM public.news_feed) AS haber_sayisi,
    EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'borsa_news_cron_secret') AS gizli_anahtar_var,
    EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'borsa-fetch-economy-news' AND active) AS otomatik_cekme_acik;
