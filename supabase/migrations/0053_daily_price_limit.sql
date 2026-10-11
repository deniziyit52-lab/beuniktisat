-- Gunluk tavan / taban: bir hisse, gunun acilis fiyatina (onceki kapanis) gore
-- belirlenen yuzdeden fazla yukselemez ya da dusemez. Varsayilan %20, yonetici panelinden degisir.
-- Kural, fiyati kim degistirirse degistirsin (motor, alim-satim, haber, yonetici) ayni yerde uygulanir.

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS daily_limit_pct NUMERIC NOT NULL DEFAULT 0.20
        CHECK (daily_limit_pct > 0 AND daily_limit_pct <= 1);

CREATE OR REPLACE FUNCTION public.apply_circuit_breaker()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _pct NUMERIC;
    _minutes INTEGER;
    _limit NUMERIC;
    _hi NUMERIC;
    _lo NUMERIC;
BEGIN
    IF NEW.current_price IS NOT DISTINCT FROM OLD.current_price THEN
        RETURN NEW;
    END IF;

    SELECT breaker_pct, breaker_minutes, daily_limit_pct INTO _pct, _minutes, _limit
    FROM public.engine_settings WHERE id = 1;
    _pct := coalesce(_pct, 0.10);
    _limit := coalesce(_limit, 0.20);

    -- Gunluk tavan / taban. Hisse kural konmadan once sinirin disina ciktiysa oldugu yerde kalabilir,
    -- ama sinirdan daha da uzaklasamaz; sinira dogru serbestce doner.
    IF NEW.previous_close > 0 AND NEW.previous_close = OLD.previous_close THEN
        _hi := GREATEST(ROUND(NEW.previous_close * (1 + _limit), 4), OLD.current_price);
        _lo := LEAST(ROUND(NEW.previous_close * (1 - _limit), 4), OLD.current_price);
        IF NEW.current_price > _hi OR NEW.current_price < _lo THEN
            NEW.current_price := LEAST(GREATEST(NEW.current_price, _lo), _hi);
            NEW.change := ROUND(NEW.current_price - NEW.previous_close, 4);
            NEW.change_pct := ROUND((NEW.current_price - NEW.previous_close) / NEW.previous_close * 100, 4);
            IF NEW.current_price = OLD.current_price THEN
                RETURN NEW;
            END IF;
        END IF;
    END IF;

    IF NEW.breaker_ref IS NULL OR NEW.breaker_ref <= 0 THEN
        NEW.breaker_ref := OLD.current_price;
    END IF;

    -- Devre kesici: referansa gore toplam hareket ya da tek hamledeki hareket esigi gecerse.
    IF (NEW.breaker_ref > 0 AND abs(NEW.current_price / NEW.breaker_ref - 1) >= _pct)
       OR (OLD.current_price > 0 AND abs(NEW.current_price / OLD.current_price - 1) >= _pct - 0.0005) THEN
        NEW.halt_until := now() + make_interval(mins => coalesce(_minutes, 5));
        NEW.breaker_ref := NEW.current_price;
    END IF;

    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.apply_circuit_breaker() FROM PUBLIC, anon, authenticated;

-- Grafik gecmisine yazilan yeni fiyat da ayni sinirin icinde kalir
-- (alim-satim, haber ve elle fiyat belirleme, gecmise sinirlanmamis fiyati yazmaya calisabilir).
CREATE OR REPLACE FUNCTION public.clamp_price_history()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _limit NUMERIC;
    _prev NUMERIC;
    _cur NUMERIC;
BEGIN
    -- Yalnizca su ana ait kayitlar; gecmise donuk toplu yazimlara dokunulmaz.
    IF NEW.recorded_at < now() - INTERVAL '5 seconds' THEN
        RETURN NEW;
    END IF;

    SELECT previous_close, current_price INTO _prev, _cur
    FROM public.stocks WHERE symbol = NEW.symbol;
    IF NOT FOUND OR coalesce(_prev, 0) <= 0 THEN
        RETURN NEW;
    END IF;

    SELECT coalesce(daily_limit_pct, 0.20) INTO _limit FROM public.engine_settings WHERE id = 1;
    _limit := coalesce(_limit, 0.20);

    NEW.price := LEAST(
        GREATEST(NEW.price, LEAST(ROUND(_prev * (1 - _limit), 4), _cur)),
        GREATEST(ROUND(_prev * (1 + _limit), 4), _cur)
    );
    RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.clamp_price_history() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_price_history_clamp ON public.price_history;
CREATE TRIGGER trg_price_history_clamp
    BEFORE INSERT ON public.price_history
    FOR EACH ROW
    EXECUTE FUNCTION public.clamp_price_history();

-- Oyuncu sayfasinin bilmesi gereken kurallar: tek hisse siniri ve gunluk tavan / taban.
CREATE OR REPLACE FUNCTION public.get_game_rules()
RETURNS JSONB
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT jsonb_build_object(
        'max_position_pct', max_position_pct,
        'daily_limit_pct', daily_limit_pct
    )
    FROM public.engine_settings
    WHERE id = 1;
$$;

REVOKE ALL ON FUNCTION public.get_game_rules() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_game_rules() TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.admin_set_daily_limit(p_limit NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF p_limit IS NULL OR p_limit < 0.05 OR p_limit > 1 THEN
        RAISE EXCEPTION 'Günlük tavan/taban %%5 ile %%100 arasında olmalı.';
    END IF;

    UPDATE public.engine_settings SET daily_limit_pct = p_limit WHERE id = 1;
    RETURN p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_daily_limit(NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_daily_limit(NUMERIC) TO authenticated;

NOTIFY pgrst, 'reload schema';

-- Her hissenin bugunku tavan ve taban fiyati; "sinir_disinda" true ise hisse kural konmadan once sinirı asmis demektir.
SELECT s.symbol,
       s.previous_close AS acilis,
       s.current_price AS simdi,
       ROUND(s.previous_close * (1 - e.daily_limit_pct), 2) AS taban,
       ROUND(s.previous_close * (1 + e.daily_limit_pct), 2) AS tavan,
       abs(s.current_price / s.previous_close - 1) > e.daily_limit_pct AS sinir_disinda
FROM public.stocks AS s
CROSS JOIN public.engine_settings AS e
WHERE e.id = 1
ORDER BY s.symbol;
