/* Öneri kutusu: oyuncu istek, hata ya da görüş yazar (submit_feedback RPC'si). Mesajları yalnızca yöneticiler okur.
   Yöneticinin cevabı pencerede oyuncunun kendi mesajının altında görünür (my_feedback). Görülmemiş cevap varsa
   body.has-feedback-reply ile 💡 düğmesinde nokta çıkar; pencere açılınca cevaplar görüldü sayılır. ?oneri=1 pencereyi açar. */
(function () {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML;
    };
    const TURLER = { oneri: "💡 İstek / öneri", hata: "🐞 Hata", gorus: "💬 Görüş" };
    const tarih = (s) => new Date(s).toLocaleString("tr-TR", { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
    const signedIn = () => Boolean(BorsaFirebase.currentUser && BorsaFirebase.currentUser());

    const BorsaFeedback = {
        _sending: false,
        _uid: null,
        _checkedAt: 0,

        setOpen(open) {
            const modal = $("feedbackModal");
            if (!modal) return;
            if (open) {
                // SSS'nin içinden açıldıysa SSS kapanır; iki pencere üst üste durmasın.
                const faq = $("faqModal");
                if (faq && faq.style.display === "flex") { faq.style.display = "none"; faq.setAttribute("aria-hidden", "true"); }
                this._result("");
                this.loadMine(true);
            }
            modal.style.display = open ? "flex" : "none";
            modal.setAttribute("aria-hidden", String(!open));
            if (open) $("feedbackMessage").focus(); else $("feedbackBtn").focus();
        },

        _result(msg, isError) {
            const el = $("feedbackResult");
            el.textContent = msg || "";
            el.classList.toggle("is-error", Boolean(isError));
        },

        _count() {
            $("feedbackCount").textContent = `${$("feedbackMessage").value.length} / 1000`;
        },

        _dot(on) {
            document.body.classList.toggle("has-feedback-reply", Boolean(on));
        },

        // Pencerede oyuncunun mesajları ve cevaplar. markSeen: görülmemiş cevaplar görüldü sayılır, nokta kalkar.
        async loadMine(markSeen) {
            const box = $("feedbackHistory");
            if (!box || !window.sb || !window.sb.rpc || !signedIn()) {
                if (box) box.hidden = true;
                return;
            }
            const { data, error } = await window.sb.rpc("my_feedback");
            if (error || !Array.isArray(data) || data.length === 0) {
                box.hidden = true;
                return;
            }
            box.innerHTML = '<h3 class="feedback-history-title">Mesajların</h3>' + data.map(m => `
                <div class="feedback-item">
                    <div class="feedback-item-head">${esc(TURLER[m.kind] || m.kind)} · ${esc(tarih(m.created_at))}</div>
                    <p class="feedback-item-msg">${esc(m.message)}</p>
                    ${m.reply
                        ? `<div class="feedback-reply${m.reply_seen ? "" : " is-new"}"><b>💬 Yönetici cevabı</b>${m.reply_seen ? "" : ' <span class="feedback-new">yeni</span>'} · ${esc(tarih(m.replied_at))}<p>${esc(m.reply)}</p></div>`
                        : '<div class="feedback-wait">Henüz cevaplanmadı.</div>'}
                </div>`).join("");
            box.hidden = false;
            const unseen = data.some(m => m.reply && !m.reply_seen);
            if (markSeen && unseen) {
                await window.sb.rpc("mark_feedback_replies_seen");
                this._dot(false);
            } else {
                this._dot(unseen);
            }
        },

        // Görülmemiş cevap var mı (nokta için). Sekmeye her dönüşte en fazla dakikada bir sorulur.
        async checkReplies() {
            if (!window.sb || !window.sb.rpc || !signedIn()) return this._dot(false);
            if (Date.now() - this._checkedAt < 60000) return;
            this._checkedAt = Date.now();
            const { data } = await window.sb.rpc("my_feedback");
            this._dot(Array.isArray(data) && data.some(m => m.reply && !m.reply_seen));
        },

        async send() {
            if (this._sending) return;
            const message = $("feedbackMessage").value.trim();
            const kind = (document.querySelector('input[name="feedbackKind"]:checked') || {}).value || "oneri";
            if (message.length < 3) return this._result("Biraz daha yazar mısın?", true);
            if (!signedIn() || !window.sb || !window.sb.rpc) return this._result("Mesaj göndermek için giriş yapmalısın.", true);

            this._sending = true;
            $("feedbackSend").disabled = true;
            this._result("");
            const { error } = await window.sb.rpc("submit_feedback", { p_kind: kind, p_message: message });
            this._sending = false;
            $("feedbackSend").disabled = false;
            if (error) return this._result(error.message || "Gönderilemedi, biraz sonra yeniden dene.", true);
            $("feedbackMessage").value = "";
            this._count();
            this._result("Teşekkürler! Mesajın bize ulaştı. Cevabımızı burada göreceksin.");
            this.loadMine(false);
        },

        wire() {
            const modal = $("feedbackModal");
            if (!modal) return;
            document.querySelectorAll("[data-open-feedback]").forEach(btn => btn.addEventListener("click", () => this.setOpen(true)));
            $("feedbackCloseBtn").addEventListener("click", () => this.setOpen(false));
            modal.addEventListener("click", (e) => { if (e.target === modal) this.setOpen(false); });
            document.addEventListener("keydown", (e) => {
                if (e.key === "Escape" && modal.style.display === "flex") this.setOpen(false);
            });
            $("feedbackMessage").addEventListener("input", () => this._count());
            $("feedbackForm").addEventListener("submit", (e) => { e.preventDefault(); this.send(); });

            // Cevap bildirimine dokunarak gelindiyse pencere giriş anlaşılınca açılır.
            const params = new URLSearchParams(location.search);
            let openOnLogin = params.has("oneri");
            if (openOnLogin) {
                params.delete("oneri");
                history.replaceState(null, "", location.pathname + (params.toString() ? "?" + params : "") + location.hash);
            }
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (uid === this._uid) return;
                this._uid = uid;
                this._checkedAt = 0;
                if (uid && openOnLogin) {
                    openOnLogin = false;
                    this.setOpen(true);
                } else {
                    this.checkReplies();
                }
            });
            document.addEventListener("visibilitychange", () => {
                if (document.visibilityState === "visible") this.checkReplies();
            });
        },
    };

    window.BorsaFeedback = BorsaFeedback;
    document.addEventListener("DOMContentLoaded", () => BorsaFeedback.wire());
})();
