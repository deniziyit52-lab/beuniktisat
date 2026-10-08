-- Gercek haberlerde kaynak adi ve haberin tamaminin adresi saklanir.
ALTER TABLE public.news_feed ADD COLUMN IF NOT EXISTS url TEXT;
ALTER TABLE public.news_feed ADD COLUMN IF NOT EXISTS source TEXT;

NOTIFY pgrst, 'reload schema';

SELECT column_name AS sutun
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'news_feed'
ORDER BY ordinal_position;
