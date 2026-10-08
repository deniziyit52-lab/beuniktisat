-- Kose yazilari: hocalarin kendi adiyla yazdigi piyasa yorumlari.
-- Yaziyi admin girer. Istenirse bir hisse ve yon (yukselir / duser) tahmini eklenir;
-- sure dolunca tahminin tutup tutmadigi kendiliginden isaretlenir.

CREATE TABLE IF NOT EXISTS public.guest_columns (
    id           BIGSERIAL PRIMARY KEY,
    author_name  TEXT NOT NULL,
    author_title TEXT,
    title        TEXT NOT NULL,
    body         TEXT NOT NULL,
    stock_symbol VARCHAR(16) REFERENCES public.stocks(symbol) ON UPDATE CASCADE ON DELETE SET NULL,
    direction    TEXT CHECK (direction IN ('UP', 'DOWN')),
    start_price  NUMERIC(18,4),
    target_at    TIMESTAMPTZ,
    end_price    NUMERIC(18,4),
    result       TEXT CHECK (result IN ('HIT', 'MISS')),
    resolved_at  TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.guest_columns ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "guest_columns herkes okur" ON public.guest_columns;
CREATE POLICY "guest_columns herkes okur"
    ON public.guest_columns FOR SELECT USING (true);

REVOKE ALL ON public.guest_columns FROM anon, authenticated;
GRANT SELECT ON public.guest_columns TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_publish_column(
    p_author_name TEXT,
    p_author_title TEXT,
    p_title TEXT,
    p_body TEXT,
    p_symbol TEXT DEFAULT NULL,
    p_direction TEXT DEFAULT NULL,
    p_days INTEGER DEFAULT 7
)
RETURNS public.guest_columns
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _author TEXT := trim(coalesce(p_author_name, ''));
    _title TEXT := trim(coalesce(p_title, ''));
    _body TEXT := trim(coalesce(p_body, ''));
    _symbol VARCHAR(16) := nullif(upper(trim(coalesce(p_symbol, ''))), '');
    _direction TEXT := nullif(upper(trim(coalesce(p_direction, ''))), '');
    _price NUMERIC;
    _row public.guest_columns;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF _author = '' THEN
        RAISE EXCEPTION 'Yazarın adı boş olamaz.';
    END IF;
    IF _title = '' THEN
        RAISE EXCEPTION 'Yazının başlığı boş olamaz.';
    END IF;
    IF length(_body) < 20 THEN
        RAISE EXCEPTION 'Yazı metni çok kısa.';
    END IF;

    -- Tahmin istege bagli: hisse secildiyse yon de secilmeli.
    IF _symbol IS NOT NULL THEN
        IF _direction IS NULL OR _direction NOT IN ('UP', 'DOWN') THEN
            RAISE EXCEPTION 'Tahmin için yön seçilmeli (yükselir ya da düşer).';
        END IF;
        IF p_days IS NULL OR p_days < 1 OR p_days > 30 THEN
            RAISE EXCEPTION 'Tahmin süresi 1 ile 30 gün arasında olmalı.';
        END IF;
        SELECT current_price INTO _price FROM public.stocks WHERE symbol = _symbol;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Hisse bulunamadi: %', _symbol;
        END IF;
    ELSE
        _direction := NULL;
    END IF;

    INSERT INTO public.guest_columns
        (author_name, author_title, title, body, stock_symbol, direction, start_price, target_at)
    VALUES (
        left(_author, 80),
        nullif(left(trim(coalesce(p_author_title, '')), 120), ''),
        left(_title, 160),
        left(_body, 6000),
        _symbol,
        _direction,
        _price,
        CASE WHEN _symbol IS NOT NULL THEN now() + make_interval(days => p_days) END
    )
    RETURNING * INTO _row;

    RETURN _row;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_column(p_id BIGINT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    DELETE FROM public.guest_columns WHERE id = p_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Yazı bulunamadı.';
    END IF;
    RETURN true;
END;
$$;

-- Suresi dolan tahminleri sonuclandirir: fiyat tahmin yonunde hareket ettiyse tuttu sayilir.
CREATE OR REPLACE FUNCTION public.resolve_guest_columns()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _count INTEGER;
BEGIN
    UPDATE public.guest_columns AS c
    SET end_price = s.current_price,
        result = CASE
            WHEN c.direction = 'UP' AND s.current_price > c.start_price THEN 'HIT'
            WHEN c.direction = 'DOWN' AND s.current_price < c.start_price THEN 'HIT'
            ELSE 'MISS'
        END,
        resolved_at = now()
    FROM public.stocks AS s
    WHERE s.symbol = c.stock_symbol
      AND c.result IS NULL
      AND c.direction IS NOT NULL
      AND c.target_at IS NOT NULL
      AND c.target_at <= now();
    GET DIAGNOSTICS _count = ROW_COUNT;
    RETURN _count;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_publish_column(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_delete_column(BIGINT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.resolve_guest_columns() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_publish_column(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_column(BIGINT) TO authenticated;

SELECT cron.unschedule(jobid)
FROM cron.job
WHERE jobname = 'borsa-resolve-columns';

-- Saatte bir (5. dakikada) suresi dolan tahminlere bakilir.
SELECT cron.schedule(
    'borsa-resolve-columns',
    '5 * * * *',
    $$ SELECT public.resolve_guest_columns(); $$
);

NOTIFY pgrst, 'reload schema';

SELECT jobname AS zamanlanmis_gorev, schedule AS utc_zamani
FROM cron.job
WHERE jobname LIKE 'borsa-%'
ORDER BY jobname;
