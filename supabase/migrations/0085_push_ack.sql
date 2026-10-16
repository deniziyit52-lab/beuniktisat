-- Bildirim gercekten cihaza ulasti mi? Cihaz bildirimi gosterince (sw.js) push_ack ile "aldim" der.
-- Neden: Google hizmeti olmayan Huawei gibi cihazlarda bildirim servisi bildirimi kabul eder ama cihaza
-- ulastiramaz; gonderici bunu goremez. Bu cihazlar tarayicida kendini masaustu gibi de tanitabildigi icin
-- marka tahmini yerine teslim olcülür.
-- push_ack herkese aciktir (anon): yalnizca bilinen bir cihaz adresine "son teslim" zamani yazar, baska bir sey yapmaz.

ALTER TABLE public.push_subscriptions ADD COLUMN IF NOT EXISTS last_ack_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.push_ack(p_endpoint TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF coalesce(p_endpoint, '') = '' OR length(p_endpoint) > 1000 THEN
        RETURN false;
    END IF;
    UPDATE public.push_subscriptions SET last_ack_at = now() WHERE endpoint = p_endpoint;
    RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION public.push_ack(TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.push_ack(TEXT) TO anon, authenticated;

-- Oyuncunun kendi cihazi icin son teslim zamani (bildirimleri acinca deneme bildirimi ulasti mi).
CREATE OR REPLACE FUNCTION public.push_ack_status(p_endpoint TEXT)
RETURNS TIMESTAMPTZ
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT last_ack_at FROM public.push_subscriptions WHERE endpoint = p_endpoint AND user_id = auth.uid();
$$;
REVOKE ALL ON FUNCTION public.push_ack_status(TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.push_ack_status(TEXT) TO authenticated;

-- Yonetici: kac cihaz bildirimi gercekten aliyor (son 30 gunde en az bir kez teslim).
CREATE OR REPLACE FUNCTION public.admin_push_stats()
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
    RETURN jsonb_build_object(
        'players', (SELECT count(DISTINCT user_id) FROM public.push_subscriptions),
        'devices', (SELECT count(*) FROM public.push_subscriptions),
        'acked', (SELECT count(*) FROM public.push_subscriptions WHERE last_ack_at > now() - INTERVAL '30 days')
    );
END;
$$;
REVOKE ALL ON FUNCTION public.admin_push_stats() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_push_stats() TO authenticated;

NOTIFY pgrst, 'reload schema';
