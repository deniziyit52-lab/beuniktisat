/* Admin paneli: takma adı olan oyuncular (gerçek adlarıyla) ve uygunsuz takma adı kaldırma. */
(function () {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML.replace(/"/g, "&quot;");
    };
    const ok = (msg) => (typeof window.showToast === "function" ? window.showToast(msg) : alert(msg));
    const fail = (msg) => (typeof window.showErr === "function" ? window.showErr(msg) : alert(msg));

    const AdminNicknames = {
        _loadedFor: null,

        async load() {
            const list = $("nicknameAdminList");
            if (!list || !window.sb || !window.sb.rpc) return;
            const { data, error } = await window.sb.rpc("admin_list_nicknames");
            if (error || !Array.isArray(data)) {
                list.innerHTML = `<p class="field-hint">Liste yüklenemedi: ${esc(error ? error.message : "boş cevap")}</p>`;
                return;
            }
            if (data.length === 0) {
                list.innerHTML = '<p class="field-hint">Henüz takma ad seçen oyuncu yok.</p>';
                return;
            }
            list.innerHTML = data.map(u => `
                <div class="column-admin-row">
                    <div class="column-admin-text">
                        <strong>${esc(u.nickname)}</strong>
                        <span>${esc(u.name || "—")} · ${esc(u.email)}</span>
                    </div>
                    <button type="button" class="reset-btn" data-nickname-clear="${esc(u.email)}" data-nickname="${esc(u.nickname)}">Kaldır</button>
                </div>`).join("");
            list.querySelectorAll("[data-nickname-clear]").forEach(btn => {
                btn.addEventListener("click", () => this.clear(btn.dataset.nicknameClear, btn.dataset.nickname));
            });
        },

        async clear(email, nickname) {
            if (!confirm(`"${nickname}" takma adı kaldırılsın mı? Oyuncu tabloda gerçek adıyla görünür.`)) return;
            const { error } = await window.sb.rpc("admin_clear_nickname", { p_user_email: email });
            if (error) return fail(error.message || "Takma ad kaldırılamadı.");
            ok(`"${nickname}" takma adı kaldırıldı.`);
            this.load();
        },

        wire() {
            if (!$("nicknameAdminList")) return;
            $("nicknameAdminRefresh").addEventListener("click", () => this.load());
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (!uid || uid === this._loadedFor) return;
                this._loadedFor = uid;
                this.load();
            });
        },
    };

    window.AdminNicknames = AdminNicknames;
    document.addEventListener("DOMContentLoaded", () => AdminNicknames.wire());
})();
