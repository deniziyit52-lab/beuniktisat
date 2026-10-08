/* Rozetler: katalog burada, kazanılanlar get_my_badges RPC'sinden gelir (hesap sunucuda yapılır). */
(function () {
    // Sıra, "Rozetlerim" bölümündeki gösterim sırasıdır.
    const BADGES = {
        first_trade: { icon: "🚀", name: "İlk Adım", desc: "İlk alım ya da satımını yap.", color: "#3b82f6" },
        quiz_done:   { icon: "📝", name: "Sınavdan Geçti", desc: "Açılış sınavını çöz.", color: "#6366f1" },
        quiz_master: { icon: "🎓", name: "İktisat Kurdu", desc: "Açılış sınavında en fazla bir yanlış yap.", color: "#8b5cf6" },
        risk_taker:  { icon: "🎲", name: "Cesur Yürek", desc: "Riskli bir hisseye yatırım yap.", color: "#ef4444" },
        balanced:    { icon: "⚖️", name: "Dengeli Portföy", desc: "Aynı anda güvenli, orta ve riskli hisse tut.", color: "#14b8a6" },
        diversified: { icon: "🧺", name: "Sepetçi", desc: "Aynı anda 5 farklı hisse tut.", color: "#10b981" },
        gold:        { icon: "🪙", name: "Altın Avcısı", desc: "Altın al.", color: "#f59e0b" },
        fx:          { icon: "💱", name: "Döviz Bürosu", desc: "3 farklı döviz al.", color: "#0ea5e9" },
        whale:       { icon: "🐋", name: "Balina", desc: "Tek işlemde 30.000 ₺ ve üzeri alım ya da satım yap.", color: "#2563eb" },
        trader_25:   { icon: "📊", name: "Aktif Yatırımcı", desc: "Toplam 25 işlem yap.", color: "#a855f7" },
        trader_100:  { icon: "🐺", name: "Borsa Kurdu", desc: "Toplam 100 işlem yap.", color: "#64748b" },
        rising:      { icon: "📈", name: "Yükselişte", desc: "Toplam getirin %10'u geçsin.", color: "#22c55e" },
        bull:        { icon: "🐂", name: "Boğa", desc: "Toplam getirin %25'i geçsin.", color: "#16a34a" },
        bear:        { icon: "🐻", name: "Ayı Pençesi", desc: "Toplam getirin -%10'un altına düşsün. Olur böyle şeyler.", color: "#92400e" },
        podium:      { icon: "🏆", name: "Podyum", desc: "Kârdayken liderlik tablosunda ilk 3'e gir.", color: "#eab308" },
        developer:   { icon: "🛠️", name: "Geliştirici", desc: "Bu oyunu geliştiren ekipten.", color: "#f97316", hidden: true },
    };
    const SEEN_KEY = "borsa_badges_seen_v1";
    const MAX_FEATURED = 3;
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML.replace(/"/g, "&quot;");
    };

    const BorsaBadges = {
        BADGES,
        _uid: null,
        _earned: [],
        _timer: null,

        // Liderlik tablosunda ismin yanında gösterilen küçük simgeler (geliştirici rozeti başta).
        iconsMarkup(keys, limit) {
            const list = (Array.isArray(keys) ? keys : []).filter(k => BADGES[k]);
            list.sort((a, b) => (b === "developer") - (a === "developer"));
            const shown = list.slice(0, limit || 3);
            const rest = list.length - shown.length;
            return shown.map(k =>
                `<span class="badge-mini" title="${esc(BADGES[k].name)}" style="--badge-color:${BADGES[k].color}">${BADGES[k].icon}</span>`
            ).join("") + (rest > 0 ? `<span class="badge-mini badge-mini--more" title="${rest} rozet daha">+${rest}</span>` : "");
        },

        async load(options) {
            const root = document.getElementById("badgesGrid");
            const user = BorsaFirebase.currentUser ? BorsaFirebase.currentUser() : null;
            if (!user || !window.sb || !window.sb.rpc) {
                this._earned = [];
                if (root) root.innerHTML = '<p class="badges-empty">Rozetlerini görmek için giriş yap.</p>';
                return;
            }
            const { data, error } = await window.sb.rpc("get_my_badges");
            if (error || !Array.isArray(data)) {
                if (root && !(options && options.silent)) {
                    root.innerHTML = '<p class="badges-empty">Rozetler şu an yüklenemedi.</p>';
                }
                return;
            }
            this._earned = data;
            this.render();
            this._announceNew(user.id);
        },

        render() {
            const root = document.getElementById("badgesGrid");
            if (!root) return;
            const earnedAt = {};
            this._earned.forEach(b => { earnedAt[b.badge] = b.earned_at; });
            const keys = Object.keys(BADGES).filter(k => !BADGES[k].hidden || earnedAt[k]);
            const visibleTotal = keys.length;
            const earnedCount = keys.filter(k => earnedAt[k]).length;
            const summary = document.getElementById("badgesSummary");
            if (summary) summary.textContent = `${earnedCount} / ${visibleTotal} rozet kazanıldı`;
            // Kazanılanlar önce, sonra kazanılmayanlar.
            keys.sort((a, b) => Boolean(earnedAt[b]) - Boolean(earnedAt[a]));
            const featured = this._featuredKeys();
            root.innerHTML = keys.map(k => {
                const b = BADGES[k];
                const got = Boolean(earnedAt[k]);
                const shown = featured.includes(k);
                return `
                <div class="badge-card ${got ? "is-earned" : "is-locked"} ${shown ? "is-featured" : ""}" style="--badge-color:${b.color}">
                    <div class="badge-medal" ${got ? `data-badge-replay="${k}" title="Tekrar göster"` : 'aria-hidden="true"'}>${got ? b.icon : "🔒"}</div>
                    <div class="badge-text">
                        <strong>${esc(b.name)}</strong>
                        <span>${esc(b.desc)}</span>
                        ${got ? `<em>Kazanıldı: ${new Date(earnedAt[k]).toLocaleDateString("tr-TR")}</em>` : ""}
                    </div>
                    ${got ? `<button type="button" class="badge-feature" data-badge-feature="${k}" aria-pressed="${shown}"
                        title="${shown ? "Liderlikten kaldır" : "Liderlik tablosunda adının yanında göster"}">${shown ? "★ Liderlikte" : "☆ Göster"}</button>` : ""}
                </div>`;
            }).join("");
            const hint = document.getElementById("badgesFeatureHint");
            if (hint) hint.textContent = `Liderlikte gösterilen: ${featured.length} / ${MAX_FEATURED}`;
            // Kazanılmış rozetin madalyonuna tıklayınca kutlama yeniden oynar.
            root.querySelectorAll("[data-badge-replay]").forEach(medal => {
                medal.addEventListener("click", () => this._celebrate([medal.dataset.badgeReplay]));
            });
            root.querySelectorAll("[data-badge-feature]").forEach(button => {
                button.addEventListener("click", () => this.toggleFeatured(button.dataset.badgeFeature));
            });
        },

        _featuredKeys() {
            return this._earned.filter(b => b.featured && BADGES[b.badge]).map(b => b.badge);
        },

        // Rozeti liderlikte gösterilenlere ekler ya da çıkarır (en fazla MAX_FEATURED).
        async toggleFeatured(key) {
            if (this._saving) return;
            const current = this._featuredKeys();
            const hint = document.getElementById("badgesFeatureHint");
            let next;
            if (current.includes(key)) {
                next = current.filter(k => k !== key);
            } else {
                if (current.length >= MAX_FEATURED) {
                    if (hint) {
                        hint.textContent = `En fazla ${MAX_FEATURED} rozet gösterebilirsin; önce birini kaldır.`;
                        hint.classList.add("is-warning");
                        setTimeout(() => { hint.classList.remove("is-warning"); this.render(); }, 2500);
                    }
                    return;
                }
                next = [...current, key];
            }
            this._saving = true;
            try {
                const { data, error } = await window.sb.rpc("set_featured_badges", { p_badges: next });
                if (error) throw error;
                if (Array.isArray(data)) this._earned = data;
                this.render();
                if (typeof window.invalidateSidebarCaches === "function") window.invalidateSidebarCaches();
            } catch (err) {
                if (hint) hint.textContent = (err && err.message) || "Seçim kaydedilemedi.";
            } finally {
                this._saving = false;
            }
        },

        // Bu tarayıcıda daha önce görülmemiş rozetler için kısa bir kutlama gösterir.
        _announceNew(uid) {
            let seen = {};
            try { seen = JSON.parse(localStorage.getItem(SEEN_KEY) || "{}") || {}; } catch (_) {}
            const known = Array.isArray(seen[uid]) ? seen[uid] : null;
            const current = this._earned.map(b => b.badge).filter(k => BADGES[k]);
            if (known) {
                const fresh = current.filter(k => !known.includes(k));
                if (fresh.length) this._celebrate(fresh);
            }
            seen[uid] = current;
            try { localStorage.setItem(SEEN_KEY, JSON.stringify(seen)); } catch (_) {}
        },

        // Yeni rozet: ekranın ortasında büyüyerek gelen madalyon. Birden fazlaysa sırayla gösterilir.
        _celebrate(keys) {
            this._queue = (this._queue || []).concat(keys.filter(k => BADGES[k]));
            if (!this._celebrating) this._showNext();
        },

        _showNext() {
            const key = (this._queue || []).shift();
            if (!key) { this._celebrating = false; return; }
            this._celebrating = true;
            const badge = BADGES[key];
            const overlay = document.createElement("div");
            overlay.className = "badge-celebrate";
            overlay.setAttribute("role", "status");
            overlay.style.setProperty("--badge-color", badge.color);
            overlay.innerHTML = `
                <div class="badge-celebrate-inner">
                    <div class="badge-celebrate-rays" aria-hidden="true"></div>
                    <div class="badge-celebrate-medal" aria-hidden="true">${badge.icon}</div>
                    <div class="badge-celebrate-kicker">YENİ ROZET</div>
                    <div class="badge-celebrate-name">${esc(badge.name)}</div>
                    <div class="badge-celebrate-desc">${esc(badge.desc)}</div>
                    <div class="badge-celebrate-hint">Kapatmak için tıkla</div>
                </div>`;
            document.body.appendChild(overlay);
            let closed = false;
            const close = () => {
                if (closed) return;
                closed = true;
                overlay.classList.add("is-leaving");
                setTimeout(() => { overlay.remove(); this._showNext(); }, 350);
            };
            overlay.addEventListener("click", close);
            setTimeout(close, 4200);
        },

        // İşlemden kısa süre sonra rozetleri yeniden kontrol eder (art arda işlemlerde tek çağrı).
        scheduleCheck(delayMs) {
            clearTimeout(this._timer);
            this._timer = setTimeout(() => this.load({ silent: true }), delayMs || 4000);
        },

        wire() {
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (uid === this._uid) return;
                this._uid = uid;
                if (uid) this.scheduleCheck(2500);
                else this.load();
            });
            window.addEventListener("borsa:new-transaction", () => this.scheduleCheck(4000));
            window.addEventListener("borsa:asset-traded", () => this.scheduleCheck(4000));
        },
    };

    window.BorsaBadges = BorsaBadges;
    document.addEventListener("DOMContentLoaded", () => BorsaBadges.wire());
})();
