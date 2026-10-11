/* Gizli imza: logodaki ₺ simgesine kısa sürede beş kez tıklanınca küçük bir jenerik kartı açılır. */
(function () {
    const CLICKS_NEEDED = 5;
    const WINDOW_MS = 3000;
    const LINKEDIN = "https://www.linkedin.com/in/deniz-iyit-9a0366390/";
    let clicks = [];

    function show() {
        if (document.getElementById("signatureCard")) return;
        const overlay = document.createElement("div");
        overlay.id = "signatureCard";
        overlay.className = "signature-overlay";
        overlay.setAttribute("role", "dialog");
        overlay.setAttribute("aria-label", "Jenerik");
        overlay.innerHTML = `
            <div class="signature-card">
                <div class="signature-symbol" aria-hidden="true">₺</div>
                <div class="signature-kicker">Gizli jeneriği buldun</div>
                <div class="signature-role">Tasarım ve geliştirme</div>
                <div class="signature-name">Deniz İyit</div>
                <div class="signature-reward" id="signatureReward" role="status"></div>
                <a class="signature-link" href="${LINKEDIN}" target="_blank" rel="noopener noreferrer">LinkedIn'de bağlantı kur ↗</a>
                <div class="signature-hint">Kapatmak için boş bir yere tıkla</div>
            </div>`;
        document.body.appendChild(overlay);
        const close = () => {
            overlay.classList.add("is-leaving");
            setTimeout(() => overlay.remove(), 300);
            document.removeEventListener("keydown", onKey);
        };
        const onKey = (e) => { if (e.key === "Escape") close(); };
        overlay.addEventListener("click", (e) => { if (!e.target.closest(".signature-link")) close(); });
        document.addEventListener("keydown", onKey);
        claimReward();
    }

    // Ödül: oyuncu başına bir kez, sunucuda verilir (claim_secret_reward).
    async function claimReward() {
        const el = document.getElementById("signatureReward");
        if (!el) return;
        const fb = window.BorsaFirebase;
        const user = fb && fb.currentUser ? fb.currentUser() : null;
        if (!user || !window.sb || !window.sb.rpc) {
            el.textContent = "🎁 Giriş yaptıktan sonra jeneriği yeniden açarsan 10.000 ₺ ödülün seni bekliyor.";
            return;
        }
        try {
            const { data, error } = await window.sb.rpc("claim_secret_reward");
            if (error || !data) return;
            const amount = Number(data.reward || 0).toLocaleString("tr-TR");
            if (data.claimed) {
                el.classList.add("is-new");
                el.textContent = `🎁 Ödülün: +${amount} ₺ bakiyene eklendi!`;
                const doc = fb.currentUserData ? fb.currentUserData() : null;
                if (doc && data.balance != null) {
                    doc.balance = Number(data.balance);
                    if (typeof fb._emit === "function") fb._emit();
                }
                if (window.BorsaBadges) window.BorsaBadges.scheduleCheck(4500);
            } else {
                el.textContent = `Bu ödülü (${amount} ₺) daha önce almıştın.`;
            }
        } catch (_) {}
    }

    document.addEventListener("click", (e) => {
        const symbol = e.target.closest(".logo-symbol");
        if (!symbol) return;
        // Logo bir bağlantının içindeyse (başka sayfaya götürüyorsa) sayılmaz.
        if (symbol.closest("a[href]")) return;
        const now = Date.now();
        clicks = clicks.filter(t => now - t < WINDOW_MS);
        clicks.push(now);
        if (clicks.length >= CLICKS_NEEDED) {
            clicks = [];
            show();
        }
    });
})();
