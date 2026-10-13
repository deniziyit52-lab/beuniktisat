/* Takma ad: oyuncu liderlik tablosunda gerçek adı yerine görünecek adı seçer (set_nickname / get_my_nickname RPC'leri).
   İlk seçimden sonra en fazla 2 kez değiştirilebilir; sayım sunucuda tutulur. */
(function () {
    const $ = (id) => document.getElementById(id);

    const BorsaNickname = {
        _uid: null,
        _state: null,

        async load() {
            const box = $("nicknameBox");
            if (!box) return;
            const user = BorsaFirebase.currentUser ? BorsaFirebase.currentUser() : null;
            if (!user || !window.sb || !window.sb.rpc) { box.style.display = "none"; return; }
            const { data, error } = await window.sb.rpc("get_my_nickname");
            // Fonksiyon henüz kurulmadıysa kutu hiç gösterilmez.
            if (error || !data) { box.style.display = "none"; return; }
            this._state = data;
            this.render();
        },

        render() {
            const box = $("nicknameBox");
            const s = this._state;
            if (!box || !s) return;
            const left = Number(s.remaining || 0);
            $("nicknameCurrent").textContent = s.nickname
                ? `Tabloda "${s.nickname}" olarak görünüyorsun.`
                : "Tabloda gerçek adınla görünüyorsun.";
            $("nicknameHint").textContent = left > 0
                ? (s.nickname ? `Kalan değiştirme hakkın: ${left}.` : "İstersen bir takma ad seç. Seçtikten sonra en fazla 2 kez değiştirebilirsin.")
                : "Takma adını değiştirme hakkın kalmadı.";
            $("nicknameInput").value = s.nickname || "";
            $("nicknameInput").disabled = left <= 0;
            $("nicknameSave").disabled = left <= 0;
            $("nicknameRemove").style.display = s.nickname ? "" : "none";
            box.style.display = "";
        },

        _feedback(msg, isError) {
            const el = $("nicknameFeedback");
            el.textContent = msg || "";
            el.classList.toggle("is-error", Boolean(isError));
        },

        async save(value) {
            const name = String(value || "").trim();
            if (name && name === (this._state && this._state.nickname)) return;
            if (name) {
                const left = Number(this._state && this._state.remaining || 0);
                if (!confirm(`Takma adın "${name}" olsun mu? Bundan sonra ${left - 1} hakkın kalacak.`)) return;
            } else {
                const left = Number(this._state && this._state.remaining || 0);
                const warn = left > 0 ? "" : " Değiştirme hakkın kalmadığı için yeniden takma ad seçemezsin.";
                if (!confirm("Takma adın kaldırılsın ve tabloda gerçek adın görünsün mü?" + warn)) return;
            }
            this._feedback("");
            const { data, error } = await window.sb.rpc("set_nickname", { p_nickname: name });
            if (error || !data) return this._feedback((error && error.message) || "Kaydedilemedi.", true);
            this._state = data;
            this.render();
            this._feedback(name ? "Takma adın kaydedildi." : "Takma adın kaldırıldı.");
            if (typeof window.invalidateSidebarCaches === "function") window.invalidateSidebarCaches();
            const refresh = $("refreshLeaderboardBtn");
            if (refresh) refresh.click();
        },

        wire() {
            const form = $("nicknameForm");
            if (!form) return;
            form.addEventListener("submit", (e) => { e.preventDefault(); this.save($("nicknameInput").value); });
            $("nicknameRemove").addEventListener("click", () => this.save(""));
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (uid === this._uid) return;
                this._uid = uid;
                this.load();
            });
        },
    };

    window.BorsaNickname = BorsaNickname;
    document.addEventListener("DOMContentLoaded", () => BorsaNickname.wire());
})();
