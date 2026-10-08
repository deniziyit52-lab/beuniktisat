/* ============================================================
   BORSA - Supabase Shared Config & Wrapper
   ------------------------------------------------------------
   - Supabase istemcisi CDN üzerinden sağlanan URL ve anon key
     ile başlatılır.
   - Sayfalardaki mevcut "BorsaFirebase" çağrılarının tamamı
     çalışsın diye AYNI arayüz (signUp / signIn / signOut /
     onChange / subscribeAuth / buyStock / sellStock / balance /
     ownedQty / formatTL) korunur. Böylece HTML/JS dosyalarında
     çağrıları değiştirmek zorunda kalmayız.
   - Yeni üye kaydında users tablosuna otomatik olarak
     balance=100000 ve boş portfolio JSONB kolonu eklenir.
   - Alış / satış Postgres tarafında atomik RPC (execute_hybrid_trade)
     ile yapılır.
   ============================================================ */

const SUPABASE_CONFIG = {
    url: "https://zhjdbpokoyitvwlkncdd.supabase.co",
    anonKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpoamRicG9rb3lpdHZ3bGtuY2RkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExODYyMzEsImV4cCI6MjEwNjc2MjIzMX0.Za4vf8mDR2xOKxXSKAipO0_-21Yk_vHiVUm5nlH1ZnY",
};

const SUPABASE_AUTH_STORAGE_KEY = "borsa-supabase-auth-session";

function migrateLegacyAuthStorage() {
    if (typeof window === "undefined" || !window.localStorage) return;
    try {
        const keysToRemove = [];
        for (let i = 0; i < window.localStorage.length; i++) {
            const k = window.localStorage.key(i);
            if (!k) continue;
            const lk = k.toLowerCase();
            if (lk.startsWith("sb-") && (lk.includes("-auth-token") || lk.includes("-auth-"))) {
                keysToRemove.push(k);
            }
        }
        keysToRemove.forEach(k => {
            try { window.localStorage.removeItem(k); } catch (e) {}
        });
        if (keysToRemove.length > 0) {
            console.log("[Borsa] Eski localStorage auth sessionları temizlendi (" + keysToRemove.length + " adet) — artık her sekme bağımsız sessionStorage kullanıyor.");
        }
    } catch (e) {
        console.warn("[Borsa] Legacy auth migration başarısız:", e && e.message || e);
    }
}

(function initSupabaseLifecycle() {
    let attempts = 0;
    const MAX_ATTEMPTS = 240; // 60 saniye (250ms * 240)
    let _healthOk = false;

    function tryInit() {
        attempts++;
        if (window.sb) return true;
        if (typeof window.supabase !== "function" &&
            !(window.supabase && typeof window.supabase.createClient === "function")) {
            return false;
        }
        // Anon key uyarısı (placeholder / kısa key tespiti)
        const key = String(SUPABASE_CONFIG.anonKey || "");
        if (key.length < 80) {
            // 80 karakterden az key neredeyse kesin olarak JWT değil = placeholder
            console.warn(
                "%c[Borsa] DİKKAT: Supabase anon key çok kısa (length=" + key.length + ").\n" +
                "Gerçek publishable key tipik olarak ~400 karakter uzunluğunda JWT formatında olmalı.\n" +
                "Anahtar: https://supabase.com/dashboard/project/_/settings/api adresinden 'anon public' key kopyalayın\n" +
                "ve supabase-config.js içindeki SUPABASE_CONFIG.anonKey içine yapıştırın.",
                "background:#fef2f2;color:#b91c1c;padding:6px 10px;border-radius:6px;font-weight:700;"
            );
        }
        try {
            window.sb = window.supabase.createClient(
                SUPABASE_CONFIG.url,
                SUPABASE_CONFIG.anonKey,
                {
                    auth: {
                        persistSession: true,
                        storage: window.sessionStorage,
                        storageKey: SUPABASE_AUTH_STORAGE_KEY,
                        autoRefreshToken: true,
                        detectSessionInUrl: true,
                    },
                    realtime: { params: { eventsPerSecond: 10 } },
                    global: {
                        fetch: (...args) => fetch(...args).catch(err => {
                            console.warn("[Borsa] Supabase fetch hatası:", err && err.message || err);
                            throw err;
                        })
                    },
                }
            );
            // Hafif bir sağlık kontrolü: SDK yaratıldıysa auth nesnesi vardır.
            if (window.sb && typeof window.sb.auth !== "undefined") {
                _healthOk = true;
                try { migrateLegacyAuthStorage(); } catch (e) {}
                try {
                    window.dispatchEvent(new CustomEvent("borsa:supabase-ready", { detail: { attempts } }));
                } catch (e) {}
                console.log("[Borsa] Supabase istemcisi hazır (deneme #" + attempts + ").");
                return true;
            } else {
                window.sb = null;
                return false;
            }
        } catch (e) {
            console.warn("[Borsa] Supabase init başarısız (deneme #" + attempts + "):", e);
            window.sb = null;
            return false;
        }
    }

    // 1) Hemen dene (CDN on-load sıralaması doğruysa ilk denemede bağlanır)
    if (tryInit()) return;

    // 2) DOMContentLoaded sonrası tekrar dene
    document.addEventListener("DOMContentLoaded", () => { if (!window.sb) tryInit(); });

    // 3) window.load sonrası tekrar dene (tüm CDN scriptleri kesin yüklenmiştir)
    window.addEventListener("load", () => { if (!window.sb) tryInit(); });

    // 4) 250ms aralıklarla 60 saniyeye kadar polling fallback
    //    (kötü ağ / CDN cache miss senaryoları için)
    const iv = setInterval(() => {
        if (window.sb || attempts >= MAX_ATTEMPTS) {
            clearInterval(iv);
            if (!window.sb) {
                console.error(
                    "%c[Borsa] Supabase bağlantısı 60 saniye sonra kurulamadı.\n" +
                    "🔹 SUPABASE_CONFIG.anonKey doğru mu? (Dashboard > Settings > API > anon public)\n" +
                    "🔹 SUPABASE_CONFIG URL doğru mu? https://xxxx.supabase.co formatında olmalı\n" +
                    "🔹 Site URL'si Supabase projesinde Redirect URL olarak beyaz listede mi?",
                    "background:#7f1d1d;color:#fff;padding:10px 12px;border-radius:8px;font-weight:700;"
                );
                try {
                    window.dispatchEvent(new CustomEvent("borsa:supabase-failed", {
                        detail: { reason: "timeout", attempts }
                    }));
                } catch (e) {}
            }
            return;
        }
        tryInit();
    }, 250);

    // Public accessor: init sağlık kontrolü başarılı mı?
    window.__borsa_sb_health = () => _healthOk && !!window.sb;
})();

