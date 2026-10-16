/* Admin paneli: telefon bildirimlerini açmış bütün oyunculara duyuru (admin_send_push, admin_push_stats). */
(function () {
    const $ = (id) => document.getElementById(id);
    const ok = (msg) => (typeof window.showToast === "function" ? window.showToast(msg) : alert(msg));
    const fail = (msg) => (typeof window.showErr === "function" ? window.showErr(msg) : alert(msg));

    const AdminPush = {
        _loadedFor: null,
        players: 0,

        async loadStats() {
            const tag = $("pushAdminStats");
            if (!tag || !window.sb) return;
            const { data, error } = await window.sb.rpc("admin_push_stats");
            if (error || !data) { tag.textContent = ""; return; }
            this.players = Number(data.players || 0);
            tag.textContent = `${this.players} oyuncu · ${Number(data.devices || 0)} cihaz${data.acked != null ? ` (${Number(data.acked)} tanesi bildirim alıyor)` : ""}`;
        },

        async send(e) {
            e.preventDefault();
            const title = $("pushAdminTitle").value.trim();
            const body = $("pushAdminBody").value.trim();
            if (!title) return fail("Başlık yazın.");
            if (!this.players) return fail("Henüz telefon bildirimlerini açmış oyuncu yok.");
            if (!confirm(`"${title}" bildirimi ${this.players} oyuncuya gönderilsin mi? Gönderilen bildirim geri alınamaz.`)) return;
            const btn = $("pushAdminSend");
            btn.disabled = true;
            try {
                const { data, error } = await window.sb.rpc("admin_send_push", { p_title: title, p_body: body });
                if (error) throw error;
                ok(`Bildirim ${Number(data || 0)} oyuncuya gönderiliyor; birkaç saniye içinde telefonlarda olur.`);
                $("pushAdminTitle").value = "";
                $("pushAdminBody").value = "";
                // Teslim bilgisi cihazlardan birkaç saniye içinde gelir; sayı ardından yenilenir.
                setTimeout(() => this.loadStats(), 8000);
                setTimeout(() => this.loadStats(), 30000);
            } catch (err) {
                fail(err.message || "Bildirim gönderilemedi.");
            } finally {
                btn.disabled = false;
            }
        },

        wire() {
            if (!$("pushAdminForm")) return;
            $("pushAdminForm").addEventListener("submit", (e) => this.send(e));
            if ($("pushAdminRefresh")) $("pushAdminRefresh").addEventListener("click", () => this.loadStats());
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (!uid || uid === this._loadedFor) return;
                this._loadedFor = uid;
                this.loadStats();
            });
        },
    };

    window.AdminPush = AdminPush;
    document.addEventListener("DOMContentLoaded", () => AdminPush.wire());
})();
