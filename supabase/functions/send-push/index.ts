// Telefon bildirimi gonderici (Web Push). Veritabani push_dispatch ile cagirir (emir gerceklesince, bildirimler
// acilinca). push_queue_take ile gonderilmemis bildirimleri ve alicilarin cihazlarini alir, her cihaza gonderir,
// push_queue_done ile isaretler. Cihaz "artik yok" derse (404/410) o cihaz adresi silinir.
// Gizli ayarlar: CRON_SECRET (ortak), VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, SITE_URL (ortak; VAPID iletisim adresi).
import { createClient } from "npm:@supabase/supabase-js@2";

type Sub = { endpoint: string; p256dh: string; auth: string };
type Item = { id: number; title: string; body: string | null; url: string | null; subs: Sub[] };

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });

function constantTimeEquals(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Gizli ayara yapistirirken araya giren bosluk, tirnak ya da satir sonlari temizlenir.
const clean = (s: string | undefined) => (s ?? "").replace(/["'\s]/g, "");

Deno.serve(async (request) => {
  try {
    return await handle(request);
  } catch (e) {
    // Beklenmeyen hata: neden, veritabanindaki net._http_response kaydinda gorunsun.
    return json({ error: "beklenmeyen hata: " + String((e as Error)?.message ?? e).slice(0, 300) }, 500);
  }
});

async function handle(request: Request) {
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret || !constantTimeEquals(request.headers.get("x-cron-secret") ?? "", cronSecret)) {
    return json({ error: "yetkisiz" }, 401);
  }
  const pub = clean(Deno.env.get("VAPID_PUBLIC_KEY")), priv = clean(Deno.env.get("VAPID_PRIVATE_KEY"));
  if (!pub || !priv) return json({ error: "VAPID_PUBLIC_KEY ve VAPID_PRIVATE_KEY ayarlanmalı." }, 500);
  if (pub.length !== 87) return json({ error: `VAPID_PUBLIC_KEY ${pub.length} karakter; 87 olmalı. Değeri dosyadan yeniden kopyala.` }, 500);
  if (priv.length !== 43) return json({ error: `VAPID_PRIVATE_KEY ${priv.length} karakter; 43 olmalı. Değeri dosyadan yeniden kopyala.` }, 500);
  const site = clean(Deno.env.get("SITE_URL"));
  // Kutuphane burada yuklenir: yuklenemezse nedeni cevaba yazilir (en ustte yuklenseydi fonksiyon aciklamasiz cokerdi).
  let webpush;
  try {
    webpush = (await import("npm:web-push@3.6.7")).default;
  } catch (e) {
    return json({ error: "web-push kütüphanesi yüklenemedi: " + String((e as Error)?.message ?? e).slice(0, 200) }, 500);
  }
  try {
    webpush.setVapidDetails(/^https:\/\//.test(site) ? site : "mailto:borsa@example.com", pub, priv);
  } catch (e) {
    return json({ error: "VAPID anahtarları geçersiz: " + String((e as Error)?.message ?? e).slice(0, 200) }, 500);
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const { data, error } = await db.rpc("push_queue_take", { p_limit: 200 });
  if (error) return json({ error: error.message }, 500);
  const items = (data ?? []) as Item[];

  const sent: number[] = [];
  const dead = new Set<string>();
  let ok = 0, failed = 0;
  const errors: string[] = [];
  for (const it of items) {
    const payload = JSON.stringify({ title: it.title, body: it.body ?? "", url: it.url ?? "/" });
    let anyTemporaryFailure = false;
    for (const s of it.subs) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600 });
        ok++;
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) dead.add(s.endpoint);
        else { anyTemporaryFailure = true; failed++; errors.push(String((e as Error).message ?? e).slice(0, 200)); }
      }
    }
    // Cihazi olmayan oyuncunun bildirimi de gonderilmis sayilir; gecici hata varsa sonraki cagrida yeniden denenir.
    if (!anyTemporaryFailure) sent.push(it.id);
  }
  if (items.length) await db.rpc("push_queue_done", { p_sent: sent, p_dead_endpoints: [...dead] });
  return json({ items: items.length, ok, failed, removed: dead.size, error: errors[0] ?? null });
}
