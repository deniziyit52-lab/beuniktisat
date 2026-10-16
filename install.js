/* Telefona uygulama gibi yükleme.
   - Android / bilgisayar (Chrome, Edge): tarayıcının "yükle" penceresi tek düğmeyle açılır.
   - iPhone / iPad: Apple tek dokunuşla yüklemeye izin vermez. Bunun yerine tarayıcıya ve iOS sürümüne göre
     doğru adımları gösteren, hareketli bir rehber açılır; ok, dokunulacak düğmenin gerçek yerini gösterir.
   - Instagram, Facebook, TikTok gibi uygulamaların içindeki tarayıcı: Android'de "Chrome'da aç",
     iPhone'da "Bağlantıyı kopyala".
   Ne zaman gösterilir: telefonda alt bilgi kutusu (4 sn sonra, kapatılırsa 14 gün gösterilmez), piyasa listesinin
   üstünde küçük şerit, giriş yapınca rehber bir kez kendiliğinden, adres ?kur=1 ile açılınca (QR kod) hemen.
   Zaten uygulama olarak açılmışsa hiçbir şey gösterilmez. */
(function () {
    const $ = (id) => document.getElementById(id);
    const DISMISS_KEY = "borsa-install-dismissed";
    const AUTO_GUIDE_KEY = "borsa-install-guide-auto";
    const standalone = () =>
        (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) || window.navigator.standalone === true;
    const ua = navigator.userAgent || "";
    const isIPad = /iPad/i.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
    const isIOS = /iPhone|iPod/i.test(ua) || isIPad;
    const isAndroid = /Android/i.test(ua);
    const inApp = /Instagram|FBAN|FBAV|FB_IAB|FBIOS|Line\/|TikTok|musical_ly|Snapchat|LinkedInApp|Twitter|GSA\//i.test(ua);
    const iosChrome = isIOS && /CriOS/i.test(ua);
    const iosOther = isIOS && /FxiOS|EdgiOS|OPiOS|YaBrowser|DuckDuckGo/i.test(ua);
    const iosVersion = (() => {
        const m = ua.match(/OS (\d+)[._]\d/);
        const v = m ? Number(m[1]) : 0;
        // iPadOS bazen kendini Mac olarak tanıtır; Safari sürümü de bakılabilecek bir ipucu.
        const s = ua.match(/Version\/(\d+)/);
        return Math.max(v, s ? Number(s[1]) : 0);
    })();
    const isTouch = window.matchMedia && window.matchMedia("(pointer: coarse)").matches;
    let deferred = null;

    if ("serviceWorker" in navigator) {
        window.addEventListener("load", () => {
            navigator.serviceWorker.register("/sw.js").catch(() => {});
        });
    }

    const ICON = {
        share: '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path d="M12 3v12M7.5 7.5 12 3l4.5 4.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/><path d="M8 10H6a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-9a1 1 0 0 0-1-1h-2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
        add: '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><rect x="3.5" y="3.5" width="17" height="17" rx="4" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 8v8M8 12h8" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
        more: '<span class="install-dots">•••</span>',
        addText: '<span class="install-step-word">Ekle</span>',
    };

    // Telefona ve tarayıcıya göre adımlar. "spot": hareketli gösterimde vurgulanan yer, "arrow": okun yeri.
    function plan() {
        if (iosChrome || iosOther) {
            return {
                arrow: "top-right",
                steps: [
                    { ico: ICON.share, spot: "top-right", html: "Adres çubuğunun sağındaki <b>Paylaş</b> düğmesine dokun.", hint: "Görmüyorsan sağ alttaki ••• menüsünde <b>Paylaş</b>'ı bul." },
                    { ico: ICON.add, spot: "sheet", html: "<b>Ana Ekrana Ekle</b>'ye dokun.", hint: "Listede yoksa aşağı kaydır." },
                    { ico: ICON.addText, spot: "top-right", html: "Sağ üstteki <b>Ekle</b>'ye dokun. Bitti!" },
                ],
            };
        }
        if (isIPad) {
            return {
                arrow: "top-right",
                steps: [
                    { ico: ICON.share, spot: "top-right", html: "Sağ üstteki <b>Paylaş</b> düğmesine dokun." },
                    { ico: ICON.add, spot: "sheet", html: "<b>Ana Ekrana Ekle</b>'ye dokun.", hint: "Listede yoksa aşağı kaydır." },
                    { ico: ICON.addText, spot: "top-right", html: "Sağ üstteki <b>Ekle</b>'ye dokun. Bitti!" },
                ],
            };
        }
        if (iosVersion >= 26) {
            return {
                arrow: "bottom-right",
                steps: [
                    { ico: ICON.more, spot: "bottom-right", html: "Sağ alttaki <b>•••</b> düğmesine dokun." },
                    { ico: ICON.share, spot: "menu", html: "Açılan menüde <b>Paylaş</b>'a dokun." },
                    { ico: ICON.add, spot: "sheet", html: "<b>Ana Ekrana Ekle</b>'ye dokun.", hint: "Görmüyorsan listeyi kaydır ya da <b>Daha Fazla</b>'ya dokun." },
                    { ico: ICON.addText, spot: "top-right", html: "Sağ üstteki <b>Ekle</b>'ye dokun. Bitti!" },
                ],
            };
        }
        return {
            arrow: "bottom-center",
            steps: [
                { ico: ICON.share, spot: "bottom-center", html: "Ekranın altındaki <b>Paylaş</b> düğmesine dokun." },
                { ico: ICON.add, spot: "sheet", html: "Listeyi biraz kaydırıp <b>Ana Ekrana Ekle</b>'ye dokun." },
                { ico: ICON.addText, spot: "top-right", html: "Sağ üstteki <b>Ekle</b>'ye dokun. Bitti!" },
            ],
        };
    }

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
        renderInline();
        return true;
    }

    function openInBrowser() {
        if (isAndroid) {
            const u = new URL(location.href);
            location.href = `intent://${u.host}${u.pathname}${u.search}#Intent;scheme=https;package=com.android.chrome;S.browser_fallback_url=${encodeURIComponent(u.href)};end`;
        }
    }
    async function copyLink(btn) {
        const url = location.origin + "/?kur=1";
        try { await navigator.clipboard.writeText(url); } catch (e) {
            const t = document.createElement("textarea");
            t.value = url; document.body.appendChild(t); t.select();
            try { document.execCommand("copy"); } catch (_) {}
            t.remove();
        }
        if (btn) btn.textContent = "Kopyalandı ✓";
    }

    // Hareketli rehber: küçük bir telefon ekranında parmak sırayla dokunulacak yeri gösterir,
    // yandaki adım listesi de aynı anda vurgulanır.
    let guideTimer = null;
    function showGuide() {
        if ($("installGuide")) return;
        if (inApp || (!isIOS && deferred)) {
            // iPhone dışı ya da uygulama içi tarayıcı: rehber yerine uygun düğme.
            if (deferred) return promptInstall();
        }
        const p = plan();
        const el = document.createElement("div");
        el.id = "installGuide";
        el.className = "install-guide";
        el.setAttribute("role", "dialog");
        el.setAttribute("aria-label", "Ana ekrana ekleme rehberi");
        el.innerHTML = `
            <div class="install-guide-card">
                <button type="button" class="install-banner-close" data-guide-close aria-label="Kapat">×</button>
                <strong class="install-guide-title">${p.steps.length} dokunuşta telefonuna ekle</strong>
                <div class="install-mock" aria-hidden="true">
                    <div class="install-mock-screen">
                        <div class="install-mock-bar install-mock-bar--top"><span class="install-mock-url">beuniktisat.vercel.app</span><span class="install-mock-btn" data-spot="top-right">${p.arrow === "top-right" ? ICON.share : '<span class="install-step-word">Ekle</span>'}</span></div>
                        <img src="/icons/icon-192.png" alt="" class="install-mock-app">
                        <div class="install-mock-sheet" data-spot="sheet">${ICON.add}<span>Ana Ekrana Ekle</span></div>
                        <div class="install-mock-menu" data-spot="menu">${ICON.share}<span>Paylaş</span></div>
                        <div class="install-mock-bar install-mock-bar--bottom">
                            <span class="install-mock-btn" data-spot="bottom-left">‹</span>
                            <span class="install-mock-btn" data-spot="bottom-center">${ICON.share}</span>
                            <span class="install-mock-btn" data-spot="bottom-right">${ICON.more}</span>
                        </div>
                        <span class="install-mock-finger">👆</span>
                    </div>
                </div>
                <ol class="install-steps">
                    ${p.steps.map((s, i) => `
                        <li data-step="${i}"><span class="install-step-ico">${s.ico}</span>
                            <span class="install-step-text"><span>${s.html}</span>${s.hint ? `<small>${s.hint}</small>` : ""}</span></li>`).join("")}
                </ol>
                <button type="button" class="install-banner-btn install-guide-ok" data-guide-close>Anladım</button>
            </div>
            <div class="install-guide-arrow install-guide-arrow--${p.arrow}" aria-hidden="true">${p.arrow.startsWith("top") ? "⬆" : "⬇"}</div>`;
        document.body.appendChild(el);
        const close = () => { clearInterval(guideTimer); el.remove(); };
        el.querySelectorAll("[data-guide-close]").forEach(b => b.addEventListener("click", close));
        el.addEventListener("click", (e) => { if (e.target === el) close(); });

        // Canlandırma: her adımda ilgili yer parlar, parmak oraya gider.
        const screen = el.querySelector(".install-mock-screen");
        const finger = el.querySelector(".install-mock-finger");
        let i = 0;
        const step = () => {
            const s = p.steps[i];
            el.querySelectorAll(".install-steps li").forEach(li => li.classList.toggle("is-active", Number(li.dataset.step) === i));
            screen.classList.toggle("show-menu", s.spot === "menu");
            screen.classList.toggle("show-sheet", s.spot === "sheet");
            if (s.spot === "top-right") screen.querySelector('[data-spot="top-right"]').innerHTML = s.ico;
            screen.querySelectorAll("[data-spot]").forEach(n => n.classList.toggle("is-spot", n.dataset.spot === s.spot));
            const target = screen.querySelector(`[data-spot="${s.spot}"]`);
            if (target) {
                const a = screen.getBoundingClientRect(), b = target.getBoundingClientRect();
                finger.style.left = `${b.left - a.left + b.width / 2 - 10}px`;
                finger.style.top = `${b.top - a.top + b.height / 2 - 4}px`;
            }
            i = (i + 1) % p.steps.length;
        };
        step();
        guideTimer = setInterval(step, 1900);
    }

    function hideBanner() {
        const b = $("installBanner");
        if (b) b.remove();
    }

    function content() {
        if (inApp) {
            return {
                text: isAndroid
                    ? "Uygulama olarak eklemek için bu sayfayı Chrome'da aç."
                    : "Bu uygulamanın içinden ana ekrana eklenemiyor. Bağlantıyı kopyalayıp Safari'ye yapıştır ya da sağ üstteki ••• menüsünden \"Tarayıcıda aç\"a dokun.",
                button: isAndroid ? "Chrome'da aç" : "Bağlantıyı kopyala",
                action: isAndroid ? () => openInBrowser() : (btn) => copyLink(btn),
            };
        }
        if (isIOS) return { text: `Ana ekrandan uygulama gibi aç. ${plan().steps.length} dokunuş, 10 saniye.`, button: "Göster", action: () => showGuide() };
        return { text: "Ana ekrandan uygulama gibi tek dokunuşla aç.", button: "Yükle", action: () => promptInstall() };
    }
    const offerable = () => !standalone() && (inApp || isIOS || Boolean(deferred));

    function showBanner() {
        if (!offerable() || dismissedRecently() || !isTouch || $("installBanner") || $("installGuide")) return;
        const c = content();
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

    // Piyasa listesinin üstünde kalıcı küçük şerit (yalnızca telefonda, uygulama değilken).
    function renderInline() {
        const host = document.querySelector(".left-panel .section-header");
        let el = $("installInline");
        if (!host || !isTouch || !offerable()) { if (el) el.remove(); return; }
        if (!el) {
            el = document.createElement("button");
            el.type = "button";
            el.id = "installInline";
            el.className = "install-inline";
            host.parentNode.insertBefore(el, host);
            el.addEventListener("click", (e) => content().action(e.currentTarget));
        }
        el.innerHTML = `<img src="/icons/icon-192.png" alt=""><span><b>Uygulamayı telefonuna ekle</b><small>${inApp ? "Önce tarayıcıda aç" : isIOS ? "Nasıl yapılır? Dokun, göstereyim" : "Tek dokunuşla yükle"}</small></span><em>›</em>`;
    }

    // Kenar menüdeki kalıcı kutu.
    function renderMenuBox() {
        const box = $("installBox");
        if (!box) return;
        if (!offerable()) { box.hidden = true; return; }
        box.hidden = false;
        const c = content();
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
        renderInline();
        setTimeout(showBanner, 4000);
    });
    window.addEventListener("appinstalled", () => {
        deferred = null;
        hideBanner();
        renderMenuBox();
        renderInline();
    });

    document.addEventListener("DOMContentLoaded", () => {
        renderMenuBox();
        renderInline();
        if (standalone()) return;
        // QR koddan gelindiyse rehber hemen açılır.
        if (/[?&]kur=1\b/.test(location.search) && isIOS && !inApp) {
            setTimeout(showGuide, 800);
            return;
        }
        if (isIOS || inApp) setTimeout(showBanner, 4000);
        // Giriş yapınca (en motive olunan an) iPhone'da rehber bir kez kendiliğinden açılır.
        if (isIOS && !inApp && window.BorsaFirebase && BorsaFirebase.onChange) {
            BorsaFirebase.onChange((user) => {
                if (!user) return;
                try { if (localStorage.getItem(AUTO_GUIDE_KEY)) return; localStorage.setItem(AUTO_GUIDE_KEY, "1"); } catch (e) { return; }
                setTimeout(() => { hideBanner(); showGuide(); }, 2500);
            });
        }
    });

    window.BorsaInstall = { showGuide, promptInstall };
})();
