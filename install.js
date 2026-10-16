/* Telefona uygulama gibi yükleme.
   - Android / bilgisayar (Chrome, Edge): tarayıcının "yükle" penceresi tek düğmeyle açılır.
   - iPhone / iPad (Safari): Apple düğmeye izin vermez; resimli 3 adımlı rehber ve Paylaş düğmesini gösteren ok.
   - Instagram, Facebook, TikTok gibi uygulamaların içindeki tarayıcıdan girildiyse yükleme orada mümkün değildir:
     Android'de "Chrome'da aç", iPhone'da "Bağlantıyı kopyala" gösterilir.
   Telefonda alt bilgi kutusu kendiliğinden bir kez çıkar; kapatılırsa 14 gün gösterilmez. Kenar menüdeki
   "📲 Telefona yükle" kutusu her zaman durur. Zaten uygulama olarak açılmışsa hiçbir şey gösterilmez. */
(function () {
    const $ = (id) => document.getElementById(id);
    const DISMISS_KEY = "borsa-install-dismissed";
    const standalone = () =>
        (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) || window.navigator.standalone === true;
    const ua = navigator.userAgent || "";
    const isIOS = /iPhone|iPad|iPod/i.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
    const isAndroid = /Android/i.test(ua);
    const inApp = /Instagram|FBAN|FBAV|FB_IAB|FBIOS|Line\/|TikTok|musical_ly|Snapchat|LinkedInApp|Twitter|GSA\//i.test(ua);
    const isTouch = window.matchMedia && window.matchMedia("(pointer: coarse)").matches;
    let deferred = null;

    if ("serviceWorker" in navigator) {
        window.addEventListener("load", () => {
            navigator.serviceWorker.register("/sw.js").catch(() => {});
        });
    }

    const SHARE_SVG = '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M12 3v12M7.5 7.5 12 3l4.5 4.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M8 10H6a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-9a1 1 0 0 0-1-1h-2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';
    const ADD_SVG = '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><rect x="3.5" y="3.5" width="17" height="17" rx="4" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 8v8M8 12h8" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>';

    function dismissedRecently() {
        try {
            const t = Number(localStorage.getItem(DISMISS_KEY) || 0);
            return t && Date.now() - t < 14 * 24 * 3600 * 1000;
        } catch (e) { return false; }
    }
    function dismiss() {
        try { localStorage.setItem(DISMISS_KEY, String(Date.now())); } catch (e) {}
        hideBanner();
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

    // Uygulama içi tarayıcıdan gerçek tarayıcıya geçiş
    function openInBrowser() {
        if (isAndroid) {
            const u = new URL(location.href);
            location.href = `intent://${u.host}${u.pathname}${u.search}#Intent;scheme=https;package=com.android.chrome;S.browser_fallback_url=${encodeURIComponent(u.href)};end`;
        }
    }
    async function copyLink(btn) {
        const url = location.origin + "/";
        try { await navigator.clipboard.writeText(url); } catch (e) {
            const t = document.createElement("textarea");
            t.value = url; document.body.appendChild(t); t.select();
            try { document.execCommand("copy"); } catch (_) {}
            t.remove();
        }
        if (btn) btn.textContent = "Kopyalandı ✓";
    }

    // iPhone için resimli rehber
    function showGuide() {
        if ($("installGuide")) return;
        const el = document.createElement("div");
        el.id = "installGuide";
        el.className = "install-guide";
        el.setAttribute("role", "dialog");
        el.setAttribute("aria-label", "Ana ekrana ekleme rehberi");
        el.innerHTML = `
            <div class="install-guide-card">
                <button type="button" class="install-banner-close" data-guide-close aria-label="Kapat">×</button>
                <img src="/icons/icon-192.png" alt="" class="install-guide-icon">
                <strong class="install-guide-title">3 adımda telefonuna ekle</strong>
                <ol class="install-steps">
                    <li><span class="install-step-ico">${SHARE_SVG}</span><span class="install-step-text"><span>Ekranın altındaki <b>Paylaş</b> düğmesine dokun.</span><small>Yeni iPhone'larda önce sağ alttaki <b>•••</b> düğmesine, sonra <b>Paylaş</b>'a dokun.</small></span></li>
                    <li><span class="install-step-ico">${ADD_SVG}</span><span class="install-step-text"><span>Açılan listeyi biraz kaydır ve <b>Ana Ekrana Ekle</b>'ye dokun.</span></span></li>
                    <li><span class="install-step-ico install-step-ico--text">Ekle</span><span class="install-step-text"><span>Sağ üstteki <b>Ekle</b>'ye dokun. Simge ana ekranına gelir!</span></span></li>
                </ol>
                <button type="button" class="install-banner-btn install-guide-ok" data-guide-close>Anladım</button>
            </div>
            <div class="install-guide-arrow" aria-hidden="true">⬇</div>`;
        document.body.appendChild(el);
        el.querySelectorAll("[data-guide-close]").forEach(b => b.addEventListener("click", () => el.remove()));
        el.addEventListener("click", (e) => { if (e.target === el) el.remove(); });
    }

    function hideBanner() {
        const b = $("installBanner");
        if (b) b.remove();
    }

    function bannerContent() {
        if (inApp) {
            return {
                text: isAndroid
                    ? "Uygulama olarak eklemek için bu sayfayı Chrome'da aç."
                    : "Bu uygulamanın içinden ana ekrana eklenemiyor. Bağlantıyı kopyalayıp Safari'ye yapıştır ya da sağ üstteki ••• menüsünden \"Tarayıcıda aç\"a dokun.",
                button: isAndroid ? "Chrome'da aç" : "Bağlantıyı kopyala",
                action: isAndroid ? () => openInBrowser() : (btn) => copyLink(btn),
            };
        }
        if (isIOS) return { text: "Ana ekrandan uygulama gibi tek dokunuşla aç. 3 kolay adım.", button: "Nasıl?", action: () => showGuide() };
        return { text: "Ana ekrandan uygulama gibi tek dokunuşla aç.", button: "Yükle", action: () => promptInstall() };
    }

    function showBanner() {
        if (standalone() || dismissedRecently() || !isTouch || $("installBanner")) return;
        if (!inApp && !isIOS && !deferred) return;
        const c = bannerContent();
        const el = document.createElement("div");
        el.id = "installBanner";
        el.className = "install-banner";
        el.setAttribute("role", "dialog");
        el.setAttribute("aria-label", "Telefona yükle");
        el.innerHTML = `
            <img src="/icons/icon-192.png" alt="" class="install-banner-icon">
            <div class="install-banner-text">
                <strong>ZBEÜ Borsa'yı telefonuna ekle</strong>
                <span>${c.text}</span>
            </div>
            <button type="button" class="install-banner-btn" id="installBannerBtn">${c.button}</button>
            <button type="button" class="install-banner-close" id="installBannerClose" aria-label="Kapat">×</button>`;
        document.body.appendChild(el);
        requestAnimationFrame(() => el.classList.add("install-banner--show"));
        $("installBannerBtn").addEventListener("click", (e) => c.action(e.currentTarget));
        $("installBannerClose").addEventListener("click", dismiss);
    }

    // Kenar menüdeki kalıcı kutu: kapatılan alt bilgiye sonradan ulaşmak için.
    function renderMenuBox() {
        const box = $("installBox");
        if (!box) return;
        if (standalone() || (!inApp && !isIOS && !deferred)) { box.hidden = true; return; }
        box.hidden = false;
        const c = bannerContent();
        $("installBoxText").textContent = c.text;
        const btn = $("installBoxBtn");
        btn.hidden = false;
        btn.textContent = c.button;
        btn.onclick = (e) => c.action(e.currentTarget);
    }

    window.addEventListener("beforeinstallprompt", (e) => {
        e.preventDefault();
        deferred = e;
        renderMenuBox();
        setTimeout(showBanner, 4000);
    });
    window.addEventListener("appinstalled", () => {
        deferred = null;
        hideBanner();
        renderMenuBox();
    });

    document.addEventListener("DOMContentLoaded", () => {
        renderMenuBox();
        if (isIOS || inApp) setTimeout(showBanner, 4000);
    });

    window.BorsaInstall = { showGuide, promptInstall };
})();
