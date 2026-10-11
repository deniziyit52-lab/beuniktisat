/* Admin paneli: e-posta ile bilgilendirmeye onay veren üyelerin listesi (admin_list_email_opt_ins RPC'si). */
(function () {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML;
    };
    const ok = (msg) => (typeof window.showToast === "function" ? window.showToast(msg) : alert(msg));
    const fail = (msg) => (typeof window.showErr === "function" ? window.showErr(msg) : alert(msg));

    const AdminMailing = {
        _emails: [],
        _loadedFor: null,

        async load() {
            const list = $("mailingList");
            const summary = $("mailingSummary");
            if (!list || !window.sb || !window.sb.rpc) return;
            const { data, error } = await window.sb.rpc("admin_list_email_opt_ins");
            if (error || !data) {
                list.innerHTML = `<p class="field-hint">Liste yüklenemedi: ${esc(error ? error.message : "boş cevap")}</p>`;
                return;
            }
            const members = Array.isArray(data.members) ? data.members : [];
            this._emails = members.map(m => String(m.email || "").trim()).filter(Boolean);
            if (summary) summary.textContent = `${members.length} / ${Number(data.total_members || 0)} üye onay verdi`;
            $("mailingCopyBtn").disabled = this._emails.length === 0;
            if (members.length === 0) {
                list.innerHTML = '<p class="field-hint">Henüz e-posta ile bilgilendirmeye onay veren üye yok.</p>';
                return;
            }
            list.innerHTML = members.map(m => `
                <div class="column-admin-row">
                    <div class="column-admin-text">
                        <strong>${esc(m.email)}</strong>
                        <span>${esc(m.name || "—")}${m.opted_at ? ` · ${new Date(m.opted_at).toLocaleDateString("tr-TR")} tarihinde onay verdi` : ""}</span>
                    </div>
                </div>`).join("");
        },

        async copy() {
            if (!this._emails.length) return;
            const text = this._emails.join("; ");
            try {
                await navigator.clipboard.writeText(text);
                ok(`${this._emails.length} e-posta adresi kopyalandı. E-postanın "Gizli (BCC)" alanına yapıştır.`);
            } catch (_) {
                // Pano izni yoksa adresler seçilebilir bir kutuda gösterilir.
                const box = $("mailingFallback");
                if (box) { box.style.display = "block"; box.value = text; box.focus(); box.select(); }
                fail("Otomatik kopyalanamadı; aşağıdaki kutudan elle kopyalayabilirsin.");
            }
        },

        wire() {
            if (!$("mailingList")) return;
            $("mailingRefresh").addEventListener("click", () => this.load());
            $("mailingCopyBtn").addEventListener("click", () => this.copy());
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (!uid || uid === this._loadedFor) return;
                this._loadedFor = uid;
                this.load();
            });
        },
    };

    window.AdminMailing = AdminMailing;
    document.addEventListener("DOMContentLoaded", () => AdminMailing.wire());
})();