const INITIAL_BALANCE = 100000;
const USERS_TABLE = "users";
const DEFAULT_CURRENCY = "TRY";

// ÖNEMLİ: Klasik <script src=""> (type=module DEĞİL) içinde const/let window objesine
// eklenmez. Diğer inline scriptlerden erişilebilmesi için AÇIKÇA window üzerine atıyoruz.
// Aksi halde: typeof window.BorsaFirebase === "undefined" olur ve tüm login akışı ölür.
window.BorsaFirebase = {
    _authReady: false,
    _user: null,
    _userDoc: null,
    _listeners: new Set(),
    _profileListener: null,

    hasSdk() {
        if (typeof window.sb === "undefined" || !window.sb) return false;
        // createClient başarılı olursa her zaman auth nesnesi vardır.
        // Yoksa client yarı-init durumundadır, güvenilmez.
        return typeof window.sb.auth !== "undefined";
    },

    isConfigured() {
        if (!SUPABASE_CONFIG || !SUPABASE_CONFIG.url || !SUPABASE_CONFIG.anonKey) return false;
        const url = String(SUPABASE_CONFIG.url || "");
        const key = String(SUPABASE_CONFIG.anonKey || "");
        // URL basit doğrulaması (https + supabase domain) — YENİ supabase region formatları da dahil
        const urlOk =
            /^https:\/\/[a-z0-9-]+\.supabase\.(co|in|net|com)$/i.test(url) ||
            url.startsWith("https://") && url.indexOf("supabase") > -1;
        // ANAHTAR: SADECE placeholder dışı ve non-empty string bak.
        // Kesin uzunluk / prefix / JWT formatı DAYATMAM — yeni formatlar çıkabilir,
        // yanlışlıkla gerçek keyi bloklamaktan daha iyidir 401 dönmesi.
        const placeholder =
            key.indexOf("BURAYA") !== -1 ||
            key.indexOf("YOUR_")  !== -1 ||
            key.indexOf("your_")  !== -1 ||
            key.indexOf("xxxx")   !== -1 ||
            key.trim() === "";
        return urlOk && !placeholder;
    },

    auth() {
        if (!this.hasSdk() || !this.isConfigured()) return null;
        return window.sb.auth;
    },

    db() {
        if (!this.hasSdk() || !this.isConfigured()) return null;
        return window.sb;
    },

    currentUser() {
        return this._user;
    },

    currentUserData() {
        return this._userDoc || null;
    },

    onChange(fn) {
        this._listeners.add(fn);
        try { fn(this._user, this._userDoc); } catch (e) {}
        return () => this._listeners.delete(fn);
    },

    _setLoggedInClass(user) {
        try {
            if (!document || !document.body) return;
            if (user) document.body.classList.add("is-logged-in");
            else document.body.classList.remove("is-logged-in");
        } catch (e) {}
    },

    _normalizePortfolioKeys(pf) {
        if (!pf || typeof pf !== "object") return {};
        const out = {};
        Object.keys(pf).forEach(k => {
            const entry = pf[k];
            if (!entry || typeof entry !== "object") {
                if (typeof entry === "number") {
                    out[k] = { qty: entry, cost: 0, avg: 0, costBasis: 0 };
                } else {
                    out[k] = { qty: 0, cost: 0, avg: 0, costBasis: 0 };
                }
                return;
            }
            const qty = Number(entry.qty ?? 0);
            const cost = Number(entry.cost ?? 0);
            const avg = entry.avg !== undefined ? Number(entry.avg) : (qty > 0 ? cost / qty : 0);
            const costBasis = entry.costBasis !== undefined ? Number(entry.costBasis) : avg;
            out[k] = {
                qty,
                cost,
                avg,
                costBasis,
            };
        });
        return out;
    },

    _emit() {
        this._setLoggedInClass(this._user);
        this._listeners.forEach(fn => {
            try { fn(this._user, this._userDoc); } catch (e) { console.error(e); }
        });
    },

    async _ensureUserRow(user) {
        if (!user || !this.db()) {
            this._userDoc = null;
            return null;
        }
        const sb = this.db();
        let data = null, error = null, triedInsert = false;
        try {
            const r = await sb
                .from(USERS_TABLE)
                .select("*")
                .eq("id", user.id)
                .maybeSingle();
            data = r.data;
            error = r.error;
        } catch (e) {
            error = e;
        }

        if (error) {
            console.warn("[Borsa] Profil okunamadı (RLS veya tablo eksik olabilir):", error);
        }

        if (!data) {
            triedInsert = true;
            const payload = {
                id: user.id,
                email: user.email || "",
                display_name: (user.user_metadata && user.user_metadata.full_name) || user.email || "",
                balance: INITIAL_BALANCE,
                portfolio: {},
            };
            let insError = null;
            try {
                const r = await sb.rpc("ensure_profile");
                insError = r.error;
                // ensure_profile henüz veritabanına kurulmadıysa (migration 0027) eski yola düş.
                if (insError && insError.code === "PGRST202") {
                    const r2 = await sb.from(USERS_TABLE).insert([payload], { upsert: true, onConflict: "id" });
                    insError = r2.error;
                }
            } catch (e) { insError = e; }
            if (insError) {
                const msg = String((insError.code ? insError.code + " :: " : "") + (insError.message || insError));
                if (msg.toLowerCase().indexOf("duplicate") === -1) {
                    console.warn("[Borsa] users satırı oluşturulamadı (INSERT/upsert başarısız):", insError);
                }
            }
            let reRead = null, rrErr = null;
            try {
                const r = await sb.from(USERS_TABLE).select("*").eq("id", user.id).maybeSingle();
                reRead = r.data;
                rrErr = r.error;
            } catch (e) { rrErr = e; }
            if (reRead) {
                data = reRead;
            } else {
                if (rrErr) console.warn("[Borsa] Insert sonrası profil tekrar okunamadı:", rrErr);
                data = payload;
            }
        }

        if (typeof data.balance === "undefined" || data.balance === null) data.balance = INITIAL_BALANCE;
        if (!data.portfolio) data.portfolio = {};
        this._userDoc = this._normalizeProfile(data);
        if (!triedInsert) this._installProfileListener(user.id);
        return this._userDoc;
    },

    _normalizeProfile(row) {
        return {
            uid: row.id || row.uid,
            email: row.email || "",
            displayName: row.display_name || row.displayName || row.email || "",
            balance: Number(row.balance ?? 0),
            portfolio: this._normalizePortfolioKeys(row.portfolio),
        };
    },

    _installProfileListener(uid) {
        if (!this.db()) return;
        try {
            if (this._profileListener) {
                try { this._profileListener.unsubscribe(); } catch (e) {}
                this._profileListener = null;
            }
            const sb = this.db();
            const channel = sb
                .channel("profile-" + uid.slice(0, 8))
                .on(
                    "postgres_changes",
                    { event: "*", schema: "public", table: USERS_TABLE, filter: `id=eq.${uid}` },
                    (payload) => {
                        if (payload.new && payload.new.id === uid) {
                            this._userDoc = this._normalizeProfile(payload.new);
                            this._emit();
                        }
                    }
                )
                .subscribe();
            this._profileListener = channel;
        } catch (e) {
            console.warn("[Borsa] Profil realtime aboneliği kurulamadı:", e);
        }
    },

    subscribeAuth() {
        if (!this.auth()) {
            this._authReady = true;
            this._emit();
            return () => {};
        }
        const auth = this.auth();

        const handle = async (event, session) => {
            this._authReady = true;
            let user = session?.user || null;
            if (!user && this.auth()) {
                try {
                    const { data } = await this.auth().getUser();
                    user = data?.user || null;
                } catch (e) {
                    try {
                        const { data: s2 } = await this.auth().getSession();
                        user = s2?.session?.user || null;
                    } catch (ee) {}
                }
            }
            this._user = user;
            this._userDoc = null;
            this._setLoggedInClass(user);
            if (this._profileListener) {
                try { this._profileListener.unsubscribe(); } catch (e) {}
                this._profileListener = null;
            }
            if (user) {
                try { await this._ensureUserRow(user); }
                catch (e) { console.error("[Borsa] Kullanıcı satırı hazırlanamadı:", e); }
            }
            this._emit();
        };

        const { data: subscription } = auth.onAuthStateChange(handle);

        (async () => {
            try {
                const { data } = await auth.getSession();
                await handle("INITIAL_SESSION", data.session);
            } catch (e) {
                this._authReady = true;
                this._emit();
            }
        })();

        return () => {
            try { subscription && subscription.unsubscribe && subscription.unsubscribe(); } catch (e) {}
        };
    },

    async refreshUserDoc() {
        if (!this._user || !this.db()) return null;
        const { data, error } = await this.db()
            .from(USERS_TABLE)
            .select("*")
            .eq("id", this._user.id)
            .maybeSingle();
        if (error || !data) return this._userDoc;
        this._userDoc = this._normalizeProfile(data);
        this._emit();
        return this._userDoc;
    },

    async signUp(email, password, displayName) {
        if (!this.auth()) throw new Error("Supabase yapılandırılmamış.");
        const data = { email, password };
        if (displayName) data.options = { data: { full_name: displayName } };
        const { error, data: resp } = await this.auth().signUp(data);
        if (error) {
            const msg = (error.message || "").toString();
            const msgLow = msg.toLowerCase();
            const status = Number(error.status || 0);
            const name = String(error.name || "");
            const e = new Error(msg);
            e.status = status;
            e.name = name;

            if (msgLow.indexOf("already") > -1) e.code = "auth/email-already-in-use";
            else if (msgLow.indexOf("weak") > -1 || (status === 422 && msgLow.indexOf("password") > -1)) e.code = "auth/weak-password";
            else if (msgLow.indexOf("email") > -1 && (status === 400 || name === "AuthInvalidCredentialsError")) e.code = "auth/invalid-email";
            else if (status === 400) e.code = "auth/invalid-email";
            else if (msgLow.indexOf("operation") > -1 && msgLow.indexOf("not allowed") > -1) e.code = "auth/operation-not-allowed";
            else e.code = "auth/internal";

            throw e;
        }

        // Oturum session döndü mü? Email confirm açıksa session NULL olabilir →
        // çağıran taraf bilgilensin, yönlendirme + session yenileme hatasız gerçekleşsin
        const user = resp?.user || null;
        const session = resp?.session || null;

        if (!user) throw new Error("Kullanıcı oluşturulamadı.");
        // Email onay bekliyorsa → çağıran taraf session:null ve email_confirmed_at null görür
        user._needsEmailConfirmation = !!(user && user.email_confirmed_at == null && !session);
        return user;
    },

    async signIn(email, password) {
        if (!this.auth()) throw new Error("Supabase yapılandırılmamış.");
        const { error, data } = await this.auth().signInWithPassword({ email, password });
        if (error) {
            const msg = (error.message || "").toString();
            const msgLow = msg.toLowerCase();
            const status = Number(error.status || 0);
            const name = String(error.name || "");
            const e = new Error(msg);
            e.status = status;
            e.name = name;

            // 401 veya "Invalid login credentials" / "Email not confirmed" gibi
            if (status === 401 ||
                msgLow.indexOf("invalid") > -1 ||
                (msgLow.indexOf("password") > -1 && msgLow.indexOf("email") > -1) ||
                name === "AuthInvalidCredentialsError"
            ) {
                if (msgLow.indexOf("email") > -1 && msgLow.indexOf("confirmed") > -1) {
                    e.code = "auth/email-not-confirmed";
                } else {
                    e.code = "auth/invalid-credential";
                }
            } else if (status === 400 && msgLow.indexOf("email") > -1) {
                e.code = "auth/invalid-email";
            } else if (status === 429 || msgLow.indexOf("too many") > -1) {
                e.code = "auth/too-many-requests";
            } else if (msgLow.indexOf("user") > -1 && msgLow.indexOf("found") > -1) {
                e.code = "auth/user-not-found";
            } else if (msgLow.indexOf("disabled") > -1) {
                e.code = "auth/user-disabled";
            } else {
                e.code = "auth/invalid-credential";
            }
            throw e;
        }
        return data?.user || null;
    },

    async signOut() {
        if (!this.auth()) return;
        try { await this.auth().signOut(); } catch (e) {}
        try {
            if (window.sessionStorage && SUPABASE_AUTH_STORAGE_KEY) {
                window.sessionStorage.removeItem(SUPABASE_AUTH_STORAGE_KEY);
            }
            migrateLegacyAuthStorage();
        } catch (e) {}
        this._user = null;
        this._userDoc = null;
        if (this._profileListener) {
            try { this._profileListener.unsubscribe(); } catch (e) {}
            this._profileListener = null;
        }
        this._listeners.forEach(fn => { try { fn(null, null); } catch (e) {} });
    },

    _stockPrice(symbol) {
        return Number(Borsa?.state?.stocks?.[symbol]?.price || 0);
    },

    async buyStock(symbol, qty) {
        if (!this._user) throw new Error("Önce giriş yapın.");
        if (Borsa?.state?.marketOpen !== true) throw new Error("Piyasa kapalı. Alım-satım yapılamaz.");
        qty = Math.floor(Number(qty));
        if (!(qty > 0)) throw new Error("Geçerli bir adet girin.");
        const price = this._stockPrice(symbol);
        if (!(price > 0)) throw new Error("Fiyat geçersiz.");
        if (!this.db()) throw new Error("Supabase yapılandırılmamış.");
        const { data, error } = await this.db().rpc("execute_hybrid_trade", {
            p_user_id: this._user.id,
            p_symbol: symbol,
            p_qty: qty,
            p_side: "BUY",
        });
        if (error) throw new Error(error.message || "Alım işlemi başarısız.");
        const result = (data && Array.isArray(data) && data[0]) || data || {};
        const out = result.trade || result;
        const executionPrice = Number(result.execution_price || price);
        this._userDoc = this._normalizeProfile({
            id: this._user.id,
            email: this._userDoc?.email || this._user.email,
            display_name: this._userDoc?.displayName || "",
            balance: out.balance ?? this._userDoc?.balance ?? 0,
            portfolio: out.portfolio ?? this._userDoc?.portfolio ?? {},
        });
        this._emit();
        const subtotal = Math.round(executionPrice * qty * 100) / 100;
        const fee = Math.round(subtotal * 0.01 * 100) / 100;
        return {
            balance: this._userDoc.balance,
            portfolio: this._userDoc.portfolio,
            subtotal,
            fee,
            total: Math.round((subtotal + fee) * 100) / 100, // KULLANICI ÖDER: komisyon dahil
            price: executionPrice,
            qty,
            circuitBreakerTriggered: result.circuit_breaker_triggered === true,
            circuitBreakerMessage: result.circuit_breaker_message || "",
        };
    },

    async sellStock(symbol, qty) {
        if (!this._user) throw new Error("Önce giriş yapın.");
        if (Borsa?.state?.marketOpen !== true) throw new Error("Piyasa kapalı. Alım-satım yapılamaz.");
        qty = Math.floor(Number(qty));
        if (!(qty > 0)) throw new Error("Geçerli bir adet girin.");
        const price = this._stockPrice(symbol);
        if (!(price > 0)) throw new Error("Fiyat geçersiz.");
        if (!this.db()) throw new Error("Supabase yapılandırılmamış.");
        const { data, error } = await this.db().rpc("execute_hybrid_trade", {
            p_user_id: this._user.id,
            p_symbol: symbol,
            p_qty: qty,
            p_side: "SELL",
        });
        if (error) throw new Error(error.message || "Satım işlemi başarısız.");
        const result = (data && Array.isArray(data) && data[0]) || data || {};
        const out = result.trade || result;
        const executionPrice = Number(result.execution_price || price);
        this._userDoc = this._normalizeProfile({
            id: this._user.id,
            email: this._userDoc?.email || this._user.email,
            display_name: this._userDoc?.displayName || "",
            balance: out.balance ?? this._userDoc?.balance ?? 0,
            portfolio: out.portfolio ?? this._userDoc?.portfolio ?? {},
        });
        this._emit();
        const subtotal = Math.round(executionPrice * qty * 100) / 100;
        const fee = Math.round(subtotal * 0.01 * 100) / 100;
        return {
            balance: this._userDoc.balance,
            portfolio: this._userDoc.portfolio,
            subtotal,
            fee,
            revenue: Math.round((subtotal - fee) * 100) / 100, // KULLANICIYA KALAN: komisyon dusulmus
            price: executionPrice,
            qty,
            circuitBreakerTriggered: result.circuit_breaker_triggered === true,
            circuitBreakerMessage: result.circuit_breaker_message || "",
        };
    },

    formatTL(n) {
        try {
            return new Intl.NumberFormat("tr-TR", {
                style: "currency",
                currency: DEFAULT_CURRENCY,
                maximumFractionDigits: 2,
            }).format(Number(n || 0));
        } catch (e) {
            return `${Number(n || 0).toFixed(2)} TL`;
        }
    },

    ownedQty(symbol) {
        if (!this._userDoc || !this._userDoc.portfolio) return 0;
        return Number(this._userDoc.portfolio[symbol]?.qty || 0);
    },

    balance() {
        return Number(this._userDoc?.balance || 0);
    },

    /**
     * Liderlik tablosunu sunucu tarafında hesaplayan RPC'yi çağırır.
     * Top 10 kullanıcı döner, sıralama toplam net değere göre yapılır:
     *   balance + Σ( portfolio[sym].qty × stocks[sym].current_price )
     * Gereksinim: SQL'de "get_leaderboard" isimli SECURITY DEFINER RPC olmalı.
     */
    async fetchLeaderboard() {
        if (!this.db()) return [];
        try {
            const { data, error } = await this.db().rpc("get_leaderboard", {});
            if (error) {
                console.warn("[Borsa] get_leaderboard RPC hatası:", error.message);
                return [];
            }
            return Array.isArray(data) ? data : [];
        } catch (e) {
            console.warn("[Borsa] Liderlik yüklenemedi:", e);
            return [];
        }
    },

    /**
     * Oturumu açan kullanıcının en son 50 işlemini döner.
     * transactions tablosu + (RLS self-only) ile çalışır.
     */
    async fetchMyTransactions() {
        if (!this._user || !this.db()) return [];
        try {
            const { data, error } = await this.db()
                .from("transactions")
                .select("id, type, stock_symbol, quantity, price_per_share, created_at")
                .eq("user_id", this._user.id)
                .order("created_at", { ascending: false })
                .limit(50);
            if (error) {
                console.warn("[Borsa] İşlem dökümü hatası:", error.message);
                return [];
            }
            return Array.isArray(data) ? data : [];
        } catch (e) {
            console.warn("[Borsa] İşlem dökümü okunamadı:", e);
            return [];
        }
    },

    // =========================================================================
    //  WHISPER / TIP (Fısıltı & Tüyo Sistemi)
    // =========================================================================

    /**
     * Admin panelinden çağrılır: toplam users tablosundan rastgele n=3 tane aktif
     * (kayıtlı) kullanıcı seçip döner. RLS kullanıcıların kendi satırını görebildiği
     * için bu metot client çağrısıdır (admin şifresi geçerli tarayıcıda çalışır).
     * Çalışması için SECURITY DEFINER get_random_users(n) RPC'ye ihtiyaç vardır
     * (aşağıdaki SQL bloğunda verilmiştir).
     */
    async fetchRandomUsers(n) {
        if (!this.db()) return [];
        n = Math.max(1, Math.min(20, Math.floor(Number(n || 3))));
        try {
            const { data, error } = await this.db().rpc("get_random_users", { n });
            if (error) {
                console.warn("[Whisper] get_random_users RPC hatası:", error.message);
                return [];
            }
            return Array.isArray(data) ? data : [];
        } catch (e) {
            console.warn("[Whisper] rastgele kullanıcı çekilemedi:", e);
            return [];
        }
    },

    async fetchWhisperUsers() {
        if (!this.db()) throw new Error("Supabase bağlantısı hazır değil.");
        try {
            const { data, error } = await this.db().rpc("admin_list_whisper_users");
            if (error) {
                console.warn("[Whisper] Kullanıcı listesi RPC hatası:", error.message);
                throw new Error(error.message || "Kullanıcı listesi alınamadı.");
            }
            return Array.isArray(data) ? data : [];
        } catch (e) {
            console.warn("[Whisper] Kullanıcı listesi alınamadı:", e);
            throw e;
        }
    },

    /**
     * Belirli kullanıcı(lar) a gizli tüyo at.
     * payloads: [{ user_id, target_user_id, message, stock_symbol, is_fake }] arrayi
     * (Admin panelinden kullanılır. Client RLS INSERT varsayar.)
     */
    async insertMarketTips(payloads) {
        if (!this.db() || !Array.isArray(payloads) || !payloads.length) return [];
        const rows = payloads.map(p => ({
            user_id:      p.user_id,
            target_user_id: p.target_user_id == null ? null : p.target_user_id,
            message:      String(p.message || "").slice(0, 280),
            stock_symbol: String(p.stock_symbol || "").slice(0, 16),
            is_fake:      !!p.is_fake,
        })).filter(p => p.user_id && p.message && p.stock_symbol);
        if (!rows.length) return [];
        try {
            const { data, error } = await this.db()
                .from("market_tips")
                .insert(rows)
                .select("id, user_id, target_user_id, stock_symbol, created_at");
            if (error) {
                console.warn("[Whisper] market_tips INSERT hatası:", error.message);
                throw new Error(error.message || "Tüyolar sisteme yüklenemedi.");
            }
            return Array.isArray(data) ? data : [];
        } catch (e) {
            console.warn("[Whisper] insert hatası:", e);
            throw e;
        }
    },

    /**
     * Giriş yapmış kullanıcının son 30 tüyounu döner (kendine ait olanlar RLS ile).
     */
    async fetchMyTips() {
        if (!this._user || !this.db()) return [];
        try {
            const { data, error } = await this.db()
                .from("market_tips")
                .select("id, message, stock_symbol, is_fake, target_user_id, created_at")
                .eq("user_id", this._user.id)
                .order("created_at", { ascending: false })
                .limit(30);
            if (error) {
                console.warn("[Whisper] fetchMyTips hatası:", error.message);
                return [];
            }
            return Array.isArray(data) ? data : [];
        } catch (e) {
            console.warn("[Whisper] fetchMyTips exception:", e);
            return [];
        }
    },

    /**
     * (Admin) 3dk sonra ana yayına haber bas + fiyat oynatmasını schedule et.
     * setTimeout kullanılır; sayfa kapanmazsa 180000ms sonra çalışır.
     */
    scheduleDelayedNews({ stock_symbol, title, impact_pct, onFire }) {
        const ms = 180 * 1000; // 3 dakika
        const handle = setTimeout(async () => {
            try {
                if (typeof Borsa !== "undefined" && Borsa.state && stock_symbol) {
                    Borsa.publishNews({
                        title:  title,
                        target: stock_symbol,
                        impact: Number(impact_pct || 0),
                    });
                }
                if (typeof onFire === "function") onFire();
            } catch (e) {
                console.warn("[Whisper] delayed news hatası:", e);
            }
        }, ms);
        return handle;
    },

    /**
     * Yeni bir fısıltı geldiğinde client'in bilgilendirilmesi için
     * Realtime postgres_changes dinleyicisini bağlar.
     * listener(tip) ile dışarıdan subscribe olunur.
     *
     * Güvenle 2+ kez çağrılabilir: mevcut WhisperRealtime örneği bulunursa
     * sadece listener eklenir, kanal yeniden oluşturulmaz.
     */
    subscribeWhisperRealtime(listener) {
        if (!window.sb || typeof window.sb.channel !== "function") return () => {};

        // Singleton'ı SIFIRDAN window üzerinden al (local const TDZ sorunu YOK)
        if (!window.WhisperRealtime) {
            window.WhisperRealtime = {
                _listeners: new Set(),
                _chan: null,
                _uid: null,
                _bound: false,
            };
        }
        const WR = window.WhisperRealtime;

        const bindForUser = (uid) => {
            if (!uid) {
                if (WR._chan) { try { window.sb.removeChannel(WR._chan); } catch (e) {} }
                WR._chan = null;
                WR._uid = null;
                return;
            }
            // Aynı kullanıcı için zaten açık kanal varsa yeniden bağlama
            if (WR._uid === uid && WR._chan) return;
            if (WR._chan) {
                try { window.sb.removeChannel(WR._chan); } catch (e) {}
                WR._chan = null;
            }
            WR._uid = uid;
            try {
                WR._chan = window.sb
                    .channel("whisper-current-user", { config: { broadcast: { self: false } } })
                    .on("postgres_changes", {
                        event: "INSERT",
                        schema: "public",
                        table: "market_tips",
                        filter: `user_id=eq.${uid}`,
                    }, (payload) => {
                        const currentUser = this.currentUser();
                        const myId = currentUser && currentUser.id != null
                            ? String(currentUser.id).trim().toLowerCase()
                            : "";
                        if (!myId || myId !== String(uid).trim().toLowerCase()) return;
                        const row = payload && payload.new;
                        if (!row) return;
                        const recipientId = row.user_id == null
                            ? ""
                            : String(row.user_id).trim().toLowerCase();
                        const targetId = row.target_user_id == null
                            ? ""
                            : String(row.target_user_id).trim().toLowerCase();
                        const deliveryId = String(row.user_id || row.target_user_id || "")
                            .trim()
                            .toLowerCase();
                        if (deliveryId && deliveryId !== "null" &&
                            deliveryId !== "undefined" && deliveryId !== myId) return;
                        if (recipientId && recipientId !== myId) return;
                        if (targetId && targetId !== myId) return;
                        WR._listeners.forEach((fn) => {
                            try { fn(row); } catch (e) {}
                        });
                    })
                    .subscribe((st) => {
                        console.log("[Whisper] Realtime abonelik:", st);
                    });
            } catch (e) {
                console.warn("[Whisper] kanal bağlantı hatası:", e);
                WR._chan = null;
            }
        };

        // Yeni listener'ı ekle (tekrar aynı listener eklenmez, Set garantiler)
        WR._listeners.add(listener);

        // İlk çağrıda auth listener'ı bağla (sonraki çağrılarda duplicate olmaz)
        if (!WR._bound) {
            WR._bound = true;
            bindForUser(this._user ? this._user.id : null);
            this.onChange((user) => bindForUser(user ? user.id : null));
        } else {
            // İkinci+ çağrıysa ama kullanıcı değişmişse, mevcut id ile yeniden bağla
            bindForUser(this._user ? this._user.id : null);
        }

        return () => WR._listeners.delete(listener);
    },
};

