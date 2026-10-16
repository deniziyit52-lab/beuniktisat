-- Kullanici karari (16 Ekim 2026): kayitli butun uyeler e-posta listesinde sayilir.
-- 0079 yeni uyeler icin varsayilani acti; bu dosya bugune kadar kayit olmus ve listede olmayan uyeleri de ekler.
-- Bundan sonra e-postayi menuden ya da e-postadaki baglantidan kapatan oyuncu listeden cikar ve oyle kalir.

-- Once: kac uye listedeydi
SELECT count(*) AS toplam_uye, count(*) FILTER (WHERE email_opt_in) AS once_listede FROM public.users;

UPDATE public.users
SET email_opt_in = true,
    email_opt_in_at = coalesce(email_opt_in_at, now())
WHERE NOT email_opt_in;

-- Sonra: toplam_uye ile listede ayni olmali
SELECT count(*) AS toplam_uye, count(*) FILTER (WHERE email_opt_in) AS listede FROM public.users;
