/* Admin paneli: Oyun Özeti, Sistem Sağlığı ve Oyuncular (arama + ayrıntı).
   Hepsi yalnızca okur: admin_game_overview, admin_system_health, admin_list_players, admin_player_detail RPC'leri. */
(function () {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML.replace(/"/g, "&quot;");
    };
    const tl = (n) => Number(n || 0).toLocaleString("tr-TR", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " ₺";
    const num = (n, d = 0) => Number(n || 0).toLocaleString("tr-TR", { maximumFractionDigits: d });
    const pct = (n) => {
        if (n == null || !Number.isFinite(Number(n))) return "—";
        const v = Number(n);
        return `<span class="${v > 0 ? "ins-up" : v < 0 ? "ins-down" : ""}">${v > 0 ? "+" : ""}${v.toLocaleString("tr-TR", { maximumFractionDigits: 2 })}%</span>`;
    };
    const when = (iso) => {
        if (!iso) return "—";
        const d = new Date(iso);
        return d.toLocaleString("tr-TR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" });
    };
    const assetName = (k) => (window.BorsaAssets && window.BorsaAssets.ASSETS && window.BorsaAssets.ASSETS[k]?.name) || k;
    const rpc = async (fn, args) => {
        if (!window.sb || !window.sb.rpc) throw new Error("Bağlantı hazır değil.");
        const { data, error } = await window.sb.rpc(fn, args || {});
        if (error) throw error;
        return data;
    };

    const STATUS = {
        ok: { icon: "🟢", text: "Çalışıyor" },
        warn: { icon: "🟡", text: "Dikkat" },
        bad: { icon: "🔴", text: "Sorun var" },
        idle: { icon: "⚪", text: "Piyasa kapalı" },
    };

    const AdminInsights = {
        _loadedFor: null,
        _healthTimer: null,
        _searchTimer: null,
        _openId: null,

        async loadOverview() {
            const box = $("overviewBody");
            if (!box) return;
            try {
                const o = await rpc("admin_game_overview");
                const tile = (label, value, sub) => `
                    <div class="ins-tile"><span>${label}</span><strong>${value}</strong>${sub ? `<small>${sub}</small>` : ""}</div>`;
                box.innerHTML = `
                    <div class="ins-tiles">
                        ${tile("Kayıtlı oyuncu", num(o.players), `${num(o.active)} kişi en az bir işlem yaptı`)}
                        ${tile("Bugün işlem yapan", num(o.today_traders), `Son 7 günde ${num(o.week_traders)} kişi`)}
                        ${tile("Bugünkü işlem", num(o.today_trades), `Hacim ${tl(o.today_volume)}`)}
                        ${tile("Bugün en çok işlem gören", o.top_stock ? esc(o.top_stock.name) : "—",
                               o.top_stock ? `${num(o.top_stock.trades)} işlem · ${tl(o.top_stock.volume)}` : "Bugün hisse işlemi yok")}
                        ${tile("Ortalama getiri", pct(o.avg_return), `${num(o.in_profit)} / ${num(o.active)} oyuncu kârda`)}
                        ${tile("Nakitte duran para", o.cash_pct == null ? "—" : "%" + num(o.cash_pct, 1), "İşlem yapanların toplam varlığına göre")}
                        ${tile("En yüksek getiri", o.best ? pct(o.best.return_pct) : "—", o.best ? esc(o.best.name) : "")}
                        ${tile("En düşük getiri", o.worst ? pct(o.worst.return_pct) : "—", o.worst ? esc(o.worst.name) : "")}
                    </div>`;
            } catch (err) {
                box.innerHTML = `<p class="field-hint">Özet yüklenemedi: ${esc(err.message || err)}</p>`;
            }
        },

        async loadHealth() {
            const box = $("healthBody");
            if (!box) return;
            try {
                const h = await rpc("admin_system_health");
                const checks = Array.isArray(h.checks) ? h.checks : [];
                const worst = checks.some(c => c.status === "bad") ? "bad" : checks.some(c => c.status === "warn") ? "warn" : "ok";
                const summary = $("healthSummary");
                if (summary) summary.textContent = `${STATUS[worst].icon} ${worst === "ok" ? "Her şey yolunda" : STATUS[worst].text}`;
                box.innerHTML = `
                    <p class="field-hint">Piyasa ${h.market_open ? "açık" : "kapalı"} · kontrol ${when(h.checked_at)} · her dakika yenilenir</p>
                    ${checks.map(c => `
                        <div class="ins-check ins-check--${esc(c.status)}">
                            <div class="ins-check-head">
                                <span>${STATUS[c.status]?.icon || "⚪"} <strong>${esc(c.label)}</strong></span>
                                <span class="ins-check-state">${esc(STATUS[c.status]?.text || c.status)}</span>
                            </div>
                            <div class="ins-check-detail">${esc(c.detail || "")}</div>
                            ${Array.isArray(c.stocks) && c.stocks.length ? `
                                <details class="ins-more"><summary>Hisse hisse fark</summary>
                                    <table class="ins-table">
                                        <thead><tr><th>Hisse</th><th>Fark</th><th>Son veri</th></tr></thead>
                                        <tbody>${c.stocks.map(s => `
                                            <tr><td>${esc(s.name)}</td><td>${pct(s.gap_pct)}</td><td>${s.fetched_min == null ? "—" : num(s.fetched_min) + " dk önce"}</td></tr>`).join("")}
                                        </tbody>
                                    </table>
                                </details>` : ""}
                            ${Array.isArray(c.jobs) && c.jobs.length ? `
                                <details class="ins-more"><summary>Hatalı görevler</summary>
                                    ${c.jobs.map(j => `<div class="ins-job"><strong>${esc(j.job)}</strong> · ${num(j.count)} kez · son ${when(j.last_at)}<br><small>${esc(j.message || "")}</small></div>`).join("")}
                                </details>` : ""}
                        </div>`).join("")}`;
            } catch (err) {
                box.innerHTML = `<p class="field-hint">Durum okunamadı: ${esc(err.message || err)}</p>`;
            }
        },

        async loadPlayers() {
            const list = $("playersList");
            if (!list) return;
            const q = ($("playerSearch")?.value || "").trim();
            try {
                const rows = await rpc("admin_list_players", { p_search: q || null });
                const summary = $("playersSummary");
                if (summary) summary.textContent = q ? `${rows.length} sonuç` : `${rows.length} oyuncu`;
                if (!rows.length) {
                    list.innerHTML = '<p class="field-hint">Oyuncu bulunamadı.</p>';
                    return;
                }
                list.innerHTML = rows.map(p => `
                    <div class="ins-player" data-player="${esc(p.id)}">
                        <button type="button" class="ins-player-row" data-player-open="${esc(p.id)}">
                            <span class="ins-rank">${p.rank ? "#" + num(p.rank) : "—"}</span>
                            <span class="ins-player-name">
                                <strong>${esc(p.name || p.email)}</strong>
                                <small>${p.nickname ? "🎭 " + esc(p.nickname) + " · " : ""}${esc(p.email || "")}</small>
                            </span>
                            <span class="ins-player-num">
                                <strong>${pct(p.return_pct)}</strong>
                                <small>${tl(p.wealth)} · ${num(p.trades)} işlem</small>
                            </span>
                        </button>
                        <div class="ins-player-detail" hidden></div>
                    </div>`).join("");
                list.querySelectorAll("[data-player-open]").forEach(btn => {
                    btn.addEventListener("click", () => this.toggleDetail(btn.dataset.playerOpen));
                });
                if (this._openId && list.querySelector(`[data-player="${CSS.escape(this._openId)}"]`)) {
                    const id = this._openId;
                    this._openId = null;
                    this.toggleDetail(id);
                }
            } catch (err) {
                list.innerHTML = `<p class="field-hint">Liste yüklenemedi: ${esc(err.message || err)}</p>`;
            }
        },

        async toggleDetail(id) {
            const wrap = $("playersList")?.querySelector(`[data-player="${CSS.escape(id)}"]`);
            if (!wrap) return;
            const box = wrap.querySelector(".ins-player-detail");
            if (!box.hidden) {
                box.hidden = true;
                this._openId = null;
                return;
            }
            $("playersList").querySelectorAll(".ins-player-detail").forEach(el => { el.hidden = true; });
            this._openId = id;
            box.hidden = false;
            box.innerHTML = '<p class="field-hint">Yükleniyor…</p>';
            try {
                const d = await rpc("admin_player_detail", { p_user_id: id });
                const stocksValue = d.stocks.reduce((a, s) => a + Number(s.value || 0), 0);
                const assetsValue = d.assets.reduce((a, s) => a + Number(s.value || 0), 0);
                box.innerHTML = `
                    <div class="ins-tiles ins-tiles--small">
                        <div class="ins-tile"><span>Toplam varlık</span><strong>${tl(d.wealth)}</strong><small>Getiri ${pct(d.return_pct)}${d.rank ? " · sıra #" + num(d.rank) : ""}</small></div>
                        <div class="ins-tile"><span>Nakit</span><strong>${tl(d.balance)}</strong><small>Başlangıç ${tl(d.starting_balance)}</small></div>
                        <div class="ins-tile"><span>Hisseler</span><strong>${tl(stocksValue)}</strong><small>${d.stocks.length} farklı hisse</small></div>
                        <div class="ins-tile"><span>Altın / döviz</span><strong>${tl(assetsValue)}</strong><small>${num(d.trade_count)} işlem toplam</small></div>
                    </div>
                    ${d.stocks.length ? `
                    <div class="panel-sub">📦 Hisseler</div>
                    <div class="ins-table-wrap"><table class="ins-table">
                        <thead><tr><th>Hisse</th><th>Adet</th><th>Maliyet</th><th>Fiyat</th><th>Değer</th><th>K/Z</th></tr></thead>
                        <tbody>${d.stocks.map(s => {
                            const cost = Number(s.cost || 0);
                            const pl = cost > 0 ? (Number(s.price) / cost - 1) * 100 : null;
                            return `<tr><td>${esc(s.name)}</td><td>${num(s.qty, 4)}</td><td>${cost > 0 ? tl(cost) : "—"}</td><td>${tl(s.price)}</td><td>${tl(s.value)}</td><td>${pl == null ? "—" : pct(pl.toFixed(2))}</td></tr>`;
                        }).join("")}</tbody>
                    </table></div>` : ""}
                    ${d.assets.length ? `
                    <div class="panel-sub">🥇 Altın / döviz</div>
                    <div class="ins-table-wrap"><table class="ins-table">
                        <thead><tr><th>Varlık</th><th>Miktar</th><th>Fiyat</th><th>Değer</th></tr></thead>
                        <tbody>${d.assets.map(a => `<tr><td>${esc(assetName(a.asset))}</td><td>${num(a.qty, 4)}</td><td>${tl(a.price)}</td><td>${tl(a.value)}</td></tr>`).join("")}</tbody>
                    </table></div>` : ""}
                    <div class="panel-sub">🧾 Son işlemler${d.trades.length ? ` (son ${d.trades.length})` : ""}</div>
                    ${d.trades.length ? `
                    <div class="ins-table-wrap"><table class="ins-table">
                        <thead><tr><th>Zaman</th><th>İşlem</th><th>Ne</th><th>Miktar</th><th>Fiyat</th><th>Tutar</th></tr></thead>
                        <tbody>${d.trades.map(t => {
                            const name = t.kind === "asset" ? assetName(t.symbol) : ((window.Borsa && Borsa.state.stocks[t.symbol]?.name) || t.symbol);
                            const buy = String(t.side).toUpperCase() === "BUY";
                            return `<tr><td>${when(t.at)}</td><td><span class="${buy ? "ins-up" : "ins-down"}">${buy ? "Alış" : "Satış"}</span></td><td>${esc(name)}</td><td>${num(t.qty, 4)}</td><td>${tl(t.price)}</td><td>${tl(t.total)}</td></tr>`;
                        }).join("")}</tbody>
                    </table></div>` : '<p class="field-hint">Henüz işlem yok.</p>'}`;
            } catch (err) {
                box.innerHTML = `<p class="field-hint">Ayrıntı yüklenemedi: ${esc(err.message || err)}</p>`;
            }
        },

        loadAll() {
            this.loadOverview();
            this.loadHealth();
            this.loadPlayers();
        },

        wire() {
            if (!$("overviewBody")) return;
            $("overviewRefresh").addEventListener("click", () => this.loadOverview());
            $("healthRefresh").addEventListener("click", () => this.loadHealth());
            $("playersRefresh").addEventListener("click", () => this.loadPlayers());
            $("playerSearch").addEventListener("input", () => {
                clearTimeout(this._searchTimer);
                this._searchTimer = setTimeout(() => this.loadPlayers(), 350);
            });
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (!uid || uid === this._loadedFor) return;
                this._loadedFor = uid;
                this.loadAll();
                clearInterval(this._healthTimer);
                // Sağlık her dakika, özet beş dakikada bir yenilenir; sekme arka plandayken boşuna sorgu atılmaz.
                let tick = 0;
                this._healthTimer = setInterval(() => {
                    if (document.hidden) return;
                    tick += 1;
                    this.loadHealth();
                    if (tick % 5 === 0) this.loadOverview();
                }, 60 * 1000);
            });
        },
    };

    window.AdminInsights = AdminInsights;
    document.addEventListener("DOMContentLoaded", () => AdminInsights.wire());
})();
