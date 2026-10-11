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
