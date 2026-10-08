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
            const shown = list.slice(0, limit || 5);
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
            root.innerHTML = keys.map(k => {
                const b = BADGES[k];
                const got = Boolean(earnedAt[k]);
                return `
                <div class="badge-card ${got ? "is-earned" : "is-locked"}" style="--badge-color:${b.color}">
                    <div class="badge-medal" aria-hidden="true">${got ? b.icon : "🔒"}</div>
                    <div class="badge-text">
                        <strong>${esc(b.name)}</strong>
                        <span>${esc(b.desc)}</span>
                        ${got ? `<em>Kazanıldı: ${new Date(earnedAt[k]).toLocaleDateString("tr-TR")}</em>` : ""}
                    </div>
                </div>`;
            }).join("");
        },

        // Bu tarayıcıda daha önce görülmemiş rozetler için kısa bir kutlama gösterir.
        _announceNew(uid) {
            let seen = {};
            try { seen = JSON.parse(localStorage.getItem(SEEN_KEY) || "{}") || {}; } catch (_) {}
            const known = Array.isArray(seen[uid]) ? seen[uid] : null;
            const current = this._earned.map(b => b.badge).filter(k => BADGES[k]);
            if (known) {
                const fresh = current.filter(k => !known.includes(k));
                if (fresh.length) this._toast(fresh);
            }
            seen[uid] = current;
            try { localStorage.setItem(SEEN_KEY, JSON.stringify(seen)); } catch (_) {}
        },

        _toast(keys) {
            let el = document.getElementById("badgeToast");
            if (!el) {
                el = document.createElement("div");
                el.id = "badgeToast";
                el.className = "badge-toast";
                el.setAttribute("role", "status");
                document.body.appendChild(el);
            }
            const first = BADGES[keys[0]];
            el.style.setProperty("--badge-color", first.color);
            el.innerHTML = `
                <span class="badge-toast-icon" aria-hidden="true">${first.icon}</span>
                <span class="badge-toast-text">
                    <strong>Yeni rozet: ${esc(first.name)}</strong>
                    <span>${keys.length > 1 ? `ve ${keys.length - 1} rozet daha · ` : ""}Menüdeki "Rozetlerim" bölümünden görebilirsin.</span>
                </span>`;
            el.classList.add("is-visible");
            clearTimeout(el._hideTimer);
            el._hideTimer = setTimeout(() => el.classList.remove("is-visible"), 6000);
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
