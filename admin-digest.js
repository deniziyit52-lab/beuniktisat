/* Admin paneli: haftalık özet e-postası. Gönderim durumu (admin_digest_status) ve yöneticinin kendisine deneme gönderimi
   (admin_send_digest_test -> weekly-digest Edge Function; sonuç admin_digest_test_result ile beklenir). */
(function () {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML;
    };
    const ok = (msg) => (typeof window.showToast === "function" ? window.showToast(msg) : alert(msg));
    const fail = (msg) => (typeof window.showErr === "function" ? window.showErr(msg) : alert(msg));
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const gun = (s) => new Date(s).toLocaleDateString("tr-TR", { day: "numeric", month: "long" });

    const AdminDigest = {
        _loadedFor: null,

        async load() {
            const box = $("digestStatus");
            if (!box || !window.sb || !window.sb.rpc) return;
            const { data, error } = await window.sb.rpc("admin_digest_status");
            if (error || !data) {
                box.innerHTML = `<p class="field-hint">Durum yüklenemedi: ${esc(error ? error.message : "boş cevap")}</p>`;
                return;
            }
            $("digestSummary").textContent = `${Number(data.opted_in || 0)} alıcı`;
            const rows = [];
            if (data.this_week_sent || data.this_week_failed) {
                rows.push(`<div class="column-admin-row"><div class="column-admin-text"><strong>Bu hafta</strong><span>${Number(data.this_week_sent)} gönderildi${data.this_week_failed ? ` · ${Number(data.this_week_failed)} gönderilemedi` : ""}</span></div></div>`);
            }
            (data.runs || []).forEach((r) => {
                rows.push(`<div class="column-admin-row"><div class="column-admin-text"><strong>${esc(gun(r.week_start))} haftası</strong><span>${Number(r.sent)} gönderildi${r.failed ? ` · ${Number(r.failed)} gönderilemedi` : ""}</span></div></div>`);
            });
            if (data.last_error) rows.push(`<p class="field-hint">Son hata: ${esc(data.last_error)}</p>`);
            box.innerHTML = rows.length ? rows.join("") : '<p class="field-hint">Henüz haftalık özet gönderilmedi. İlk gönderim bu cuma 18:05\'te başlar.</p>';
        },

        async sendTest() {
            const btn = $("digestTestBtn");
            btn.disabled = true;
            const label = btn.textContent;
            btn.textContent = "Gönderiliyor…";
            try {
                const { data: requestId, error } = await window.sb.rpc("admin_send_digest_test");
                if (error) return fail(error.message || "Deneme başlatılamadı.");
                for (let i = 0; i < 12; i++) {
                    await sleep(2500);
                    const { data } = await window.sb.rpc("admin_digest_test_result", { p_request_id: requestId });
                    if (!data || !data.done) continue;
                    let body = {};
                    try { body = JSON.parse(data.body || "{}"); } catch (e) {}
                    if (data.status === 200 && body.sent) return ok("Deneme e-postası gönderildi. Gelen kutunu (ve spam klasörünü) kontrol et.");
                    return fail("Gönderilemedi: " + (body.error || data.error || `durum ${data.status}`));
                }
                fail("Cevap gelmedi. Birkaç dakika sonra gelen kutunu kontrol et; gelmediyse Supabase'de weekly-digest fonksiyonunun kayıtlarına bak.");
            } finally {
                btn.disabled = false;
                btn.textContent = label;
            }
        },

        wire() {
            if (!$("digestStatus")) return;
            $("digestRefresh").addEventListener("click", () => this.load());
            $("digestTestBtn").addEventListener("click", () => this.sendTest());
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (!uid || uid === this._loadedFor) return;
                this._loadedFor = uid;
                this.load();
            });
        },
    };

    window.AdminDigest = AdminDigest;
    document.addEventListener("DOMContentLoaded", () => AdminDigest.wire());
})();
