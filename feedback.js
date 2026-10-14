/* Öneri kutusu: oyuncu istek, hata ya da görüş yazar (submit_feedback RPC'si). Mesajları yalnızca yöneticiler okur. */
(function () {
    const $ = (id) => document.getElementById(id);

    const BorsaFeedback = {
        _sending: false,

        setOpen(open) {
            const modal = $("feedbackModal");
            if (!modal) return;
            if (open) {
                // SSS'nin içinden açıldıysa SSS kapanır; iki pencere üst üste durmasın.
                const faq = $("faqModal");
                if (faq && faq.style.display === "flex") { faq.style.display = "none"; faq.setAttribute("aria-hidden", "true"); }
                this._result("");
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

        async send() {
            if (this._sending) return;
            const message = $("feedbackMessage").value.trim();
            const kind = (document.querySelector('input[name="feedbackKind"]:checked') || {}).value || "oneri";
            if (message.length < 3) return this._result("Biraz daha yazar mısın?", true);
            const user = BorsaFirebase.currentUser ? BorsaFirebase.currentUser() : null;
            if (!user || !window.sb || !window.sb.rpc) return this._result("Mesaj göndermek için giriş yapmalısın.", true);

            this._sending = true;
            $("feedbackSend").disabled = true;
            this._result("");
            const { error } = await window.sb.rpc("submit_feedback", { p_kind: kind, p_message: message });
            this._sending = false;
            $("feedbackSend").disabled = false;
            if (error) return this._result(error.message || "Gönderilemedi, biraz sonra yeniden dene.", true);
            $("feedbackMessage").value = "";
            this._count();
            this._result("Teşekkürler! Mesajın bize ulaştı.");
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
        },
    };

    window.BorsaFeedback = BorsaFeedback;
    document.addEventListener("DOMContentLoaded", () => BorsaFeedback.wire());
})();
