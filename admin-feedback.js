/* Admin paneli: öneri kutusu. Oyuncuların mesajları yazanın adıyla listelenir; okundu işaretlenir ya da silinir. */
(function () {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML.replace(/"/g, "&quot;");
    };
    const fail = (msg) => (typeof window.showErr === "function" ? window.showErr(msg) : alert(msg));
    const TURLER = { oneri: "💡 İstek / öneri", hata: "🐞 Hata", gorus: "💬 Görüş" };
    const tarih = (s) => new Date(s).toLocaleString("tr-TR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

    const AdminFeedback = {
        _loadedFor: null,

        async load() {
            const list = $("feedbackAdminList");
            if (!list || !window.sb || !window.sb.rpc) return;
            const { data, error } = await window.sb.rpc("admin_list_feedback");
            if (error || !Array.isArray(data)) {
                list.innerHTML = `<p class="field-hint">Liste yüklenemedi: ${esc(error ? error.message : "boş cevap")}</p>`;
                return;
            }
            const yeni = data.filter(m => !m.is_read).length;
            $("feedbackAdminSummary").textContent = yeni ? `${yeni} yeni` : "";
            if (data.length === 0) {
                list.innerHTML = '<p class="field-hint">Henüz mesaj yok.</p>';
                return;
            }
            list.innerHTML = data.map(m => {
                const kim = m.email
                    ? `${esc(m.name || "—")}${m.nickname ? ` (${esc(m.nickname)})` : ""} · ${esc(m.email)}`
                    : "Silinmiş oyuncu";
                return `
                <div class="column-admin-row feedback-admin-row${m.is_read ? " is-read" : ""}">
                    <div class="column-admin-text">
                        <strong>${esc(TURLER[m.kind] || m.kind)}${m.is_read ? "" : ' <span class="admin-tag">yeni</span>'}</strong>
                        <p class="feedback-admin-msg">${esc(m.message)}</p>
                        <span>${kim} · ${esc(tarih(m.created_at))}</span>
                    </div>
                    <div class="feedback-admin-actions">
                        <button type="button" class="reset-btn" data-feedback-read="${m.id}" data-read="${m.is_read ? "0" : "1"}">${m.is_read ? "Okunmadı yap" : "Okundu"}</button>
                        <button type="button" class="reset-btn" data-feedback-delete="${m.id}">Sil</button>
                    </div>
                </div>`;
            }).join("");
            list.querySelectorAll("[data-feedback-read]").forEach(btn => {
                btn.addEventListener("click", () => this.setRead(Number(btn.dataset.feedbackRead), btn.dataset.read === "1"));
            });
            list.querySelectorAll("[data-feedback-delete]").forEach(btn => {
                btn.addEventListener("click", () => this.remove(Number(btn.dataset.feedbackDelete)));
            });
        },

        async setRead(id, read) {
            const { error } = await window.sb.rpc("admin_set_feedback_read", { p_id: id, p_read: read });
            if (error) return fail(error.message || "Güncellenemedi.");
            this.load();
        },

        async remove(id) {
            if (!confirm("Bu mesaj silinsin mi? Geri alınamaz.")) return;
            const { error } = await window.sb.rpc("admin_delete_feedback", { p_id: id });
            if (error) return fail(error.message || "Silinemedi.");
            this.load();
        },

        wire() {
            if (!$("feedbackAdminList")) return;
            $("feedbackAdminRefresh").addEventListener("click", () => this.load());
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (!uid || uid === this._loadedFor) return;
                this._loadedFor = uid;
                this.load();
            });
        },
    };

    window.AdminFeedback = AdminFeedback;
    document.addEventListener("DOMContentLoaded", () => AdminFeedback.wire());
})();
