-- Eski hesaplasma fonksiyonlari (execute_trade, butun surumleri) disaridan dogrudan cagrilamaz.
-- Fiyati cagiran belirledigi icin bunlara yalnizca execute_hybrid_trade (sunucu icinden) ulasmalidir.
-- 0016 bu izni kaldirmisti; sonradan eklenmis bir surum kalmis olabilir diye yeniden uygulanir.
-- Hicbir davranisi degistirmez: alim-satim execute_hybrid_trade uzerinden eskisi gibi calisir.

DO $$
DECLARE
    _fn REGPROCEDURE;
BEGIN
    FOR _fn IN
        SELECT p.oid::regprocedure
        FROM pg_proc AS p
        JOIN pg_namespace AS n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'execute_trade'
    LOOP
        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', _fn);
    END LOOP;
END
$$;

NOTIFY pgrst, 'reload schema';

-- Sonuc: her surum icin "oyuncu_cagirabilir" false olmali.
SELECT p.oid::regprocedure::text AS fonksiyon,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') AS oyuncu_cagirabilir,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS girissiz_cagirabilir
FROM pg_proc AS p
JOIN pg_namespace AS n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'execute_trade';
