ALTER TABLE public.news_feed REPLICA IDENTITY FULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_publication_tables
        WHERE pubname = 'supabase_realtime'
          AND schemaname = 'public'
          AND tablename = 'news_feed'
    ) THEN
        ALTER PUBLICATION supabase_realtime ADD TABLE public.news_feed;
    END IF;
END
$$;

NOTIFY pgrst, 'reload schema';
