-- Devre kesici artik tek hamlede esik kadar oynayan fiyatta da devreye girer.
-- Onceden yalnizca referans fiyata gore bakiliyordu; referans biraz eskiyse
-- tek islemde %10 dusen hisse referansa gore %9,3 gorunup devre kesiciye takilmiyordu.

CREATE OR REPLACE FUNCTION public.apply_circuit_breaker()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _pct NUMERIC;
    _minutes INTEGER;
BEGIN
    IF NEW.current_price IS NOT DISTINCT FROM OLD.current_price THEN
        RETURN NEW;
    END IF;
    IF NEW.breaker_ref IS NULL OR NEW.breaker_ref <= 0 THEN
        NEW.breaker_ref := OLD.current_price;
    END IF;

    SELECT breaker_pct, breaker_minutes INTO _pct, _minutes
    FROM public.engine_settings WHERE id = 1;
    _pct := coalesce(_pct, 0.10);

    -- Iki kosuldan biri yeter: referansa gore toplam hareket ya da tek hamledeki hareket.
    -- 0.0005 payi, fiyat yuvarlamasi yuzunden esigin kil payi kacirilmasini onler.
    IF (NEW.breaker_ref > 0 AND abs(NEW.current_price / NEW.breaker_ref - 1) >= _pct)
       OR (OLD.current_price > 0 AND abs(NEW.current_price / OLD.current_price - 1) >= _pct - 0.0005) THEN
        NEW.halt_until := now() + make_interval(mins => coalesce(_minutes, 5));
        NEW.breaker_ref := NEW.current_price;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_circuit_breaker() FROM PUBLIC, anon, authenticated;

SELECT symbol, current_price, breaker_ref, halt_until
FROM public.stocks
ORDER BY symbol;