/* =========================================================
 *  BORSA MAINTENANCE MODE
 * ========================================================= */
window.BorsaMaintenance = (function () {
    const BYPASS_KEY = "borsa_admin_maintenance_bypass";
    const ADMIN_EMAIL = "deniziyit52@gmail.com";
    let _authSubscription = null;
    let _checkPromise = null;
    let _supabaseReadyHandlerInstalled = false;

    function isDisabled() {
        return false;
    }

    function hasAdminBypassFlag() {
        try {
            const raw = sessionStorage.getItem(BYPASS_KEY);
            if (!raw) return false;
            if (raw === "1") return true;
            sessionStorage.removeItem(BYPASS_KEY);
            return false;
        } catch (_) {
            console.warn("[Bakım] Bypass durumu sessionStorage'dan okunamadı.");
            return false;
        }
    }

    function setAdminBypassFlag() {
        try {
            sessionStorage.setItem(BYPASS_KEY, "1");
            window.__borsa_admin_bypass_set_at = Date.now();
        } catch (e) {
            console.warn("[Bakım] Bypass sessionStorage'a kaydedilemedi:", e && e.message || e);
        }
    }

    function clearAdminBypassFlag() {
        try {
            sessionStorage.removeItem(BYPASS_KEY);
            try { delete window.__borsa_admin_bypass_set_at; } catch (_) {}
        } catch (_) {}
    }

    async function fetchMaintenanceMode() {
        if (!window.sb || !window.sb.from) throw new Error("Supabase bağlantısı hazır değil.");
        const { data, error } = await window.sb
            .from("app_settings")
            .select("maintenance_mode")
            .eq("id", 1)
            .maybeSingle();
        if (error) throw new Error(error.message || "Bakım durumu okunamadı.");
        if (!data || typeof data.maintenance_mode !== "boolean") {
            throw new Error("app_settings id=1 bakım durumu bulunamadı.");
        }
        return data.maintenance_mode;
    }

    async function setMaintenanceMode(nextBool) {
        if (!window.sb || !window.sb.rpc) {
            throw new Error("Supabase yapılandırılmamış.");
        }
        const val = !!nextBool;
        const { error } = await window.sb.rpc("admin_set_maintenance", { p_enabled: val });
        if (error) throw new Error(error.message || "Bakım modu güncellenemedi.");
        return val;
    }

    function captureEmergencyBypass() {
        try {
            const url = new URL(window.location.href);
            if (url.searchParams.get("bypass") !== "admin") return false;
            setAdminBypassFlag();
            url.searchParams.delete("bypass");
            window.history.replaceState(window.history.state, "", url.toString());
            return true;
        } catch (e) {
            console.warn("[Bakım] URL bypass parametresi işlenemedi:", e && e.message || e);
            return false;
        }
    }

    function isMaintenancePage() {
        return window.location.pathname.toLowerCase().endsWith("/maintenance.html");
    }

    function isAdminUser(user) {
        if (!user) return false;
        const email = String(user.email || "").trim().toLowerCase();
        const appRole = String(user.app_metadata?.role || "").trim().toLowerCase();
        const appRoles = Array.isArray(user.app_metadata?.roles)
            ? user.app_metadata.roles.map(role => String(role).toLowerCase())
            : [];
        return email === ADMIN_EMAIL || appRole === "admin" || appRoles.includes("admin");
    }

    async function checkAndRedirect() {
        if (captureEmergencyBypass() || hasAdminBypassFlag()) return false;

        const page = window.location.pathname.toLowerCase();
        const isAdminPage = page.endsWith("/admin.html");
        const isLoginPage = page.endsWith("/login.html");
        const maintenancePage = isMaintenancePage();
        if (isAdminPage) return false;

        if (_checkPromise) return _checkPromise;
        _checkPromise = (async () => {
            try {
                const auth = window.sb && window.sb.auth;
                if (!auth || typeof auth.getSession !== "function") return false;

                // Wait for Supabase auth hydration before deciding whether the
                // visitor is an admin or should be redirected.
                const { data, error } = await auth.getSession();
                if (error) throw new Error(error.message || "Oturum doğrulanamadı.");
                const user = data?.session?.user || null;
                if (isAdminUser(user)) {
                    if (maintenancePage) {
                        const adminUrl = new URL("admin.html", window.location.href);
                        window.location.replace(adminUrl.toString());
                    }
                    return false;
                }
                if (hasAdminBypassFlag() || isLoginPage || maintenancePage) return false;

                const maintenanceActive = await fetchMaintenanceMode();
                if (!maintenanceActive) return false;

                const maintenanceUrl = new URL("maintenance.html", window.location.href);
                window.location.replace(maintenanceUrl.toString());
                return true;
            } catch (e) {
                console.error("[Bakım] Bakım durumu denetlenemedi; yönlendirme yapılmadı:", e && e.message || e);
                return false;
            }
        })();

        try {
            return await _checkPromise;
        } finally {
            _checkPromise = null;
        }
    }

    function subscribeRealtime() {
        const auth = window.sb && window.sb.auth;
        if (auth && !_authSubscription && typeof auth.onAuthStateChange === "function") {
            const { data } = auth.onAuthStateChange((event) => {
                if (event !== "INITIAL_SESSION" && event !== "SIGNED_IN" && event !== "SIGNED_OUT") return;
                window.setTimeout(() => {
                    checkAndRedirect();
                }, 0);
            });
            _authSubscription = data?.subscription || null;
        }

        if (!_supabaseReadyHandlerInstalled) {
            _supabaseReadyHandlerInstalled = true;
            window.addEventListener("borsa:supabase-ready", () => {
                subscribeRealtime();
                checkAndRedirect();
            });
        }
        window.setTimeout(() => {
            checkAndRedirect();
        }, 0);
    }

    subscribeRealtime();

    return {
        fetchMaintenanceMode,
        setMaintenanceMode,
        checkAndRedirect,
        subscribeRealtime,
        hasAdminBypassFlag,
        setAdminBypassFlag,
        clearAdminBypassFlag,
        isDisabled,
    };
})();
