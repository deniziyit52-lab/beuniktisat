-- Grafikler icin yapay ama gercekci fiyat gecmisi uretir (tek seferlik; istenirse tekrar calistirilabilir).
-- Hisselerin SIMDIKI fiyati, onceki kapanisi ve gunluk yuzdesi DEGISMEZ; yalnizca grafik gecmisi yeniden yazilir.
--   * Bugunku seans: onceki kapanistan simdiki fiyata dogru dalgali bir yol (dakikalik).
--   * Dunku seans: onceki kapanisa baglanan dakikalik dalgalanma.
--   * Ondan onceki 29 gun: saatlik dalgalanma.
-- Dalgalanma buyuklugu hissenin turune gore (guvenli az, riskli cok), oyundaki gercek oynakligin %60'i.
-- Piyasanin kapali oldugu saatler (24:00-09:00) icin nokta uretilmez.

BEGIN;

DELETE FROM public.price_history WHERE true;
DELETE FROM public.price_history_hourly WHERE true;

-- 1) Bugunku seans: previous_close -> current_price (uclari sabit, arasi dalgali).
WITH bounds AS (
    SELECT (
        (date_trunc('day', now() AT TIME ZONE 'Europe/Istanbul')
         - CASE WHEN (now() AT TIME ZONE 'Europe/Istanbul')::time >= TIME '09:00'
                THEN INTERVAL '0 days' ELSE INTERVAL '1 day' END
         + INTERVAL '9 hours') AT TIME ZONE 'Europe/Istanbul'
    ) AS s_start
),
session AS (
    SELECT s_start,
           LEAST(date_trunc('minute', now()), s_start + INTERVAL '15 hours') AS s_end
    FROM bounds
),
steps AS MATERIALIZED (
    SELECT s.symbol,
           s.previous_close AS p0,
           s.current_price AS p1,
           0.6 * t.daily_sigma / sqrt(900.0) AS sig,
           g.ts,
           sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random()) AS z
    FROM public.stocks AS s
    JOIN public.stock_types AS t ON t.risk_type = s.risk_type
    CROSS JOIN session
    CROSS JOIN LATERAL generate_series(session.s_start, session.s_end, INTERVAL '1 minute') AS g(ts)
),
walk AS (
    SELECT symbol, p0, p1, sig, ts,
           sum(z) OVER w - first_value(z) OVER w AS wt,
           sum(z) OVER (PARTITION BY symbol) - first_value(z) OVER w AS w_total,
           (row_number() OVER w - 1)::NUMERIC AS i,
           (count(*) OVER (PARTITION BY symbol) - 1)::NUMERIC AS n
    FROM steps
    WINDOW w AS (PARTITION BY symbol ORDER BY ts)
)
INSERT INTO public.price_history (symbol, price, recorded_at)
SELECT symbol,
       GREATEST(1, ROUND((
           p0 * exp(
               coalesce(i / NULLIF(n, 0), 1) * ln(p1 / p0)
               + sig * (wt - coalesce(i / NULLIF(n, 0), 1) * w_total)
           )
       )::NUMERIC, 4)),
       ts
FROM walk;

-- 2) Dunku seans (09:00-24:00): sonu onceki kapanisa baglanan dakikalik yol.
WITH bounds AS (
    SELECT (
        (date_trunc('day', now() AT TIME ZONE 'Europe/Istanbul')
         - CASE WHEN (now() AT TIME ZONE 'Europe/Istanbul')::time >= TIME '09:00'
                THEN INTERVAL '0 days' ELSE INTERVAL '1 day' END
         + INTERVAL '9 hours') AT TIME ZONE 'Europe/Istanbul'
    ) AS s_start
),
steps AS MATERIALIZED (
    SELECT s.symbol,
           s.previous_close AS p0,
           0.6 * t.daily_sigma / sqrt(900.0) AS sig,
           g.ts,
           sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random()) AS z
    FROM public.stocks AS s
    JOIN public.stock_types AS t ON t.risk_type = s.risk_type
    CROSS JOIN bounds
    CROSS JOIN LATERAL generate_series(
        bounds.s_start - INTERVAL '24 hours',
        bounds.s_start - INTERVAL '9 hours' - INTERVAL '1 minute',
        INTERVAL '1 minute'
    ) AS g(ts)
)
INSERT INTO public.price_history (symbol, price, recorded_at)
SELECT symbol,
       GREATEST(1, ROUND((
           p0 * exp(-sig * sum(z) OVER (PARTITION BY symbol ORDER BY ts DESC))
       )::NUMERIC, 4)),
       ts
FROM steps;

-- 3) Saatlik arsivin son iki gunu dakikalik gecmisten alinir (iki grafik birbirini tutar).
INSERT INTO public.price_history_hourly (symbol, price, recorded_at)
SELECT symbol, price, recorded_at
FROM public.price_history
WHERE extract(minute FROM recorded_at) = 0;

-- 4) Daha eski 29 gun: dunku seansin acilis fiyatina baglanan saatlik yol.
WITH anchor AS (
    SELECT DISTINCT ON (symbol) symbol, price, recorded_at
    FROM public.price_history
    ORDER BY symbol, recorded_at
),
steps AS MATERIALIZED (
    SELECT a.symbol,
           a.price AS p0,
           0.6 * t.daily_sigma / sqrt(15.0) AS sig,
           g.ts,
           sqrt(-2 * ln(1 - random())) * cos(2 * pi() * random()) AS z
    FROM anchor AS a
    JOIN public.stocks AS s ON s.symbol = a.symbol
    JOIN public.stock_types AS t ON t.risk_type = s.risk_type
    CROSS JOIN LATERAL generate_series(
        a.recorded_at - INTERVAL '29 days',
        a.recorded_at - INTERVAL '1 hour',
        INTERVAL '1 hour'
    ) AS g(ts)
    WHERE extract(hour FROM g.ts AT TIME ZONE 'Europe/Istanbul') >= 9
)
INSERT INTO public.price_history_hourly (symbol, price, recorded_at)
SELECT symbol,
       GREATEST(1, ROUND((
           p0 * exp(-sig * sum(z) OVER (PARTITION BY symbol ORDER BY ts DESC))
       )::NUMERIC, 4)),
       ts
FROM steps;

COMMIT;

-- Ozet: her hissenin simdiki fiyati ile grafikteki en dusuk / en yuksek deger ve son nokta.
SELECT s.symbol,
       s.current_price AS simdiki_fiyat,
       (SELECT h.price FROM public.price_history AS h
        WHERE h.symbol = s.symbol ORDER BY h.recorded_at DESC LIMIT 1) AS grafikteki_son_nokta,
       (SELECT min(x.price) FROM public.price_history_hourly AS x WHERE x.symbol = s.symbol) AS ay_en_dusuk,
       (SELECT max(x.price) FROM public.price_history_hourly AS x WHERE x.symbol = s.symbol) AS ay_en_yuksek,
       (SELECT count(*) FROM public.price_history AS h WHERE h.symbol = s.symbol) AS dakikalik_nokta,
       (SELECT count(*) FROM public.price_history_hourly AS x WHERE x.symbol = s.symbol) AS saatlik_nokta
FROM public.stocks AS s
ORDER BY s.symbol;
