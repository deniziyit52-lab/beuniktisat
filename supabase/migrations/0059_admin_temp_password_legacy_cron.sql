-- 1) Sifresini unutan uyeye yonetici panelinden gecici sifre verilebilir.
-- 2) Her gece acilis fiyatini bozan, depoda olmayan eski zamanlanmis gorevler kapatilir.
--
-- 0058'in teshisi sucluyu gosterdi: "piyasayi-kapat-gece-12" adli eski gorev her gece 21:00 UTC'de
-- (Turkiye 24:00) acilis fiyatini kullanilmayan "price" sutunuyla eziyordu. Eslenigi olan
-- "piyasayi-ac-sabah-9" ile birlikte kapatilir. Gorevler silinmez, yalnizca durdurulur; geri acilabilir.
-- Piyasayi asil acip kapatan gorevler (borsa-market-open / borsa-market-close) yerinde ve calisir
-- durumda degilse hicbir sey kapatilmaz.

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Yonetici, e-postasi verilen uyeye yeni sifre belirler. Sifre veritabaninda yalnizca geri cozulemeyen
-- ozet olarak durur. Uyenin acik oturumlari kapatilir. Yonetici hesaplarina uygulanamaz.
CREATE OR REPLACE FUNCTION public.admin_set_user_password(p_user_email TEXT, p_new_password TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions, pg_temp
AS $$
DECLARE
    _email TEXT := lower(trim(coalesce(p_user_email, '')));
    _target_user_id UUID;
    _matches INTEGER;
    _name TEXT;
    _sessions_closed BOOLEAN := false;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    IF _email = '' THEN
        RAISE EXCEPTION 'Üyenin e-posta adresi gerekli.';
    END IF;
    IF p_new_password IS NULL
       OR char_length(p_new_password) < 6
       OR octet_length(p_new_password) > 72 THEN
        RAISE EXCEPTION 'Şifre en az 6, en fazla 72 karakter olmalı.';
    END IF;

    SELECT count(*) INTO _matches
    FROM auth.users
    WHERE lower(email) = _email;

    IF _matches = 0 THEN
        RAISE EXCEPTION 'Bu e-posta ile kayıtlı üye bulunamadı.';
    ELSIF _matches > 1 THEN
        RAISE EXCEPTION 'Bu e-posta birden fazla hesaba ait; şifre değiştirilmedi.';
    END IF;

    SELECT id INTO _target_user_id
    FROM auth.users
    WHERE lower(email) = _email
    FOR UPDATE;

    IF EXISTS (SELECT 1 FROM public.admins WHERE user_id = _target_user_id) THEN
        RAISE EXCEPTION 'Yönetici hesaplarının şifresi buradan değiştirilemez.';
    END IF;

    UPDATE auth.users
    SET encrypted_password = crypt(p_new_password, gen_salt('bf', 10)),
        updated_at = now()
    WHERE id = _target_user_id;

    -- Eski sifreyle acilmis oturumlar kapatilir (ornegin ortak bilgisayarda acik kalmis bir oturum).
    -- Bu adim basarisiz olsa da sifre degisikligi gecerlidir.
    BEGIN
        DELETE FROM auth.sessions WHERE user_id = _target_user_id;
        _sessions_closed := true;
    EXCEPTION WHEN OTHERS THEN
        _sessions_closed := false;
    END;

    SELECT display_name INTO _name FROM public.users WHERE id = _target_user_id;

    RETURN jsonb_build_object(
        'email', _email,
        'name', coalesce(_name, ''),
        'changed', true,
        'sessions_closed', _sessions_closed
    );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_user_password(TEXT, TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_user_password(TEXT, TEXT) TO authenticated;

-- Eski zamanlanmis gorevler durdurulur. Buradaki bir hata, yukaridaki fonksiyonu geri almaz.
DO $$
DECLARE
    _ok_open  BOOLEAN := false;
    _ok_close BOOLEAN := false;
    _job      RECORD;
    _stopped  TEXT[] := '{}';
    _skipped  TEXT[] := '{}';
    _words    JSONB := '{}'::jsonb;
    _jobs     TEXT;
    _result   TEXT;
BEGIN
    BEGIN
        SELECT EXISTS (SELECT 1 FROM cron.job AS j
                       WHERE j.jobname::TEXT = 'borsa-market-open' AND j.active
                         AND j.command ~* 'apply_market_open\s*\(\s*true'),
               EXISTS (SELECT 1 FROM cron.job AS j
                       WHERE j.jobname::TEXT = 'borsa-market-close' AND j.active
                         AND j.command ~* 'apply_market_open\s*\(\s*false')
        INTO _ok_open, _ok_close;

        FOR _job IN
            SELECT j.jobid, j.jobname::TEXT AS jobname, j.command, j.active
            FROM cron.job AS j
            WHERE j.jobname::TEXT IN ('piyasayi-kapat-gece-12', 'piyasayi-ac-sabah-9')
            ORDER BY j.jobid
        LOOP
            -- Komutun kendisi yerine yalnizca icinde gecen bilinen sozcukler kaydedilir.
            _words := _words || jsonb_build_object(_job.jobname, (
                SELECT coalesce(string_agg(v.word, ',' ORDER BY v.ord), '')
                FROM unnest(ARRAY['previous_close', 'price', 'current_price', 'change', 'change_pct', 'stocks',
                                  'market_settings', 'is_market_open', 'app_settings', 'market_open',
                                  'apply_market_open', 'set_market_open', 'users', 'balance',
                                  'update', 'insert', 'delete', 'select', 'http_post'])
                     WITH ORDINALITY AS v(word, ord)
                WHERE _job.command ~* ('\m' || v.word || '\M')
            ));

            IF NOT (_ok_open AND _ok_close) THEN
                _skipped := array_append(_skipped, _job.jobname);
            ELSE
                IF _job.active THEN
                    PERFORM cron.alter_job(_job.jobid, active := false);
                END IF;
                _stopped := array_append(_stopped, _job.jobname);
            END IF;
        END LOOP;

        SELECT string_agg(
                   coalesce(j.jobname::TEXT, 'adsiz#' || j.jobid) || ' [' || j.schedule || ']'
                   || CASE WHEN j.active THEN '' ELSE ' (kapali)' END,
                   '; ' ORDER BY j.jobid)
        INTO _jobs
        FROM cron.job AS j;

        _result := CASE
            WHEN cardinality(_skipped) > 0 THEN
                'KAPATILMADI: asil acma/kapama gorevleri dogrulanamadi (' || array_to_string(_skipped, ', ') || ')'
            WHEN cardinality(_stopped) > 0 THEN
                cardinality(_stopped) || ' eski gorev durduruldu: ' || array_to_string(_stopped, ', ')
            ELSE 'eski gorev bulunamadi'
        END;

        INSERT INTO public.engine_diagnostics (topic, summary)
        VALUES ('legacy_cron', jsonb_build_object(
            'sonuc', _result,
            'asil_acma_gorevi_calisiyor', _ok_open,
            'asil_kapama_gorevi_calisiyor', _ok_close,
            'eski_gorev_sozcukleri', _words,
            'gorevler', _jobs
        ));
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO public.engine_diagnostics (topic, summary)
        VALUES ('legacy_cron', jsonb_build_object('sonuc', 'HATA: ' || left(SQLERRM, 300)));
    END;
END
$$;

NOTIFY pgrst, 'reload schema';

-- Sonuc
SELECT r.konu, r.sonuc
FROM (
    SELECT 1 AS sira,
           'Gecici sifre' AS konu,
           CASE WHEN to_regprocedure('public.admin_set_user_password(text, text)') IS NOT NULL
                THEN 'kuruldu' ELSE 'KURULAMADI' END AS sonuc
    UNION ALL
    SELECT 2, 'Eski gorevler',
           (SELECT d.summary ->> 'sonuc' FROM public.engine_diagnostics AS d
            WHERE d.topic = 'legacy_cron' ORDER BY d.id DESC LIMIT 1)
    UNION ALL
    SELECT 3, 'Acilis fiyatlari',
           (SELECT count(*) FILTER (WHERE abs(previous_close - (current_price - change)) <= 0.01)::TEXT
                   || ' / ' || count(*)::TEXT || ' hissede dogru'
            FROM public.stocks)
) AS r
ORDER BY r.sira;
