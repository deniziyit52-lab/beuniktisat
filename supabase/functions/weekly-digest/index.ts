// Haftalik ozet e-postasi. Cuma aksami cron 10 dakikada bir cagirir; her cagrida en fazla 40 kisiye gonderir.
// Alici kalmayinca haftayi kapatir (weekly_digest_finish). Yonetici denemesi: { "test_user": "<uuid>" }.
// Abonelikten cikma: POST ?unsub=<token> (sitedeki eposta-iptal sayfasi ya da e-posta programi; cron anahtari istemez).
// Gizli ayarlar: CRON_SECRET, SMTP_HOST, SMTP_PORT (465), SMTP_USER, SMTP_PASS, SMTP_FROM, SITE_URL.
// Supabase Edge Functions 25 ve 587 portlarina izin vermez; SMTP 465 (SSL) uzerinden baglanir.
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";

const BATCH = 40;

type Recipient = {
  user_id: string; email: string; name: string; wealth: number; return_pct: number;
  rank: number | null; prev_wealth: number | null; prev_rank: number | null; trades_week: number; token: string;
};
type Payload = {
  week_start: string; active_players: number; trades_week: number; recipients: Recipient[];
  top: { name: string; return_pct: number }[];
  movers: { up: { name: string; pct: number } | null; down: { name: string; pct: number } | null };
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json; charset=utf-8" } });

function constantTimeEquals(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
const tl = (n: number) => new Intl.NumberFormat("tr-TR", { maximumFractionDigits: 0 }).format(n) + " ₺";
const pct = (n: number) => (n > 0 ? "+" : n < 0 ? "−" : "") + "%" + new Intl.NumberFormat("tr-TR", { minimumFractionDigits: 1, maximumFractionDigits: 1 }).format(Math.abs(n));
const renk = (n: number) => (n > 0 ? "#16a34a" : n < 0 ? "#dc2626" : "#475569");

function compose(r: Recipient, p: Payload, siteUrl: string, unsubUrl: string) {
  const active = r.rank != null;
  const weekChange = r.prev_wealth != null && r.prev_wealth > 0 ? (r.wealth / r.prev_wealth - 1) * 100 : null;
  const rankMove = active && r.prev_rank != null ? r.prev_rank - r.rank! : null;

  let subject: string;
  if (!active) subject = "Piyasa seni bekliyor: bu hafta borsada neler oldu?";
  else if (weekChange != null) subject = `Haftalık özetin: ${pct(weekChange)} · ${r.rank}. sıradasın`;
  else subject = `Haftalık özetin: ${r.rank}. sıradasın`;

  const lines: string[] = [];
  if (!active) {
    lines.push("Henüz hiç işlem yapmadın. 100.000 ₺ sanal paran hâlâ seni bekliyor; ilk hisseni almak bir dakika sürer.");
  } else {
    if (weekChange != null) lines.push(`Bu hafta toplam varlığın <b style="color:${renk(weekChange)}">${pct(weekChange)}</b> değişti.`);
    if (rankMove != null && rankMove > 0) lines.push(`Sıralamada <b style="color:#16a34a">${rankMove} basamak yükseldin</b>.`);
    else if (rankMove != null && rankMove < 0) lines.push(`Sıralamada ${-rankMove} basamak geriledin. Pazartesi yeni bir hafta.`);
    else if (rankMove === 0) lines.push("Sıralamadaki yerini korudun.");
    if (r.trades_week === 0) lines.push("Bu hafta hiç işlem yapmadın. Bazen en iyi hamle beklemektir; bazen de unutmaktır.");
  }

  const statRow = (label: string, value: string, color = "#0f172a") =>
    `<tr><td style="padding:6px 0;color:#64748b;font-size:14px">${label}</td><td style="padding:6px 0;text-align:right;font-weight:700;font-size:15px;color:${color}">${value}</td></tr>`;
  const stats = [
    statRow("Toplam varlığın", tl(r.wealth)),
    statRow("Başlangıca göre", pct(r.return_pct), renk(r.return_pct)),
    active ? statRow("Sıralaman", `${r.rank}. / ${p.active_players} oyuncu`) : "",
    r.prev_rank != null && active ? statRow("Geçen hafta", `${r.prev_rank}.`, "#64748b") : "",
  ].join("");

  const top = p.top.map((t, i) => `<li style="margin:2px 0">${["🥇", "🥈", "🥉"][i]} ${esc(t.name)} <span style="color:${renk(t.return_pct)}">${pct(t.return_pct)}</span></li>`).join("");
  const movers = [
    p.movers?.up ? `<li style="margin:2px 0">📈 En çok yükselen: <b>${esc(p.movers.up.name)}</b> <span style="color:${renk(p.movers.up.pct)}">${pct(p.movers.up.pct)}</span></li>` : "",
    p.movers?.down ? `<li style="margin:2px 0">📉 En çok düşen: <b>${esc(p.movers.down.name)}</b> <span style="color:${renk(p.movers.down.pct)}">${pct(p.movers.down.pct)}</span></li>` : "",
    `<li style="margin:2px 0">🔁 Bu hafta toplam ${new Intl.NumberFormat("tr-TR").format(p.trades_week)} işlem yapıldı.</li>`,
  ].join("");

  const html = `<!doctype html><html lang="tr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head><body style="margin:0;background:#f1f5f9;font-family:Arial,Helvetica,sans-serif;color:#0f172a">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f1f5f9;padding:24px 12px"><tr><td align="center">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border-radius:14px;overflow:hidden">
<tr><td style="background:#0f172a;color:#ffffff;padding:20px 24px">
  <div style="font-size:12px;letter-spacing:2px;color:#94a3b8;text-transform:uppercase">ZBEÜ İktisat Topluluğu · Borsa Oyunu</div>
  <div style="font-size:22px;font-weight:700;margin-top:6px">Haftalık özetin</div>
</td></tr>
<tr><td style="padding:22px 24px 8px">
  <p style="margin:0 0 12px;font-size:16px">Merhaba ${esc(r.name)},</p>
  ${lines.map((l) => `<p style="margin:0 0 10px;font-size:15px;line-height:1.5">${l}</p>`).join("")}
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin:12px 0 4px;border-top:1px solid #e2e8f0;border-bottom:1px solid #e2e8f0">${stats}</table>
</td></tr>
<tr><td style="padding:8px 24px">
  <div style="font-weight:700;font-size:15px;margin:8px 0 4px">Haftanın öne çıkanları</div>
  <ul style="margin:0;padding-left:0;list-style:none;font-size:14px;line-height:1.6">${movers}</ul>
  ${top ? `<div style="font-weight:700;font-size:15px;margin:14px 0 4px">Liderlikte ilk 3</div><ul style="margin:0;padding-left:0;list-style:none;font-size:14px;line-height:1.6">${top}</ul>` : ""}
</td></tr>
<tr><td align="center" style="padding:20px 24px 26px">
  <a href="${esc(siteUrl)}" style="display:inline-block;background:#4f46e5;color:#ffffff;text-decoration:none;font-weight:700;padding:12px 26px;border-radius:999px">Piyasaya git</a>
  <div style="margin-top:10px;font-size:12px;color:#64748b">Piyasa hafta içi 10:00–18:00 arası açık.</div>
</td></tr>
<tr><td style="padding:14px 24px;background:#f8fafc;font-size:11px;line-height:1.5;color:#94a3b8">
  Bu e-postayı ZBEÜ İktisat Topluluğu Borsa Oyunu'na kayıtlı olduğun için alıyorsun. Paralar sanaldır; bu e-posta yatırım tavsiyesi değildir.<br>
  <a href="${esc(unsubUrl)}" style="color:#64748b">Haftalık özeti artık almak istemiyorum</a>
</td></tr>
</table></td></tr></table></body></html>`;

  const text = [
    `Merhaba ${r.name},`, "",
    ...lines.map((l) => l.replace(/<[^>]+>/g, "")), "",
    `Toplam varlığın: ${tl(r.wealth)}`,
    `Başlangıca göre: ${pct(r.return_pct)}`,
    active ? `Sıralaman: ${r.rank}. / ${p.active_players} oyuncu` : "",
    "",
    p.movers?.up ? `En çok yükselen: ${p.movers.up.name} ${pct(p.movers.up.pct)}` : "",
    p.movers?.down ? `En çok düşen: ${p.movers.down.name} ${pct(p.movers.down.pct)}` : "",
    p.top.length ? "Liderlikte ilk 3: " + p.top.map((t, i) => `${i + 1}. ${t.name} ${pct(t.return_pct)}`).join(", ") : "",
    "", `Piyasaya git: ${siteUrl}`, "", `Haftalık özeti almak istemiyorsan: ${unsubUrl}`,
  ].filter((l, i, a) => l !== "" || a[i - 1] !== "").join("\n");

  return { subject, html, text };
}

Deno.serve(async (request) => {
  const url = new URL(request.url);
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const db = createClient(supabaseUrl, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

  // Abonelikten cikma: yalnizca POST. E-postadaki baglanti sitedeki onay sayfasini acar, oradaki dugme buraya POST eder;
  // e-posta programlarinin tek tik istegi (List-Unsubscribe-Post) de POST'tur. GET kabul edilmez, cunku bazi
  // e-posta servisleri baglantilari tarama icin kendiliginden acar.
  const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "content-type" };
  const unsub = url.searchParams.get("unsub");
  if (unsub && request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
  if (unsub && request.method === "POST") {
    const res = /^[0-9a-f-]{36}$/i.test(unsub) ? await db.rpc("weekly_digest_unsubscribe", { p_token: unsub }) : null;
    const ok = Boolean(res && !res.error && res.data === true);
    return new Response(JSON.stringify({ ok }), { status: ok ? 200 : 400, headers: { ...cors, "Content-Type": "application/json; charset=utf-8" } });
  }

  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret || !constantTimeEquals(request.headers.get("x-cron-secret") ?? "", cronSecret)) {
    return json({ error: "yetkisiz" }, 401);
  }

  const host = Deno.env.get("SMTP_HOST"), user = Deno.env.get("SMTP_USER"), pass = Deno.env.get("SMTP_PASS");
  const from = Deno.env.get("SMTP_FROM") ?? user, siteUrl = Deno.env.get("SITE_URL") ?? "";
  const port = Number(Deno.env.get("SMTP_PORT") ?? "465");
  if (!host || !user || !pass || !siteUrl) return json({ error: "SMTP_HOST, SMTP_USER, SMTP_PASS ve SITE_URL ayarlanmalı." }, 500);

  const body = await request.json().catch(() => ({}));
  const testUser: string | undefined = body?.test_user;

  const { data, error } = await db.rpc("weekly_digest_payload", { p_limit: BATCH, p_only_user: testUser ?? null });
  if (error) return json({ error: error.message }, 500);
  const payload = data as Payload;

  if (testUser && payload.recipients.length === 0) return json({ error: "Yönetici hesabının oyuncu kaydı bulunamadı." }, 404);
  if (!testUser && payload.recipients.length === 0) {
    const fin = await db.rpc("weekly_digest_finish");
    return json({ sent: 0, finished: fin.data === true });
  }

  const transport = nodemailer.createTransport({ host, port, secure: port === 465, auth: { user, pass }, pool: true, maxConnections: 1 });
  let sent = 0, failed = 0;
  const errors: string[] = [];
  for (const r of payload.recipients) {
    const unsubPage = `${siteUrl.replace(/\/+$/, "")}/eposta-iptal?t=${r.token}`;
    const oneClick = `${supabaseUrl}/functions/v1/weekly-digest?unsub=${r.token}`;
    const m = compose(r, payload, siteUrl, unsubPage);
    try {
      await transport.sendMail({
        from, to: r.email, subject: (testUser ? "[Deneme] " : "") + m.subject, html: m.html, text: m.text,
        headers: { "List-Unsubscribe": `<${oneClick}>`, "List-Unsubscribe-Post": "List-Unsubscribe=One-Click" },
      });
      sent++;
      if (!testUser) await db.rpc("weekly_digest_record", { p_user: r.user_id, p_ok: true });
    } catch (e) {
      failed++;
      const msg = e instanceof Error ? e.message : String(e);
      errors.push(msg);
      if (!testUser) await db.rpc("weekly_digest_record", { p_user: r.user_id, p_ok: false, p_error: msg });
    }
  }
  transport.close();
  return json({ test: Boolean(testUser), sent, failed, error: errors[0] ?? null }, failed && !sent ? 502 : 200);
});
