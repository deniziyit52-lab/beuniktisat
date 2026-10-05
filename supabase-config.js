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
   - Alış / satış Postgres tarafında atomik RPC (execute_trade)
     ile yapılır.
   ============================================================ */

const SUPABASE_CONFIG = {
    url: "https://zhjdbpokoyitvwlkncdd.supabase.co",
    anonKey: "sb_publishable_6HAQTaMsrRy6t945u0kjSA_Y7vXf8fd",
};

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
                        storage: window.localStorage,
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
                // Dışarıya bildir (bekleyen kodlar bu event üzerinde uyanabilir)
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
                const r = await sb.from(USERS_TABLE).insert([payload], { upsert: true, onConflict: "id" });
                insError = r.error;
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
        await this.auth().signOut();
    },

    _stockPrice(symbol) {
        return Number(Borsa?.state?.stocks?.[symbol]?.price || 0);
    },

    async buyStock(symbol, qty) {
        if (!this._user) throw new Error("Önce giriş yapın.");
        qty = Math.floor(Number(qty));
        if (!(qty > 0)) throw new Error("Geçerli bir adet girin.");
        const price = this._stockPrice(symbol);
        if (!(price > 0)) throw new Error("Fiyat geçersiz.");
        if (!this.db()) throw new Error("Supabase yapılandırılmamış.");
        const { data, error } = await this.db().rpc("execute_trade", {
            p_user_id: this._user.id,
            p_symbol: symbol,
            p_qty: qty,
            p_price: price,
            p_side: "BUY",
        });
        if (error) throw new Error(error.message || "Alım işlemi başarısız.");
        const out = (data && Array.isArray(data) && data[0]) || data || {};
        this._userDoc = this._normalizeProfile({
            id: this._user.id,
            email: this._userDoc?.email || this._user.email,
            display_name: this._userDoc?.displayName || "",
            balance: out.balance ?? this._userDoc?.balance ?? 0,
            portfolio: out.portfolio ?? this._userDoc?.portfolio ?? {},
        });
        this._emit();
        const subtotal = Math.round(price * qty * 100) / 100;
        const fee = Math.round(subtotal * 0.01 * 100) / 100;
        return {
            balance: this._userDoc.balance,
            portfolio: this._userDoc.portfolio,
            subtotal,
            fee,
            total: Math.round((subtotal + fee) * 100) / 100, // KULLANICI ÖDER: komisyon dahil
            price,
            qty,
        };
    },

    async sellStock(symbol, qty) {
        if (!this._user) throw new Error("Önce giriş yapın.");
        qty = Math.floor(Number(qty));
        if (!(qty > 0)) throw new Error("Geçerli bir adet girin.");
        const price = this._stockPrice(symbol);
        if (!(price > 0)) throw new Error("Fiyat geçersiz.");
        if (!this.db()) throw new Error("Supabase yapılandırılmamış.");
        const { data, error } = await this.db().rpc("execute_trade", {
            p_user_id: this._user.id,
            p_symbol: symbol,
            p_qty: qty,
            p_price: price,
            p_side: "SELL",
        });
        if (error) throw new Error(error.message || "Satım işlemi başarısız.");
        const out = (data && Array.isArray(data) && data[0]) || data || {};
        this._userDoc = this._normalizeProfile({
            id: this._user.id,
            email: this._userDoc?.email || this._user.email,
            display_name: this._userDoc?.displayName || "",
            balance: out.balance ?? this._userDoc?.balance ?? 0,
            portfolio: out.portfolio ?? this._userDoc?.portfolio ?? {},
        });
        this._emit();
        const subtotal = Math.round(price * qty * 100) / 100;
        const fee = Math.round(subtotal * 0.01 * 100) / 100;
        return {
            balance: this._userDoc.balance,
            portfolio: this._userDoc.portfolio,
            subtotal,
            fee,
            revenue: Math.round((subtotal - fee) * 100) / 100, // KULLANICIYA KALAN: komisyon dusulmus
            price,
            qty,
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

    /**
     * Belirli kullanıcı(lar) a gizli tüyo at.
     * payloads: [{ user_id, message, stock_symbol, is_fake }] arrayi
     * (Admin panelinden kullanılır. Client RLS INSERT varsayar.)
     */
    async insertMarketTips(payloads) {
        if (!this.db() || !Array.isArray(payloads) || !payloads.length) return [];
        const rows = payloads.map(p => ({
            user_id:      p.user_id,
            message:      String(p.message || "").slice(0, 280),
            stock_symbol: String(p.stock_symbol || "").slice(0, 16),
            is_fake:      !!p.is_fake,
        })).filter(p => p.user_id && p.message && p.stock_symbol);
        if (!rows.length) return [];
        try {
            const { data, error } = await this.db()
                .from("market_tips")
                .insert(rows)
                .select("id, user_id, stock_symbol, created_at");
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
                .select("id, message, stock_symbol, is_fake, created_at")
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
                        const row = payload && payload.new;
                        if (!row) return;
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
 *  BORSA MAINTENANCE MOD
 *  Otomatik yönlendirme / reload / realtime abonelik YOK.
 *  Admin panel yalnızca fetch/set ile DB bayrağını okur/yazar.
 * ========================================================= */
window.BorsaMaintenance = (function () {
    // true olduğu sürece bakım asla kullanıcıları başka sayfaya atmaz.
    // Tekrar açmak için bu sabiti false yapın VE aşağıdaki
    // checkAndRedirect gövdesini bilinçli olarak geri yazın.
    const MAINTENANCE_DISABLED = true;

    window.__BORSA_DISABLE_MAINTENANCE__ = true;
    window.__BORSA_KILL_MAINT__ = true;
    try { sessionStorage.setItem("borsa_maint_disabled", "1"); } catch (_) {}
    try { localStorage.setItem("borsa_maint_disabled", "1"); } catch (_) {}

    const BYPASS_KEY = "borsa_admin_maintenance_bypass";
    const BYPASS_TTL_MS = 30 * 60 * 1000;

    function isDisabled() {
        if (MAINTENANCE_DISABLED === true) return true;
        try {
            if (window.__BORSA_DISABLE_MAINTENANCE__ === true) return true;
            if (window.__BORSA_KILL_MAINT__ === true) return true;
            if (sessionStorage.getItem("borsa_maint_disabled") === "1") return true;
            if (localStorage.getItem("borsa_maint_disabled") === "1") return true;
        } catch (_) {}
        return false;
    }

    function hasAdminBypassFlag() {
        try {
            const raw = sessionStorage.getItem(BYPASS_KEY);
            if (!raw) return false;
            const exp = parseInt(raw, 10);
            if (isNaN(exp) || Date.now() > exp) {
                try { sessionStorage.removeItem(BYPASS_KEY); } catch (_) {}
                return false;
            }
            return true;
        } catch (_) {
            return false;
        }
    }

    function setAdminBypassFlag() {
        try {
            sessionStorage.setItem(BYPASS_KEY, String(Date.now() + BYPASS_TTL_MS));
            window.__borsa_admin_bypass_set_at = Date.now();
        } catch (_) {}
    }

    function clearAdminBypassFlag() {
        try {
            sessionStorage.removeItem(BYPASS_KEY);
            try { delete window.__borsa_admin_bypass_set_at; } catch (_) {}
        } catch (_) {}
    }

    async function fetchMaintenanceMode() {
        if (!window.sb || !window.sb.from) return false;
        try {
            const { data, error } = await window.sb
                .from("app_settings")
                .select("maintenance_mode")
                .limit(1)
                .maybeSingle();
            if (error) {
                console.warn("[Bakım] app_settings okuma hatası:", error.message);
                return false;
            }
            return !!(data && data.maintenance_mode);
        } catch (e) {
            console.warn("[Bakım] beklenmedik hata:", e);
            return false;
        }
    }

    async function setMaintenanceMode(nextBool) {
        if (!window.sb || !window.sb.from) {
            throw new Error("Supabase yapılandırılmamış.");
        }
        const val = !!nextBool;
        const { error } = await window.sb.from("app_settings").upsert(
            [{ id: 1, maintenance_mode: val }],
            { onConflict: "id" }
        );
        if (error) throw new Error(error.message || "Bakım modu güncellenemedi.");
        return val;
    }

    // Kasıtlı no-op: location.href / reload / assign YOK.
    // Eski sürümde bakım açık/kapalı okuma hatası index <-> maintenance
    // arasında sonsuz yenileme üretiyordu.
    async function checkAndRedirect() {
        return;
    }

    function subscribeRealtime() {
        return;
    }

    if (isDisabled()) {
        console.log("[Bakım] Pasif: otomatik yönlendirme ve realtime kapalı.");
    }

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
