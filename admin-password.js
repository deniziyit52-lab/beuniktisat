/* Admin paneli: şifresini unutan üyeye geçici şifre verme (admin_set_user_password RPC'si). */
(function () {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML;
    };
    const ok = (msg) => (typeof window.showToast === "function" ? window.showToast(msg) : alert(msg));
    const fail = (msg) => (typeof window.showErr === "function" ? window.showErr(msg) : alert(msg));

    // Birbirine karışan karakterler (0/o, 1/l/i) yok; telefonda kolay yazılsın diye küçük harf ve rakam.
    const ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789";

    const AdminPassword = {
        _message: "",

        generate() {
            const bytes = new Uint32Array(8);
            window.crypto.getRandomValues(bytes);
            const chars = Array.from(bytes, b => ALPHABET[b % ALPHABET.length]);
            return chars.slice(0, 4).join("") + "-" + chars.slice(4).join("");
        },

        async submit() {
            const form = $("tempPasswordForm");
            if (!form.reportValidity()) return;
            const email = $("tempPasswordEmail").value.trim().toLowerCase();
            const password = $("tempPasswordValue").value.trim();
            if (password.length < 6) return fail("Şifre en az 6 karakter olmalı.");
            if (!confirm(`${email} hesabının şifresi değiştirilsin mi? Üyenin eski şifresi artık geçmeyecek.`)) return;

            const button = $("tempPasswordSubmit");
            button.disabled = true;
            try {
                if (!window.sb || !window.sb.rpc) throw new Error("Supabase bağlantısı hazır değil.");
                const { data, error } = await window.sb.rpc("admin_set_user_password", {
                    p_user_email: email,
                    p_new_password: password,
                });
                if (error) throw error;
                if (!data || data.changed !== true) throw new Error("Şifre değişti yanıtı alınamadı.");
                form.reset();
                this._showResult(data, password);
                ok(`${data.email} hesabının şifresi değiştirildi.`);
            } catch (err) {
                console.error("[Admin] Geçici şifre RPC hatası:", err);
                fail(err.message || "Şifre değiştirilemedi.");
            } finally {
                button.disabled = false;
            }
        },

        // Yeni şifre yalnızca bu kutuda, yönetici sayfadan ayrılana ya da kutuyu kapatana kadar görünür.
        _showResult(data, password) {
            const box = $("tempPasswordResult");
            const loginUrl = window.location.origin + "/login";
            this._message = `Borsa oyunu için geçici şifren: ${password}\nGiriş: ${loginUrl}`;
            box.innerHTML = `
                <p>✅ <strong>${esc(data.name || data.email)}</strong> (${esc(data.email)}) için yeni şifre:</p>
                <p><code>${esc(password)}</code></p>
                <p class="field-hint">Bu şifreyi üyeye ilet. ${data.sessions_closed ? "Üyenin açık kalmış oturumları kapatıldı." : "Üyenin açık oturumları kapatılamadı; eski oturumlar en geç bir saat içinde kendiliğinden düşer."}</p>
                <div class="admin-btn-pair">
                    <button type="button" class="submit-btn" data-temp-password-copy>📋 Mesajı Kopyala</button>
                    <button type="button" class="reset-btn" data-temp-password-clear>Kapat</button>
                </div>`;
            box.style.display = "block";
            box.querySelector("[data-temp-password-copy]").addEventListener("click", () => this.copy());
            box.querySelector("[data-temp-password-clear]").addEventListener("click", () => this.clear());
        },

        async copy() {
            if (!this._message) return;
            try {
                await navigator.clipboard.writeText(this._message);
                ok("Mesaj kopyalandı; üyeye yapıştırıp gönderebilirsin.");
            } catch (_) {
                fail("Otomatik kopyalanamadı; şifreyi kutudan elle kopyalayabilirsin.");
            }
        },

        clear() {
            this._message = "";
            const box = $("tempPasswordResult");
            box.style.display = "none";
            box.innerHTML = "";
        },

        wire() {
            const form = $("tempPasswordForm");
            if (!form) return;
            form.addEventListener("submit", (e) => { e.preventDefault(); this.submit(); });
            $("tempPasswordGenerate").addEventListener("click", () => {
                $("tempPasswordValue").value = this.generate();
            });
        },
    };

    window.AdminPassword = AdminPassword;
    document.addEventListener("DOMContentLoaded", () => AdminPassword.wire());
})();
