/* Telefona uygulama gibi yükleme.
   - Android / bilgisayar (Chrome, Edge): tarayıcının "yükle" penceresi düğmeyle açılır.
   - iPhone / iPad (Safari): Apple düğmeye izin vermez; "Paylaş → Ana Ekrana Ekle" adımları gösterilir.
   Telefonda bir kez alt bilgi kutusu çıkar; kapatılırsa 14 gün gösterilmez. Kenar menüdeki "📲 Telefona yükle"
   kutusu her zaman durur. Zaten uygulama olarak açılmışsa hiçbir şey gösterilmez. */
(function () {
    const $ = (id) => document.getElementById(id);
    const DISMISS_KEY = "borsa-install-dismissed";
    const standalone = () =>
        (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) || window.navigator.standalone === true;
    const ua = navigator.userAgent || "";
    const isIOS = /iPhone|iPad|iPod/i.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
    const isTouch = window.matchMedia && window.matchMedia("(pointer: coarse)").matches;
    let deferred = null;

    if ("serviceWorker" in navigator) {
        window.addEventListener("load", () => {
            navigator.serviceWorker.register("/sw.js").catch(() => {});
        });
    }

    const iosSteps =
        'Safari\'de alttaki <b>Paylaş</b> düğmesine <span class="install-share" aria-hidden="true">⬆︎</span> bas, ' +
        'listeyi kaydırıp <b>Ana Ekrana Ekle</b>\'ye, sonra <b>Ekle</b>\'ye dokun.';

    function dismissedRecently() {
        try {
            const t = Number(localStorage.getItem(DISMISS_KEY) || 0);
            return t && Date.now() - t < 14 * 24 * 3600 * 1000;
        } catch (e) { return false; }
    }

    async function promptInstall() {
        if (!deferred) return false;
        deferred.prompt();
        try { await deferred.userChoice; } catch (e) {}
        deferred = null;
        hideBanner();
        renderMenuBox();
        return true;
    }

    function hideBanner() {
        const b = $("installBanner");
        if (b) b.remove();
    }

    function showBanner() {
        if (standalone() || dismissedRecently() || !isTouch || $("installBanner")) return;
        if (!isIOS && !deferred) return;
        const el = document.createElement("div");
        el.id = "installBanner";
        el.className = "install-banner";
        el.setAttribute("role", "dialog");
        el.setAttribute("aria-label", "Telefona yükle");
        el.innerHTML = `
            <img src="/icons/icon-192.png" alt="" class="install-banner-icon">
            <div class="install-banner-text">
                <strong>ZBEÜ Borsa'yı telefonuna ekle</strong>
                <span>${isIOS ? iosSteps : "Ana ekrandan uygulama gibi tek dokunuşla aç."}</span>
            </div>
            ${isIOS ? "" : '<button type="button" class="install-banner-btn" id="installBannerBtn">Yükle</button>'}
            <button type="button" class="install-banner-close" id="installBannerClose" aria-label="Kapat">×</button>`;
        document.body.appendChild(el);
        requestAnimationFrame(() => el.classList.add("install-banner--show"));
        if ($("installBannerBtn")) $("installBannerBtn").addEventListener("click", promptInstall);
        $("installBannerClose").addEventListener("click", () => {
            try { localStorage.setItem(DISMISS_KEY, String(Date.now())); } catch (e) {}
            hideBanner();
        });
    }

    // Kenar menüdeki kalıcı kutu: kapatılan alt bilgiye sonradan ulaşmak için.
    function renderMenuBox() {
        const box = $("installBox");
        if (!box) return;
        if (standalone() || (!isIOS && !deferred)) { box.hidden = true; return; }
        box.hidden = false;
        $("installBoxText").innerHTML = isIOS ? iosSteps : "Ana ekrana simge olarak eklenir; uygulama gibi tam ekran açılır.";
        $("installBoxBtn").hidden = isIOS;
    }

    window.addEventListener("beforeinstallprompt", (e) => {
        e.preventDefault();
        deferred = e;
        renderMenuBox();
        setTimeout(showBanner, 8000);
    });
    window.addEventListener("appinstalled", () => {
        deferred = null;
        hideBanner();
        renderMenuBox();
    });

    document.addEventListener("DOMContentLoaded", () => {
        if ($("installBoxBtn")) $("installBoxBtn").addEventListener("click", promptInstall);
        renderMenuBox();
        if (isIOS) setTimeout(showBanner, 8000);
    });
})();
