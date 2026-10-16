/* Telefon bildirimleri (Web Push): oyuncu menüden açar ya da kapatır. Açınca tarayıcı izin ister, cihazın
   bildirim adresi save_push_subscription ile kaydedilir ve birkaç saniye içinde deneme bildirimi gelir.
   iPhone'da bildirim yalnızca site ana ekrana eklenip oradan açılınca çalışır (iOS 16.4+). */
(function () {
    const $ = (id) => document.getElementById(id);
    // Herkese açık anahtar; eşi olan gizli anahtar yalnızca Supabase'in gizli ayarlarındadır.
    const VAPID_PUBLIC_KEY = "BGidrTLQqxn3CQAjlLrZH0bdtbnuU0CMW7F_B-toLy1gyYnf4SIVCZU8PPPY6dlYVAm9GKqOArIkLfClEoi3sPg";

    const supported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
    const ua = navigator.userAgent || "";
    const isIOS = /iPhone|iPad|iPod/i.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
    const standalone = () =>
        (window.matchMedia && window.matchMedia("(display-mode: standalone)").matches) || window.navigator.standalone === true;
    const signedIn = () => Boolean(window.BorsaFirebase && BorsaFirebase.currentUser && BorsaFirebase.currentUser());

    function keyBytes(base64url) {
        const pad = "=".repeat((4 - (base64url.length % 4)) % 4);
        const raw = atob((base64url + pad).replace(/-/g, "+").replace(/_/g, "/"));
        return Uint8Array.from(raw, (c) => c.charCodeAt(0));
    }

    const BorsaPush = {
        _uid: null,
        on: false,

        async currentSub() {
            if (!supported()) return null;
            const reg = await navigator.serviceWorker.ready;
            return reg.pushManager.getSubscription();
        },

        _feedback(msg, isError) {
            const el = $("pushPrefFeedback");
            if (!el) return;
            el.textContent = msg || "";
            el.classList.toggle("is-error", Boolean(isError));
        },

        async load() {
            const box = $("pushPrefBox");
            if (!box) return;
            if (!signedIn()) { box.style.display = "none"; return; }
            box.style.display = "";
            const toggle = $("pushPrefToggle");
            this._feedback("");
            if (isIOS && !standalone()) {
                toggle.checked = false;
                toggle.disabled = true;
                $("pushPrefHint").textContent = "iPhone'da bildirim için önce siteyi ana ekrana ekle (aşağıdaki \"Telefona yükle\"), sonra uygulamayı oradan açıp bu düğmeyi aç.";
                return;
            }
            if (!supported()) {
                toggle.checked = false;
                toggle.disabled = true;
                $("pushPrefHint").textContent = "Bu tarayıcı bildirimleri desteklemiyor. Telefonda Chrome ya da Safari kullan.";
                return;
            }
            toggle.disabled = false;
            $("pushPrefHint").textContent = "Bekleyen emrin gerçekleşince telefonuna bildirim gelsin.";
            try {
                const sub = await this.currentSub();
                let on = false;
                if (sub && Notification.permission === "granted") {
                    const { data } = await window.sb.rpc("has_push_subscription", { p_endpoint: sub.endpoint });
                    on = data === true;
                }
                this.on = on;
                toggle.checked = on;
                if (Notification.permission === "denied") {
                    this._feedback("Bildirim izni kapalı. Açmak için tarayıcı ya da telefon ayarlarından bu siteye bildirim izni ver.", true);
                }
                await this.autoSetup();
            } catch (e) {
                toggle.checked = false;
            }
        },

        // Telefona kurulmuş uygulamada bildirimler varsayılan olarak açıktır:
        // - izin zaten verilmişse ve bu cihaz kayıtlı değilse sormadan açılır;
        // - izin henüz sorulmamışsa ilk açılışta tek düğmelik pencere çıkar (telefonlar izni yalnızca
        //   bir dokunuşla istemeye izin verir; bu adım atlanamaz).
        // Menüden bilerek kapatan oyuncuya bir daha sorulmaz.
        async autoSetup() {
            if (!standalone() || this.on || !supported() || this._optedOut()) return;
            if (Notification.permission === "granted") {
                try { await this.enable(); } catch (e) {}
                return;
            }
            if (Notification.permission === "default") this.showPrompt();
        },

        _optedOut() {
            try { return localStorage.getItem("borsa-push-optout") === "1"; } catch (e) { return false; }
        },

        showPrompt() {
            if ($("pushPrompt")) return;
            try {
                const later = Number(localStorage.getItem("borsa-push-later") || 0);
                if (later && Date.now() - later < 3 * 24 * 3600 * 1000) return;
            } catch (e) {}
            const el = document.createElement("div");
            el.id = "pushPrompt";
            el.className = "push-prompt";
            el.setAttribute("role", "dialog");
            el.setAttribute("aria-label", "Bildirimleri aç");
            el.innerHTML = `
                <div class="push-prompt-card">
                    <img src="/icons/icon-192.png" alt="" class="push-prompt-icon">
                    <strong>Bildirimleri aç</strong>
                    <p>Emrin gerçekleşince, elindeki hisse sert oynayınca ve temettü yatınca haber verelim.</p>
                    <button type="button" class="push-prompt-yes" id="pushPromptYes">🔔 Aç</button>
                    <button type="button" class="push-prompt-no" id="pushPromptNo">Şimdi değil</button>
                    <small id="pushPromptMsg"></small>
                </div>`;
            document.body.appendChild(el);
            $("pushPromptYes").addEventListener("click", async () => {
                $("pushPromptYes").disabled = true;
                try {
                    await this.enable();
                    el.remove();
                    this._feedback("Açıldı. Birkaç saniye içinde bir deneme bildirimi gelecek.");
                } catch (err) {
                    $("pushPromptMsg").textContent = err.message || "Açılamadı.";
                    $("pushPromptYes").disabled = false;
                }
            });
            $("pushPromptNo").addEventListener("click", () => {
                try { localStorage.setItem("borsa-push-later", String(Date.now())); } catch (e) {}
                el.remove();
            });
        },

        // Menüdeki düğme ve emir verince çıkan kısayol bunu çağırır.
        async enable() {
            if (!supported()) throw new Error("Bu tarayıcı bildirimleri desteklemiyor.");
            const perm = await Notification.requestPermission();
            if (perm !== "granted") {
                throw new Error("İzin verilmedi. Telefon ya da tarayıcı ayarlarından bu siteye bildirim izni verebilirsin.");
            }
            const reg = await navigator.serviceWorker.ready;
            let sub = await reg.pushManager.getSubscription();
            if (!sub) {
                sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(VAPID_PUBLIC_KEY) });
            }
            const j = sub.toJSON();
            const { error } = await window.sb.rpc("save_push_subscription", {
                p_endpoint: j.endpoint, p_p256dh: j.keys && j.keys.p256dh, p_auth: j.keys && j.keys.auth,
            });
            if (error) throw error;
            this.on = true;
            if ($("pushPrefToggle")) $("pushPrefToggle").checked = true;
            return true;
        },

        async disable() {
            const sub = await this.currentSub();
            if (sub) {
                await window.sb.rpc("delete_push_subscription", { p_endpoint: sub.endpoint });
                try { await sub.unsubscribe(); } catch (e) {}
            }
            this.on = false;
        },

        // Emir verilince kısayol gösterilsin mi: destekleniyor, giriş yapılmış, henüz açık değil, izin reddedilmemiş.
        canOffer() {
            return signedIn() && supported() && !this.on && Notification.permission !== "denied" && !(isIOS && !standalone());
        },

        async toggle(on) {
            const toggle = $("pushPrefToggle");
            toggle.disabled = true;
            try {
                if (on) {
                    await this.enable();
                    try { localStorage.removeItem("borsa-push-optout"); } catch (e) {}
                    this._feedback("Açıldı. Birkaç saniye içinde bir deneme bildirimi gelecek.");
                } else {
                    await this.disable();
                    // Bilerek kapattı: uygulama bir daha kendiliğinden açmaz, sormaz.
                    try { localStorage.setItem("borsa-push-optout", "1"); } catch (e) {}
                    this._feedback("Kapatıldı. Bu cihaza artık bildirim gelmez.");
                }
            } catch (err) {
                toggle.checked = !on;
                this._feedback(err.message || "Olmadı, biraz sonra yeniden dene.", true);
            } finally {
                toggle.disabled = false;
            }
        },

        wire() {
            const toggle = $("pushPrefToggle");
            if (!toggle) return;
            toggle.addEventListener("change", () => this.toggle(toggle.checked));
            if (window.BorsaFirebase && BorsaFirebase.onChange) {
                BorsaFirebase.onChange((user) => {
                    const uid = user ? user.id : null;
                    if (uid === this._uid) return;
                    this._uid = uid;
                    this.load();
                });
            }
        },
    };

    window.BorsaPush = BorsaPush;
    document.addEventListener("DOMContentLoaded", () => BorsaPush.wire());
})();
