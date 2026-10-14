/* Haftalık özet e-postası ayarı: oyuncu menüden açar ya da kapatır (users.email_opt_in, set_email_opt_in RPC'si). */
(function () {
    const $ = (id) => document.getElementById(id);

    const BorsaDigestPref = {
        _uid: null,

        async load() {
            const box = $("digestPrefBox");
            if (!box) return;
            const user = BorsaFirebase.currentUser ? BorsaFirebase.currentUser() : null;
            if (!user || !window.sb) { box.style.display = "none"; return; }
            const { data, error } = await window.sb.from("users").select("email_opt_in").eq("id", user.id).maybeSingle();
            // Okunamazsa kutu hiç gösterilmez.
            if (error || !data) { box.style.display = "none"; return; }
            $("digestPrefToggle").checked = Boolean(data.email_opt_in);
            this._feedback("");
            box.style.display = "";
        },

        _feedback(msg, isError) {
            const el = $("digestPrefFeedback");
            el.textContent = msg || "";
            el.classList.toggle("is-error", Boolean(isError));
        },

        async save(on) {
            const toggle = $("digestPrefToggle");
            toggle.disabled = true;
            const { error } = await window.sb.rpc("set_email_opt_in", { p_opt_in: on });
            toggle.disabled = false;
            if (error) {
                toggle.checked = !on;
                return this._feedback(error.message || "Kaydedilemedi, biraz sonra yeniden dene.", true);
            }
            this._feedback(on ? "Açıldı. İlk haftalık özet cuma akşamı gelir." : "Kapatıldı. Artık e-posta göndermeyeceğiz.");
        },

        wire() {
            const toggle = $("digestPrefToggle");
            if (!toggle) return;
            toggle.addEventListener("change", () => this.save(toggle.checked));
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (uid === this._uid) return;
                this._uid = uid;
                this.load();
            });
        },
    };

    window.BorsaDigestPref = BorsaDigestPref;
    document.addEventListener("DOMContentLoaded", () => BorsaDigestPref.wire());
})();
