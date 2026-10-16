-- Sistem sagligi uyarisinin denemesi: yonetici panelindeki "Deneme uyarısı gönder" dugmesi.
-- Uyari durumuna (health_alert_state) dokunmaz; health-alert fonksiyonu { "test": true } ile ornek bir
-- "sorun var" e-postasini yalnizca yoneticilere gonderir. Sonuc admin_digest_test_result ile okunur.

-- Yoneticilerin e-posta adresleri (Edge Function cagirir).
CREATE OR REPLACE FUNCTION public.health_alert_recipients()
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT coalesce(jsonb_agg(DISTINCT au.email), '[]'::jsonb)
    FROM public.admins AS a
    JOIN auth.users AS au ON au.id = a.user_id
    WHERE coalesce(au.email, '') <> '';
$$;
REVOKE ALL ON FUNCTION public.health_alert_recipients() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.health_alert_recipients() TO service_role;

CREATE OR REPLACE FUNCTION public.admin_send_health_test()
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _secret TEXT;
    _request_id BIGINT;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    SELECT decrypted_secret INTO _secret FROM vault.decrypted_secrets WHERE name = 'borsa_news_cron_secret';
    IF _secret IS NULL THEN
        RAISE EXCEPTION 'Gizli anahtar (borsa_news_cron_secret) veritabanında bulunamadı.';
    END IF;
    -- Authorization'daki anahtar sitedeki herkese acik anon anahtardir; asil yetki x-cron-secret ile kontrol edilir.
    SELECT net.http_post(
        url := 'https://zhjdbpokoyitvwlkncdd.supabase.co/functions/v1/health-alert',
        headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpoamRicG9rb3lpdHZ3bGtuY2RkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExODYyMzEsImV4cCI6MjEwNjc2MjIzMX0.Za4vf8mDR2xOKxXSKAipO0_-21Yk_vHiVUm5nlH1ZnY',
            'x-cron-secret', _secret
        ),
        body := jsonb_build_object('test', true),
        timeout_milliseconds := 30000
    ) INTO _request_id;
    RETURN _request_id;
END;
$$;
REVOKE ALL ON FUNCTION public.admin_send_health_test() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_send_health_test() TO authenticated;

NOTIFY pgrst, 'reload schema';
