-- Bakim modu, istenirse belirlenen saatte kendiliginden kapanir.
-- (0049 calistirilmadiysa gereken sutunlar burada da eklenir.)

ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS maintenance_message TEXT;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS maintenance_until TIMESTAMPTZ;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS maintenance_auto_off BOOLEAN NOT NULL DEFAULT false;

DROP FUNCTION IF EXISTS public.admin_set_maintenance_info(TEXT, TIMESTAMPTZ);

-- Notu, saati ve "bu saatte kendiliginden kapat" secimini kaydeder. Bakim modunu acip kapatmaz.
CREATE OR REPLACE FUNCTION public.admin_set_maintenance_info(
    p_message TEXT,
    p_until TIMESTAMPTZ,
    p_auto_off BOOLEAN DEFAULT false
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF coalesce(p_auto_off, false) AND p_until IS NULL THEN
        RAISE EXCEPTION 'Kendiliğinden kapanma için bir saat seçmelisin.';
    END IF;

    INSERT INTO public.app_settings
        (id, maintenance_mode, maintenance_message, maintenance_until, maintenance_auto_off, updated_at)
    VALUES (
        1,
        false,
        nullif(left(trim(coalesce(p_message, '')), 400), ''),
        p_until,
        coalesce(p_auto_off, false),
        now()
    )
    ON CONFLICT (id) DO UPDATE
    SET maintenance_message = EXCLUDED.maintenance_message,
        maintenance_until = EXCLUDED.maintenance_until,
        maintenance_auto_off = EXCLUDED.maintenance_auto_off,
        updated_at = EXCLUDED.updated_at;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_maintenance_info(TEXT, TIMESTAMPTZ, BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_maintenance_info(TEXT, TIMESTAMPTZ, BOOLEAN) TO authenticated;

-- Dakikada bir: saati gelmis ve "kendiliginden kapat" secili bakim modu kapatilir.
-- Kapatilacak bir sey yoksa satira dokunulmaz (bos yere canli mesaj gitmez).
CREATE OR REPLACE FUNCTION public.maintenance_auto_off()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    UPDATE public.app_settings
    SET maintenance_mode = false,
        maintenance_auto_off = false,
        updated_at = now()
    WHERE id = 1
      AND maintenance_mode
      AND maintenance_auto_off
      AND maintenance_until IS NOT NULL
      AND maintenance_until <= now();
    RETURN FOUND;
END;
$$;

REVOKE ALL ON FUNCTION public.maintenance_auto_off() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'borsa-maintenance-auto-off';

SELECT cron.schedule(
    'borsa-maintenance-auto-off',
    '* * * * *',
    $$ SELECT public.maintenance_auto_off(); $$
);

NOTIFY pgrst, 'reload schema';

SELECT maintenance_mode AS bakim_acik,
       maintenance_until AS saat,
       maintenance_auto_off AS kendiliginden_kapanir
FROM public.app_settings
WHERE id = 1;
