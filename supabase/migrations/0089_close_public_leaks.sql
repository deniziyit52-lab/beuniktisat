-- Supabase guvenlik taramasi (21.10.2026) sonrasi kapatilanlar:
-- 1) get_random_users(n): depoda olmayan eski fisilti fonksiyonu; giris yapmamis biri bile cagirip oyuncularin
--    ad ve e-postalarini alabiliyordu. Sitede kullanilmiyor (fetchRandomUsers hic cagrilmiyor); erisim kapatilir.
-- 2) get_engine_diagnosis(): 17.10.2026'dan beri bos doner (0058 teshisi); erisim kapatilir.
-- 3) handle_auth_user_on_signup(): kayit tetikleyicisi; dogrudan cagrilmasi gerekmez. Tetikleyici calismaya devam eder
--    (tetikleyicide fonksiyon yetkisi aranmaz).

REVOKE ALL ON FUNCTION public.get_random_users(INTEGER) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_engine_diagnosis() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.handle_auth_user_on_signup() FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';

SELECT p.proname AS fonksiyon,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS girissiz_cagirabilir,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS oyuncu_cagirabilir
FROM pg_proc AS p JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('get_random_users', 'get_engine_diagnosis', 'handle_auth_user_on_signup');
