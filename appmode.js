/* Telefona kurulmuş uygulama görünümü: site ana ekrandan açılınca (tam ekran) gerçek uygulamalar gibi
   alt sekme çubuğu çıkar: Piyasa, Cüzdan, Haberler, Sıralama, Menü. Üstteki düğmeler gizlenir; tema, SSS,
   öneri ve çıkış menünün başına taşınır. Tarayıcıdan girildiğinde site hiç değişmez. */
(function () {
    const standalone =
        (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) || window.navigator.standalone === true;
    // Denemek için: adresin sonuna ?uygulama=1 eklenirse tarayıcıda da uygulama görünümü açılır.
    const forced = /[?&]uygulama=1\b/.test(location.search);
    if (!standalone && !forced) return;
    document.documentElement.classList.add("app-mode");

    const $ = (id) => document.getElementById(id);
    const click = (sel) => { const el = typeof sel === "string" ? document.querySelector(sel) : sel; if (el) el.click(); return Boolean(el); };
    const signedIn = () => Boolean(window.BorsaFirebase && BorsaFirebase.currentUser && BorsaFirebase.currentUser());
    const drawerOpen = () => document.body.classList.contains("drawer-open");

    function openSidebar(tab) {
        if (!drawerOpen()) click("#sidebarToggle");
        if (tab) click(`.sidebar-tab[data-tab="${tab}"]`);
    }
    function closeAll() {
        if (drawerOpen()) click("#sidebarCloseBtn");
        document.querySelectorAll(".modal-backdrop").forEach(m => {
            if (m.style.display === "flex") { const x = m.querySelector(".modal-close"); if (x) x.click(); }
        });
        const news = $("newsModal");
        if (news && news.getAttribute("aria-hidden") === "false") click("#closeNewsModal") || click("#newsModal [data-close-news]");
    }

    const TABS = [
        { id: "market", icon: "📈", label: "Piyasa", run: () => { closeAll(); window.scrollTo({ top: 0, behavior: "smooth" }); } },
        { id: "wallet", icon: "👛", label: "Cüzdan", run: () => { closeAll(); if (signedIn()) click("#portfolioBtn"); else location.href = "login.html"; } },
        { id: "news", icon: "📰", label: "Haberler", run: () => { closeAll(); click("[data-open-news]") || click("#openNewsModal"); } },
        { id: "rank", icon: "🏆", label: "Sıralama", run: () => openSidebar("leaderboard") },
        { id: "menu", icon: "☰", label: "Menü", run: () => openSidebar(null) },
    ];

    function buildTabbar() {
        const nav = document.createElement("nav");
        nav.className = "app-tabbar";
        nav.setAttribute("aria-label", "Ana menü");
        nav.innerHTML = TABS.map(t => `
            <button type="button" class="app-tab${t.id === "market" ? " app-tab--active" : ""}" data-app-tab="${t.id}">
                <span class="app-tab-icon" aria-hidden="true">${t.icon}</span>
                <span class="app-tab-label">${t.label}</span>
            </button>`).join("");
        document.body.appendChild(nav);
        nav.querySelectorAll("[data-app-tab]").forEach(b => {
            b.addEventListener("click", () => {
                const t = TABS.find(x => x.id === b.dataset.appTab);
                nav.querySelectorAll(".app-tab").forEach(x => x.classList.toggle("app-tab--active", x === b));
                if (navigator.vibrate) { try { navigator.vibrate(8); } catch (e) {} }
                t.run();
                // Pencere ya da menü kapanınca vurgu Piyasa'ya döner.
                setTimeout(() => watchBack(nav), 300);
            });
        });
    }

    let backTimer = null;
    function watchBack(nav) {
        clearInterval(backTimer);
        backTimer = setInterval(() => {
            const anyOpen = drawerOpen()
                || [...document.querySelectorAll(".modal-backdrop")].some(m => m.style.display === "flex")
                || ($("newsModal") && $("newsModal").getAttribute("aria-hidden") === "false");
            if (!anyOpen) {
                clearInterval(backTimer);
                nav.querySelectorAll(".app-tab").forEach(x => x.classList.toggle("app-tab--active", x.dataset.appTab === "market"));
            }
        }, 400);
    }

    // Menünün başına: tema, SSS, öneri, giriş/çıkış (üstteki gizlenen düğmelerin yerine).
    function buildMenuActions() {
        const drawer = $("sidebarDrawer");
        if (!drawer || $("appMenuActions")) return;
        const box = document.createElement("div");
        box.id = "appMenuActions";
        box.className = "app-menu-actions";
        box.innerHTML = `
            <button type="button" data-app-act="theme"><span>🌗</span>Tema</button>
            <button type="button" data-app-act="faq"><span>❓</span>SSS</button>
            <button type="button" data-app-act="feedback"><span>💡</span>Öneri</button>
            <button type="button" data-app-act="account"><span id="appAccountIcon">🔑</span><b id="appAccountLabel">Giriş</b></button>`;
        const tabs = drawer.querySelector(".sidebar-tabs");
        drawer.insertBefore(box, tabs);
        box.querySelector('[data-app-act="theme"]').addEventListener("click", () => {
            click($("themeToggleUser") && $("userNav").style.display !== "none" ? "#themeToggleUser" : "#themeToggleGuest");
        });
        box.querySelector('[data-app-act="faq"]').addEventListener("click", () => { closeAll(); click("#faqBtn"); });
        box.querySelector('[data-app-act="feedback"]').addEventListener("click", () => { closeAll(); click("#feedbackBtn"); });
        box.querySelector('[data-app-act="account"]').addEventListener("click", () => {
            if (signedIn()) { if (confirm("Çıkış yapılsın mı?")) click("#logoutBtn"); }
            else location.href = "login.html";
        });
        const refresh = () => {
            $("appAccountIcon").textContent = signedIn() ? "🚪" : "🔑";
            $("appAccountLabel").textContent = signedIn() ? "Çıkış" : "Giriş";
        };
        refresh();
        if (window.BorsaFirebase && BorsaFirebase.onChange) BorsaFirebase.onChange(refresh);
    }

    function shortTitle() {
        const t = document.querySelector(".logo-text");
        if (t) t.textContent = "ZBEÜ Borsa";
    }

    document.addEventListener("DOMContentLoaded", () => {
        buildTabbar();
        buildMenuActions();
        shortTitle();
    });
})();
