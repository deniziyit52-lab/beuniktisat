-- Site market_snapshot'a gectikten sonra calistirilir: hisse basina giden realtime mesajlari kapatilir.
-- price_history'yi siteden dinleyen yok; o da yayindan cikarilir.
DO $$
DECLARE
    _t TEXT;
BEGIN
    FOREACH _t IN ARRAY ARRAY['stocks', 'price_history'] LOOP
        IF EXISTS (
            SELECT 1 FROM pg_publication_tables
            WHERE pubname = 'supabase_realtime'
              AND schemaname = 'public'
              AND tablename = _t
        ) THEN
            EXECUTE format('ALTER PUBLICATION supabase_realtime DROP TABLE public.%I', _t);
        END IF;
    END LOOP;
END
$$;

SELECT tablename AS canli_yayindaki_tablolar
FROM pg_publication_tables
WHERE pubname = 'supabase_realtime' AND schemaname = 'public'
ORDER BY tablename;
