-- Gunun acilis fiyati (previous_close) kapanis sirasinda bozulmus: hisselerin eski, kullanilmayan
-- "price" sutunundaki degerler acilis fiyatinin yerine yazilmis. Bu dosya:
--   1) Acilis fiyatini, hala dogru duran "change" (gunluk fark) sutunundan geri kurar.
--   2) Bozulmaya neyin yol actigini bulmak icin hisse tablosuna bagli butun otomatik kurallari,
--      zamanlanmis gorevleri ve acilis fiyatina dokunan fonksiyonlari listeler.

UPDATE public.stocks
SET previous_close = ROUND(current_price - change, 4)
WHERE current_price - change > 0
  AND abs(previous_close - (current_price - change)) > 0.01;

SELECT 'tetikleyici' AS tur,
       c.relname || ' / ' || t.tgname AS ad,
       pg_get_triggerdef(t.oid) AS ayrinti
FROM pg_trigger AS t
JOIN pg_class AS c ON c.oid = t.tgrelid
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND n.nspname = 'public'
  AND c.relname IN ('stocks', 'market_settings', 'app_settings', 'price_history')
UNION ALL
SELECT 'zamanlanmis gorev', j.jobname || ' (' || j.schedule || ')', j.command
FROM cron.job AS j
UNION ALL
SELECT 'fonksiyon', p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')',
       CASE WHEN p.prosrc ~* 'previous_close\s*=\s*(s\.)?price\M' THEN 'ACILIS FIYATINA ESKI price SUTUNUNU YAZIYOR'
            ELSE 'previous_close degerini degistiriyor' END
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prosrc ~* 'set[^;]*previous_close\s*='
ORDER BY 1, 2;
