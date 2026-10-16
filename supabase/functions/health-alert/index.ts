// Sistem sagligi sorun e-postasi. Cron hafta ici 10:00-18:59 her 5 dakikada cagirir (borsa-health-alert).
// health_alert_tick neyin gonderilecegini soyler: 'down' (kirmizi satir 10 dk suruyor), 'up' (duzeldi) ya da 'none'.
// Alicilar admins tablosundaki yoneticilerin e-postalari. Gonderilemezse health_alert_failed durumu geri alir.
// Deneme: { "test": true } -> durum degismeden ornek bir "sorun var" e-postasi (yonetici panelindeki dugme).
// Gizli ayarlar haftalik ozetle ortak: CRON_SECRET, SMTP_HOST, SMTP_PORT (465), SMTP_USER, SMTP_PASS, SMTP_FROM, SITE_URL.
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

type Item = { label: string; detail: string };
type Tick = { action: "down" | "up" | "none"; bad: Item[]; since: string | null; to: string[] };

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });

function constantTimeEquals(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
const saat = (iso: string | null) =>
  iso ? new Date(iso).toLocaleString("tr-TR", { timeZone: "Europe/Istanbul", day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }) : "";

function compose(t: Tick, adminUrl: string) {
  const down = t.action === "down";
  const subject = down
    ? `🔴 Borsa oyununda sorun: ${t.bad.map((b) => b.label).join(", ")}`
    : "🟢 Borsa oyunundaki sorun düzeldi";
  const intro = down
    ? "Sistem Sağlığı'nda aşağıdaki satırlar en az 10 dakikadır kırmızı. Oyuncular eski ya da donmuş fiyat görüyor olabilir."
    : `${saat(t.since)} itibarıyla bildirilen sorun düzeldi; Sistem Sağlığı'nda kırmızı satır kalmadı. Sorunlu olan satırlar şunlardı:`;
  const rows = t.bad.map((b) =>
    `<tr><td style="padding:8px 0;border-bottom:1px solid #e2e8f0"><b>${esc(b.label)}</b><br><span style="color:#64748b;font-size:13px">${esc(b.detail)}</span></td></tr>`).join("");
  const html = `<!doctype html><html lang="tr"><head><meta charset="utf-8"></head><body style="margin:0;background:#f1f5f9;font-family:Arial,Helvetica,sans-serif;color:#0f172a">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f1f5f9;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:14px;overflow:hidden">
<tr><td style="background:${down ? "#991b1b" : "#166534"};color:#ffffff;padding:18px 24px;font-size:20px;font-weight:700">${down ? "🔴 Sistemde sorun var" : "🟢 Sorun düzeldi"}</td></tr>
<tr><td style="padding:20px 24px">
  <p style="margin:0 0 12px;font-size:15px;line-height:1.5">${intro}</p>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0">${rows}</table>
  ${down ? `<p style="margin:14px 0 0;font-size:13px;color:#64748b;line-height:1.5">Sorun düzelince ayrıca haber verilir. Bu arada yeni e-posta gelmez.</p>` : ""}
</td></tr>
<tr><td align="center" style="padding:4px 24px 24px">
  <a href="${esc(adminUrl)}" style="display:inline-block;background:#4f46e5;color:#ffffff;text-decoration:none;font-weight:700;padding:11px 24px;border-radius:999px">Yönetici paneline git</a>
</td></tr>
</table></td></tr></table></body></html>`;
  const text = [intro, "", ...t.bad.map((b) => `- ${b.label}: ${b.detail}`), "", `Yönetici paneli: ${adminUrl}`].join("\n");
  return { subject, html, text };
}

Deno.serve(async (request) => {
  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret || !constantTimeEquals(request.headers.get("x-cron-secret") ?? "", cronSecret)) {
    return json({ error: "yetkisiz" }, 401);
  }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
  const body = await request.json().catch(() => ({}));
  // Deneme (yonetici panelindeki dugme): uyari durumuna dokunmadan ornek bir "sorun var" e-postasi gonderir.
  const test = body?.test === true;
  const { data, error } = test ? await db.rpc("health_alert_recipients") : await db.rpc("health_alert_tick");
  if (error) return json({ error: error.message }, 500);
  const tick: Tick = test
    ? {
        action: "down",
        since: null,
        to: data as string[],
        bad: [{ label: "Hisse verisi okuma (DENEME)", detail: "Bu bir deneme e-postasıdır; sistemde gerçek bir sorun yok. Gerçek bir sorun olduğunda e-posta böyle görünecek." }],
      }
    : (data as Tick);
  if (tick.action === "none") return json({ action: "none", bad: tick.bad.length });
  if (!tick.to.length) return json({ action: tick.action, error: "Yönetici e-postası bulunamadı." }, 500);

  const host = Deno.env.get("SMTP_HOST"), user = Deno.env.get("SMTP_USER"), pass = Deno.env.get("SMTP_PASS");
  const from = Deno.env.get("SMTP_FROM") ?? user, siteUrl = Deno.env.get("SITE_URL") ?? "";
  const port = Number(Deno.env.get("SMTP_PORT") ?? "465");
  if (!host || !user || !pass) {
    if (!test) await db.rpc("health_alert_failed", { p_action: tick.action });
    return json({ error: "SMTP_HOST, SMTP_USER ve SMTP_PASS ayarlanmalı." }, 500);
  }

  const m = compose(tick, `${siteUrl.replace(/\/+$/, "")}/admin.html`);
  try {
    const transport = nodemailer.createTransport({ host, port, secure: port === 465, auth: { user, pass } });
    await transport.sendMail({ from, to: tick.to.join(", "), subject: (test ? "[Deneme] " : "") + m.subject, html: m.html, text: m.text });
    transport.close();
    return json({ action: tick.action, test, sent: tick.to.length });
  } catch (e) {
    if (!test) await db.rpc("health_alert_failed", { p_action: tick.action });
    return json({ action: tick.action, error: e instanceof Error ? e.message : String(e) }, 502);
  }
});
