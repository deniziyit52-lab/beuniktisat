-- Bakim sayfasi icin: yoneticinin yazdigi not ve tahmini acilis saati.

ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS maintenance_message TEXT;
ALTER TABLE public.app_settings ADD COLUMN IF NOT EXISTS maintenance_until TIMESTAMPTZ;

-- Notu ve tahmini acilis saatini kaydeder (ikisi de bos birakilabilir). Bakim modunu acip kapatmaz.
CREATE OR REPLACE FUNCTION public.admin_set_maintenance_info(
    p_message TEXT,
    p_until TIMESTAMPTZ
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

    INSERT INTO public.app_settings (id, maintenance_mode, maintenance_message, maintenance_until, updated_at)
    VALUES (
        1,
        false,
        nullif(left(trim(coalesce(p_message, '')), 400), ''),
        p_until,
        now()
    )
    ON CONFLICT (id) DO UPDATE
    SET maintenance_message = EXCLUDED.maintenance_message,
        maintenance_until = EXCLUDED.maintenance_until,
        updated_at = EXCLUDED.updated_at;

    RETURN true;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_maintenance_info(TEXT, TIMESTAMPTZ) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_maintenance_info(TEXT, TIMESTAMPTZ) TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT maintenance_mode AS bakim_acik, maintenance_message AS not_metni, maintenance_until AS tahmini_acilis
FROM public.app_settings
WHERE id = 1;
