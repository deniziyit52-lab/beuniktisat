/* Admin paneli: öneri kutusu. Oyuncuların mesajları yazanın adıyla listelenir; okundu işaretlenir, cevaplanır ya da silinir.
   Cevabı oyuncu öneri penceresinde görür (admin_reply_feedback; bildirimleri açıksa telefonuna da gider). */
(function () {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML.replace(/"/g, "&quot;");
    };
    const fail = (msg) => (typeof window.showErr === "function" ? window.showErr(msg) : alert(msg));
    const ok = (msg) => (typeof window.showToast === "function" ? window.showToast(msg) : alert(msg));
    const TURLER = { oneri: "💡 İstek / öneri", hata: "🐞 Hata", gorus: "💬 Görüş" };
    const tarih = (s) => new Date(s).toLocaleString("tr-TR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });

    const AdminFeedback = {
        _loadedFor: null,
        _items: [],

        async load() {
            const list = $("feedbackAdminList");
            if (!list || !window.sb || !window.sb.rpc) return;
            const { data, error } = await window.sb.rpc("admin_list_feedback");
            if (error || !Array.isArray(data)) {
                list.innerHTML = `<p class="field-hint">Liste yüklenemedi: ${esc(error ? error.message : "boş cevap")}</p>`;
                return;
            }
            this._items = data;
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
                const cevap = m.reply
                    ? `<div class="feedback-reply"><b>Cevabın</b> · ${esc(tarih(m.replied_at))} · ${m.reply_seen ? "oyuncu gördü ✓" : "henüz görmedi"}<p>${esc(m.reply)}</p></div>`
                    : "";
                return `
                <div class="column-admin-row feedback-admin-row${m.is_read ? " is-read" : ""}">
                    <div class="column-admin-text">
                        <strong>${esc(TURLER[m.kind] || m.kind)}${m.is_read ? "" : ' <span class="admin-tag">yeni</span>'}</strong>
                        <p class="feedback-admin-msg">${esc(m.message)}</p>
                        <span>${kim} · ${esc(tarih(m.created_at))}</span>
                        ${cevap}
                        <div class="feedback-reply-form" data-reply-form="${m.id}" hidden>
                            <textarea rows="3" maxlength="1000" placeholder="Cevabını yaz… Oyuncu bunu öneri penceresinde görür."></textarea>
                            <div class="feedback-reply-actions">
                                <button type="button" class="btn btn--primary" data-reply-send="${m.id}">Gönder</button>
                                <button type="button" class="reset-btn" data-reply-cancel="${m.id}">Vazgeç</button>
                            </div>
                        </div>
                    </div>
                    <div class="feedback-admin-actions">
                        ${m.email ? `<button type="button" class="reset-btn feedback-reply-btn" data-feedback-reply="${m.id}">${m.reply ? "Cevabı düzenle" : "Cevapla"}</button>` : ""}
                        <button type="button" class="reset-btn" data-feedback-read="${m.id}" data-read="${m.is_read ? "0" : "1"}">${m.is_read ? "Okunmadı yap" : "Okundu"}</button>
                        <button type="button" class="reset-btn" data-feedback-delete="${m.id}">Sil</button>
                    </div>
                </div>`;
            }).join("");
            list.querySelectorAll("[data-feedback-reply]").forEach(btn => {
                btn.addEventListener("click", () => this.openReply(Number(btn.dataset.feedbackReply)));
            });
            list.querySelectorAll("[data-reply-cancel]").forEach(btn => {
                btn.addEventListener("click", () => { list.querySelector(`[data-reply-form="${btn.dataset.replyCancel}"]`).hidden = true; });
            });
            list.querySelectorAll("[data-reply-send]").forEach(btn => {
                btn.addEventListener("click", () => this.sendReply(Number(btn.dataset.replySend), btn));
            });
            list.querySelectorAll("[data-feedback-read]").forEach(btn => {
                btn.addEventListener("click", () => this.setRead(Number(btn.dataset.feedbackRead), btn.dataset.read === "1"));
            });
            list.querySelectorAll("[data-feedback-delete]").forEach(btn => {
                btn.addEventListener("click", () => this.remove(Number(btn.dataset.feedbackDelete)));
            });
        },

        openReply(id) {
            const form = $("feedbackAdminList").querySelector(`[data-reply-form="${id}"]`);
            if (!form) return;
            const m = this._items.find(x => x.id === id);
            const box = form.querySelector("textarea");
            if (form.hidden) box.value = (m && m.reply) || "";
            form.hidden = false;
            box.focus();
        },

        async sendReply(id, btn) {
            const form = $("feedbackAdminList").querySelector(`[data-reply-form="${id}"]`);
            const text = form.querySelector("textarea").value.trim();
            const m = this._items.find(x => x.id === id);
            if (!text && !(m && m.reply)) return fail("Cevap boş olamaz.");
            if (!text && !confirm("Cevap boş: mevcut cevabın kaldırılsın mı?")) return;
            btn.disabled = true;
            const { error } = await window.sb.rpc("admin_reply_feedback", { p_id: id, p_reply: text });
            btn.disabled = false;
            if (error) return fail(error.message || "Cevap gönderilemedi.");
            ok(text ? "Cevap gönderildi. Oyuncu öneri penceresinde görecek." : "Cevap kaldırıldı.");
            this.load();
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
