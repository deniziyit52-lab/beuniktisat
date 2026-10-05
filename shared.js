const STORAGE_KEY = "borsa_economics_club_v1";

const Borsa = {
    state: {
        stocks: {},
        news: [],
        selectedStock: null,
    },
    priceChart: null,
    _chartSymbol: null,
    _clockInterval: null,

    round2(n) {
        return Math.round(n * 100) / 100;
    },

    formatTime(ts) {
        const d = new Date(ts);
        const day = String(d.getDate()).padStart(2, "0");
        const month = String(d.getMonth() + 1).padStart(2, "0");
        const hh = String(d.getHours()).padStart(2, "0");
        const mm = String(d.getMinutes()).padStart(2, "0");
        const ss = String(d.getSeconds()).padStart(2, "0");
        return `${day}.${month} ${hh}:${mm}:${ss}`;
    },

    formatDateTime(ts) {
        return new Date(ts).toLocaleTimeString("tr-TR", {
            hour: "2-digit", minute: "2-digit", second: "2-digit",
        });
    },

    formatCurrency(n) {
        return "₺" + n.toFixed(2);
    },

    seedNews() {
        const seeds = [
            { title: "Piyasa istikrarlı bir şekilde açıldı", target: null, impact: 0 },
            { title: "İktisat Topluluğu haftalık toplantısı planlandı", target: null, impact: 0 },
        ];
        return seeds.map((s, i) => ({
            id: Date.now() - i * 5000,
            title: s.title,
            target: s.target,
            impact: s.impact,
            timestamp: Date.now() - i * 5000,
        }));
    },

    loadState() {
        try {
            const raw = localStorage.getItem(STORAGE_KEY);
            if (raw) {
                const parsed = JSON.parse(raw);
                this.state.news = parsed.news || [];
            }
        } catch (e) {
            console.warn("Failed to load from localStorage", e);
        }
        return false;
    },

    saveState() {
        try {
            localStorage.setItem(STORAGE_KEY, JSON.stringify({
                news: this.state.news,
            }));
        } catch (e) {
            console.warn("Failed to save to localStorage", e);
        }
    },

    async resetMarket() {
        if (!confirm("Haber akışı ve tüyolar silinsin mi? Hisse fiyatları, grafik geçmişi ve portföyler korunur.")) return false;
        const sb = (typeof window.sb !== "undefined" && window.sb) ? window.sb : null;
        if (!sb || !sb.rpc) throw new Error("Supabase bağlantısı hazır değil.");
        const { error } = await sb.rpc("admin_reset_market");
        if (error) throw error;
        this.state.news = [];
        this.saveState();
        await this.Realtime._loadInitialStocksFromDB();
        this.renderCommon();
        return true;
    },

    /* ===== ADMIN PANEL YARDIMCILARI =====
     * Sessiz fiyat manipülasyonu (habersiz) + Stock CRUD
     */

    // Admin: yeni hisse ekle. color opsiyonel, atanmazsa rastgele.
    addStock({ symbol, name, price }) {
        symbol = String(symbol || "").trim().toUpperCase();
        name = String(name || "").trim();
        const p = Math.max(0.05, Number(price) || 0);
        if (!symbol || !name) throw new Error("Sembol ve isim gerekli.");
        if (this.state.stocks[symbol]) throw new Error("Bu sembol zaten var.");
        if (!(p > 0)) throw new Error("Başlangıç fiyatı pozitif olmalı.");
        const palette = ["#f59e0b", "#10b981", "#3b82f6", "#a855f7", "#ef4444", "#ec4899", "#14b8a6", "#f97316"];
        const color = palette[Object.keys(this.state.stocks).length % palette.length];
        const base = this.round2(p);
        this.state.stocks[symbol] = {
            name,
            symbol,
            color,
            price: this.round2(p),
            previousClose: this.round2(p),
            change: 0,
            changePct: 0,
            history: [],
            shares: 100000,
        };
        if (!this.state.selectedStock) this.state.selectedStock = symbol;
        this.saveState();
        this.renderCommon();
        return this.state.stocks[symbol];
    },

    // Admin: mevcut hissenin ismini/sembolünü değiştirir. Eğer symbol değişirse anahtar da değişir.
    editStock(oldSymbol, { symbol, name }) {
        const stock = this.state.stocks[oldSymbol];
        if (!stock) throw new Error("Hisse bulunamadı.");
        symbol = String(symbol || "").trim().toUpperCase();
        name = String(name || "").trim();
        if (!symbol || !name) throw new Error("Sembol ve isim gerekli.");
        if (symbol !== oldSymbol) {
            if (this.state.stocks[symbol]) throw new Error("Yeni sembol zaten kullanımda.");
            this.state.stocks[symbol] = stock;
            stock.symbol = symbol;
            delete this.state.stocks[oldSymbol];
            if (this.state.selectedStock === oldSymbol) this.state.selectedStock = symbol;
        }
        if (name) stock.name = name;
        this.saveState();
        this.renderCommon();
        return this.state.stocks[symbol];
    },

    // Admin: hisseyi tamamen kaldırır.
    deleteStock(symbol) {
        if (!this.state.stocks[symbol]) throw new Error("Hisse bulunamadı.");
        delete this.state.stocks[symbol];
        if (this.state.selectedStock === symbol) {
            const syms = Object.keys(this.state.stocks);
            this.state.selectedStock = syms[0] || null;
        }
        this.saveState();
        this.renderCommon();
        return true;
    },

    publishNews({ title, target, impact }) {
        const newsItem = {
            id: Date.now(),
            title: title,
            target: target || null,
            impact: Number(impact) || 0,
            timestamp: Date.now(),
        };
        this.state.news.unshift(newsItem);
        if (this.state.news.length > 150) this.state.news.pop();
        if (target && this.state.stocks[target]) {
            this.applyNewsImpact(target, Number(impact) || 0);
        }
        this.saveState();
        return newsItem;
    },

    escapeHtml(str) {
        const div = document.createElement("div");
        div.textContent = String(str || "");
        return div.innerHTML;
    },

    flashCard(symbol, isUp) {
        setTimeout(() => {
            const card = document.querySelector(`.stock-card[data-symbol="${symbol}"]`);
            if (card) {
                card.classList.add(isUp ? "flash-up" : "flash-down");
                setTimeout(() => {
                    card.classList.remove("flash-up", "flash-down");
                }, 800);
            }
        }, 50);
    },

    renderStocksGrid({ onSelect } = {}) {
        const grid = document.getElementById("stocksGrid");
        if (!grid) return;
        const symbols = Object.keys(this.state.stocks);
        grid.innerHTML = "";
        symbols.forEach(sym => {
            const s = this.state.stocks[sym];
            const isUp = s.changePct >= 0;
            const card = document.createElement("div");
            card.className = `stock-card ${isUp ? "up" : "down"} ${this.state.selectedStock === sym ? "selected" : ""}`;
            card.dataset.symbol = sym;
            card.innerHTML = `
                <div class="stock-avatar" style="background: linear-gradient(135deg, ${s.color}, ${s.color}aa);">
                    ${s.name.charAt(0).toUpperCase()}
                </div>
                <div class="stock-body">
                    <div class="stock-name">${s.name}</div>
                    <div class="stock-symbol">${s.symbol}</div>
                    <div class="stock-price-row">
                        <div class="stock-price">${this.formatCurrency(s.price)}</div>
                        <div class="stock-change ${isUp ? "up" : "down"}">
                            ${isUp ? "▲" : "▼"} ${Math.abs(s.changePct).toFixed(2)}%
                        </div>
                    </div>
                </div>
            `;
            card.addEventListener("click", () => {
                this.state.selectedStock = sym;
                const sel = document.getElementById("stockSelector");
                if (sel) sel.value = sym;
                this.renderStocksGrid({ onSelect });
                this.renderChart();
                this.Realtime.loadPriceHistory(sym).then(() => {
                    if (this.state.selectedStock === sym) this.renderChart();
                });
                if (typeof onSelect === "function") onSelect(sym);
            });
            grid.appendChild(card);
        });
    },

    renderStockSelector() {
        const sel = document.getElementById("stockSelector");
        if (sel) {
            sel.innerHTML = "";
            Object.values(this.state.stocks).forEach(s => {
                const opt = document.createElement("option");
                opt.value = s.symbol;
                opt.textContent = `${s.name} (${s.symbol})`;
                if (s.symbol === this.state.selectedStock) opt.selected = true;
                sel.appendChild(opt);
            });
            sel.onchange = (e) => {
                this.state.selectedStock = e.target.value;
                this.renderStocksGrid();
                this.renderChart();
                this.Realtime.loadPriceHistory(e.target.value).then(() => {
                    if (this.state.selectedStock === e.target.value) this.renderChart();
                });
            };
        }
        const tgt = document.getElementById("targetPerson");
        if (tgt) {
            tgt.innerHTML = '<option value="">Kişi seçin...</option>';
            Object.values(this.state.stocks).forEach(s => {
                const opt = document.createElement("option");
                opt.value = s.symbol;
                opt.textContent = `${s.name} (${s.symbol})`;
                tgt.appendChild(opt);
            });
        }
    },

    renderTickerTape() {
        const el = document.getElementById("tickerContent");
        if (!el) return;
        const symbols = Object.keys(this.state.stocks);
        const build = () => symbols.map(sym => {
            const s = this.state.stocks[sym];
            const isUp = s.changePct >= 0;
            const color = isUp ? "var(--green-bright)" : "var(--red-bright)";
            const arrow = isUp ? "▲" : "▼";
            return `
                <span class="ticker-item">
                    <span class="ticker-name">${s.symbol}</span>
                    <span class="ticker-price">${this.formatCurrency(s.price)}</span>
                    <span style="color:${color};font-family:Consolas,monospace;">${arrow} ${Math.abs(s.changePct).toFixed(2)}%</span>
                </span>
            `;
        }).join("");
        el.innerHTML = build() + build();
    },

    renderMarketCap() {
        const el = document.getElementById("totalMarketCap");
        if (!el) return;
        const total = Object.values(this.state.stocks).reduce((sum, s) => sum + s.price * s.shares, 0);
        let formatted;
        if (total >= 1e9) formatted = "₺" + (total / 1e9).toFixed(2) + "B";
        else if (total >= 1e6) formatted = "₺" + (total / 1e6).toFixed(2) + "M";
        else formatted = "₺" + total.toLocaleString();
        el.textContent = "Piyasa Hacmi: " + formatted;
    },

    renderChart() {
        const canvas = document.getElementById("priceChart");
        if (!canvas || typeof Chart !== "function") return;
        const ctx = canvas.getContext("2d");
        const sym = this.state.selectedStock || Object.keys(this.state.stocks)[0];
        const stock = this.state.stocks[sym];
        if (!stock) return;
        const labels = stock.history.map(p => this.formatTime(p.time));
        const data = stock.history.map(p => p.price);
        const isUp = stock.changePct >= 0;
        const lineColor = isUp ? "#10b981" : "#ef4444";
        const bgColor = isUp ? "rgba(16, 185, 129, 0.15)" : "rgba(239, 68, 68, 0.15)";
        const chartColors = (this.Theme && this.Theme._chartColors)
            ? this.Theme._chartColors()
            : {
                tooltipBg: "#1a2236", tooltipTitle: "#e5e7eb", tooltipBody: "#9ca3af",
                tooltipBorder: "#2a3550", grid: "rgba(42, 53, 80, 0.5)", ticks: "#6b7280",
            };
        if (this.priceChart) this.priceChart.destroy();
        this.priceChart = new Chart(ctx, {
            type: "line",
            data: {
                labels: labels,
                datasets: [{
                    label: `${stock.name} (${stock.symbol})`,
                    data: data,
                    borderColor: lineColor,
                    backgroundColor: bgColor,
                    borderWidth: 2.5,
                    fill: true,
                    tension: 0.35,
                    pointRadius: data.length === 1 ? 3 : 0,
                    pointHoverRadius: 5,
                    pointHoverBackgroundColor: lineColor,
                    pointHoverBorderColor: "#fff",
                    pointHoverBorderWidth: 2,
                }],
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                interaction: { mode: "index", intersect: false },
                plugins: {
                    legend: { display: false },
                    tooltip: {
                        backgroundColor: chartColors.tooltipBg,
                        titleColor: chartColors.tooltipTitle,
                        bodyColor: chartColors.tooltipBody,
                        borderColor: chartColors.tooltipBorder,
                        borderWidth: 1,
                        padding: 10,
                        displayColors: false,
                        callbacks: { label: (ctx) => this.formatCurrency(ctx.parsed.y) },
                    },
                },
                scales: {
                    x: {
                        grid: { color: chartColors.grid, drawBorder: false },
                        ticks: {
                            color: chartColors.ticks, maxRotation: 0, autoSkip: true,
                            maxTicksLimit: 8, font: { size: 10 },
                        },
                    },
                    y: {
                        grid: { color: chartColors.grid, drawBorder: false },
                        ticks: {
                            color: chartColors.ticks,
                            callback: (val) => this.formatCurrency(val),
                            font: { size: 10 },
                        },
                    },
                },
            },
        });
        this._chartSymbol = sym;
        this.priceChart.$historyTimestamps = stock.history.map(point => Number(point.time));
    },

    updateLiveChart(stock) {
        if (!this.priceChart || this._chartSymbol !== stock.symbol) {
            if (this.state.selectedStock === stock.symbol) this.renderChart();
            return;
        }

        const chart = this.priceChart;
        const dataset = chart.data.datasets[0];
        const timestamps = chart.$historyTimestamps || [];
        const history = (stock.history || []).slice(-5760);
        const lastTimestamp = timestamps.length ? timestamps[timestamps.length - 1] : -Infinity;
        const newPoints = history.filter(point => Number(point.time) > lastTimestamp);

        newPoints.forEach(point => {
            chart.data.labels.push(this.formatTime(point.time));
            dataset.data.push(Number(point.price));
            timestamps.push(Number(point.time));
        });

        if (newPoints.length === 0 && history.length && timestamps.length) {
            const lastPoint = history[history.length - 1];
            if (Number(lastPoint.time) === timestamps[timestamps.length - 1]) {
                dataset.data[dataset.data.length - 1] = Number(lastPoint.price);
            }
        }

        while (timestamps.length > 5760) {
            timestamps.shift();
            chart.data.labels.shift();
            dataset.data.shift();
        }
        chart.$historyTimestamps = timestamps;
        chart.update("none");
    },

    renderNewsFeed() {
        const el = document.getElementById("newsFeed");
        if (!el) return;
        if (this.state.news.length === 0) {
            el.innerHTML = `
                <div class="empty-state">
                    <div class="empty-state-icon">📰</div>
                    <p>Henüz haber yok. Yakında tekrar kontrol edin!</p>
                </div>
            `;
            return;
        }
        const sorted = [...this.state.news].sort((a, b) => b.timestamp - a.timestamp);
        el.innerHTML = "";
        sorted.forEach(n => {
            const impact = Number(n.impact) || 0;
            const positive = impact > 0;
            const negative = impact < 0;
            const classes = ["news-item"];
            if (positive) classes.push("positive");
            if (negative) classes.push("negative");
            const targetInfo = n.target && this.state.stocks[n.target]
                ? `<span class="news-target">${this.state.stocks[n.target].name}</span>`
                : `<span class="news-target" style="background: rgba(107,114,128,0.15); color: var(--text-secondary);">Piyasa</span>`;
            let impactInfo;
            if (impact !== 0) {
                impactInfo = `<span class="news-impact ${positive ? "positive" : "negative"}">${positive ? "▲" : "▼"} %${Math.abs(impact).toFixed(1)}</span>`;
            } else {
                impactInfo = `<span class="news-impact" style="background: rgba(107,114,128,0.15); color: var(--text-muted);">Nötr</span>`;
            }
            const item = document.createElement("div");
            item.className = classes.join(" ");
            item.innerHTML = `
                <div class="news-header">
                    <div class="news-title">${this.escapeHtml(n.title)}</div>
                    <span class="news-time">${this.formatDateTime(n.timestamp)}</span>
                </div>
                <div class="news-meta">
                    ${targetInfo}
                    ${impactInfo}
                </div>
            `;
            el.appendChild(item);
        });
    },

    updateClock() {
        const el = document.getElementById("currentTime");
        if (!el) return;
        el.textContent = this.formatDateTime(Date.now());
    },

    startAutoUpdates() {
        if (this._clockInterval) clearInterval(this._clockInterval);
        this.updateClock();
        this._clockInterval = setInterval(() => this.updateClock(), 1000);

    },

    renderCommon({ onStockSelect } = {}) {
        this.renderStocksGrid({ onSelect: onStockSelect });
        this.renderStockSelector();
        this.renderTickerTape();
        this.renderMarketCap();
        this.renderChart();
        this.renderNewsFeed();
    },

    ensureInitialized() {
        this.loadState();
        const symbols = Object.keys(this.state.stocks);
        if (!this.state.selectedStock || !this.state.stocks[this.state.selectedStock]) {
            this.state.selectedStock = symbols[0];
        }
    },

    /* =========================================================
     *  SUPABASE REALTIME ENTEGRASYONU (Canlı Senkronizasyon)
     * =========================================================
     * - Tek doğruluk kaynağı (SSOT): Supabase stocks tablosu
     * - Clientlar: postgres_changes dinleyicisiyle canlı güncelleme alır
    * - Fiyat mutations are committed through Supabase RPCs.
     */
    Realtime: {
        _chan: null,
        _statusChan: null,
        _appSettingsChan: null,
        _newsChan: null,
        _bound: false,
        _enabled: false,
        _lastStatus: null,

        _sb() {
            return (typeof window.sb !== "undefined" && window.sb) ? window.sb : null;
        },

        isEnabled() {
            return this._enabled === true;
        },

        _normalizeStockRow(row) {
            if (!row) return null;
            const symbol = String(row.symbol || row.code || "").trim().toUpperCase();
            if (!symbol) return null;
            const name = String(row.name || row.stock_name || symbol).trim();
            const price = Number(row.current_price ?? row.price ?? 0);
            const previousClose = Number(row.previous_close ?? row.open_price ?? price);
            const change = Number(row.change ?? Borsa.round2(price - previousClose));
            const changePct = Number(row.change_pct ?? Borsa.round2(previousClose > 0 ? (change / previousClose) * 100 : 0));
            const color = String(row.color || "#3b82f6").trim();
            const shares = Number(row.shares ?? row.shares_outstanding ?? row.total_shares ?? 100000);
            const updatedAt = row.updated_at ? new Date(row.updated_at).getTime() : Date.now();
            let history = null;
            try {
                if (row.price_history && Array.isArray(row.price_history) && row.price_history.length > 0) {
                    history = row.price_history.map(h => ({
                        time: Number(h.time ?? h.t ?? Date.now()),
                        price: Borsa.round2(Number(h.price ?? h.p ?? price)),
                    }));
                }
            } catch (_) { history = null; }
            if (!history || history.length === 0) {
                // Eski JSONB kolonu bossa yeni price_history (ROW tablosundan) cek
                history = (row.__history && Array.isArray(row.__history))
                    ? row.__history.map(h => ({
                        time: h.recorded_at ? new Date(h.recorded_at).getTime() : Date.now(),
                        price: Borsa.round2(Number(h.price ?? price)),
                    }))
                    : (Borsa.state.stocks[symbol]?.history || []).slice();
            }
            const last = history[history.length - 1];
            if (!last || Number(last.time) < updatedAt || Math.abs(Number(last.price) - price) > 0.01) {
                history.push({ time: updatedAt, price: Borsa.round2(price) });
            }
            if (history.length > 5760) history = history.slice(-5760);
            return {
                name,
                symbol,
                color,
                price: Borsa.round2(price),
                previousClose: Borsa.round2(previousClose),
                change: Borsa.round2(change),
                changePct: Borsa.round2(changePct),
                history,
                shares: Math.max(1, Math.floor(shares)),
                _src: "supabase",
                _updatedAt: updatedAt,
            };
        },

        async _loadInitialStocksFromDB() {
            const sb = this._sb();
            if (!sb) return false;
            try {
                const { data: stockRows, error } = await sb
                    .from("stocks")
                    .select("*")
                    .order("symbol", { ascending: true });
                if (error) {
                    console.warn("[Realtime] stocks tablosu okunamadi:", error.message);
                    return false;
                }
                if (!Array.isArray(stockRows) || stockRows.length === 0) return false;

                const symbols = stockRows.map(row => String(row.symbol || "").toUpperCase()).filter(Boolean);
                const historyBySymbol = {};
                const { data: historyRows, error: historyError } = await sb
                    .from("price_history")
                    .select("symbol, price, recorded_at")
                    .in("symbol", symbols)
                    .order("recorded_at", { ascending: false })
                    .limit(Math.min(symbols.length * 100, 1000));
                if (historyError) {
                    console.warn("[Realtime] price_history okunamadi:", historyError.message);
                } else {
                    (historyRows || []).forEach(point => {
                        const sym = String(point.symbol || "").toUpperCase();
                        if (!historyBySymbol[sym]) historyBySymbol[sym] = [];
                        historyBySymbol[sym].push(point);
                    });
                }

                const normalized = {};
                stockRows.forEach(row => {
                    const sym = String(row.symbol || "").toUpperCase();
                    const normalizedRow = Object.assign({}, row, {
                        __history: (historyBySymbol[sym] || []).sort(
                            (a, b) => new Date(a.recorded_at).getTime() - new Date(b.recorded_at).getTime()
                        ),
                    });
                    const stock = this._normalizeStockRow(normalizedRow);
                    if (stock) normalized[stock.symbol] = stock;
                });
                const loadedSymbols = Object.keys(normalized);
                if (loadedSymbols.length === 0) return false;
                Borsa.state.stocks = normalized;
                Borsa.state.news = Borsa.state.news || Borsa.seedNews();
                await this._loadInitialNewsFromDB();
                if (!Borsa.state.selectedStock || !Borsa.state.stocks[Borsa.state.selectedStock]) {
                    Borsa.state.selectedStock = loadedSymbols[0];
                }
                console.log(`[Realtime] DB'den ${loadedSymbols.length} hisse yüklendi + price_history.`);
                return true;
            } catch (e) {
                console.warn("[Realtime] Ilk hisse yukleme hatasi:", e && e.message || e);
                return false;
            }
        },

        async loadPriceHistory(symbol) {
            const sb = this._sb();
            const stock = Borsa.state.stocks[symbol];
            if (!sb || !stock) return false;
            try {
                const rows = [];
                for (let from = 0; from < 5760; from += 1000) {
                    const { data, error } = await sb
                        .from("price_history")
                        .select("price, recorded_at")
                        .eq("symbol", symbol)
                        .order("recorded_at", { ascending: false })
                        .range(from, Math.min(from + 999, 5759));
                    if (error) throw error;
                    rows.push(...(data || []));
                    if (!data || data.length < 1000) break;
                }

                const history = rows.reverse().map(point => ({
                    time: new Date(point.recorded_at).getTime(),
                    price: Borsa.round2(Number(point.price)),
                }));
                const latest = history[history.length - 1];
                if (!latest || latest.time < stock._updatedAt || Math.abs(latest.price - stock.price) > 0.01) {
                    history.push({ time: Math.max(stock._updatedAt, Date.now()), price: stock.price });
                }
                stock.history = history.slice(-5760);
                return true;
            } catch (e) {
                console.warn(`[Realtime] ${symbol} fiyat geçmişi okunamadı:`, e && e.message || e);
                return false;
            }
        },

        async _loadInitialNewsFromDB() {
            const sb = this._sb();
            if (!sb) return;
            try {
                const { data, error } = await sb
                    .from("news_feed")
                    .select("id, title, stock_symbol, impact_pct, created_at")
                    .order("created_at", { ascending: false })
                    .limit(50);
                if (error || !data || !Array.isArray(data)) return;
                const mapped = data.map(n => ({
                    id: Number(n.id || Date.now()),
                    title: String(n.title || ""),
                    target: String(n.stock_symbol || "").trim() || null,
                    impact: Number(n.impact_pct || 0),
                    timestamp: n.created_at ? new Date(n.created_at).getTime() : Date.now(),
                }));
                if (mapped.length > 0) {
                    Borsa.state.news = mapped.concat(Borsa.state.news || []).slice(0, 150);
                }
            } catch (_) {}
        },

        _handleNewsEvent(evt) {
            if (!evt || evt.eventType !== "INSERT" || !evt.new) return;
            const n = evt.new;
            const item = {
                id: Number(n.id || Date.now()),
                title: String(n.title || ""),
                target: String(n.stock_symbol || "").trim() || null,
                impact: Number(n.impact_pct || 0),
                timestamp: n.created_at ? new Date(n.created_at).getTime() : Date.now(),
            };
            if (!item.title) return;
            if (Borsa.state.news.some(existing => String(existing.id) === String(item.id))) return;
            Borsa.state.news.unshift(item);
            if (Borsa.state.news.length > 150) Borsa.state.news.pop();
            try { Borsa.renderNewsFeed(); } catch (_) {}
            try { Borsa.saveState(); } catch (_) {}
        },

        updateOneStockFromPayload(stockRow, { flash = true, render = true } = {}) {
            if (!stockRow) return;
            const normalized = this._normalizeStockRow(stockRow);
            if (!normalized) return;
            const sym = normalized.symbol;
            const old = Borsa.state.stocks[sym];
            const priceChanged = !old || Math.abs(Number(old.price) - Number(normalized.price)) > 0.001;
            const wasUp = old && old.changePct >= 0;
            Borsa.state.stocks[sym] = normalized;
            if (!Borsa.state.selectedStock) Borsa.state.selectedStock = sym;
            if (flash && priceChanged) {
                const isUp = normalized.changePct >= 0;
                if (!old || wasUp !== isUp || priceChanged) {
                    Borsa.flashCard(sym, isUp);
                }
            }
            if (render) {
                try { Borsa.renderStocksGrid(); } catch (_) {}
                try { Borsa.renderTickerTape(); } catch (_) {}
                try { Borsa.renderMarketCap(); } catch (_) {}
                if (Borsa.state.selectedStock === sym) {
                    try { Borsa.updateLiveChart(normalized); } catch (_) {}
                }
                try { Borsa.saveState(); } catch (_) {}
            }
        },

        removeOneStock(symbol) {
            symbol = String(symbol || "").trim().toUpperCase();
            if (!symbol) return;
            if (!Borsa.state.stocks[symbol]) return;
            delete Borsa.state.stocks[symbol];
            if (Borsa.state.selectedStock === symbol) {
                const syms = Object.keys(Borsa.state.stocks);
                Borsa.state.selectedStock = syms[0] || null;
            }
            try { Borsa.renderCommon(); } catch (_) {}
            try { Borsa.saveState(); } catch (_) {}
        },

        _handleStockEvent(evt) {
            const eType = String(evt && evt.eventType || "").toLowerCase();
            if (!eType) return;
            if (eType === "insert" || eType === "update") {
                this.updateOneStockFromPayload(evt.new);
            } else if (eType === "delete") {
                const old = evt && evt.old;
                if (old) this.removeOneStock(old.symbol || old.code);
            }
        },

        _handleAppSettingsEvent(evt) {
            if (!evt || !evt.new) return;
            const val = evt.new;
            if (typeof val.maintenance_mode !== "undefined" &&
                typeof window.BorsaMaintenance !== "undefined" &&
                typeof window.BorsaMaintenance.checkAndRedirect === "function") {
                try { window.BorsaMaintenance.checkAndRedirect(); } catch (_) {}
            }
            if (typeof val.market_open !== "undefined") {
                const pill = document.getElementById("marketStatusPill");
                if (pill) {
                    const open = !!val.market_open;
                    pill.textContent = open ? "PİYASA AÇIK" : "PİYASA KAPALI";
                    pill.classList.toggle("market-open", open);
                    pill.classList.toggle("market-closed", !open);
                }
            }
            window.dispatchEvent(new CustomEvent("borsa:app-settings-updated", { detail: val }));
        },

        _handleTransactionEvent(evt) {
            if (!evt || !evt.new) return;
            if (typeof window.BorsaFirebase !== "undefined" &&
                typeof window.BorsaFirebase._user === "object" && window.BorsaFirebase._user &&
                typeof window.BorsaFirebase.refreshUserDoc === "function") {
                if (evt.new.user_id === window.BorsaFirebase._user.id) {
                    try { window.BorsaFirebase.refreshUserDoc(); } catch (_) {}
                }
            }
            window.dispatchEvent(new CustomEvent("borsa:new-transaction", { detail: evt.new }));
        },

        start() {
            if (this._bound) return;
            const sb = this._sb();
            if (!sb || typeof sb.channel !== "function") {
                console.warn("[Realtime] Supabase client hazır değil, canlı senkronizasyon ATLANDI.");
                return;
            }
            this._bound = true;
            this._enabled = true;
            const onStatus = (st) => {
                this._lastStatus = st;
                console.log(`[Realtime] Bağlantı durumu: ${st}`);
                window.dispatchEvent(new CustomEvent("borsa:realtime-status", { detail: { status: st } }));
            };
            try {
                this._chan = sb
                    .channel("borsa-stocks-public", { config: { broadcast: { self: false } } })
                    .on("postgres_changes",
                        { event: "*", schema: "public", table: "stocks" },
                        (payload) => this._handleStockEvent(payload)
                    )
                    .subscribe(onStatus);
            } catch (e) {
                console.warn("[Realtime] stocks kanalı açılamadı:", e);
            }
            try {
                this._appSettingsChan = sb
                    .channel("borsa-app-settings")
                    .on("postgres_changes",
                        { event: "UPDATE", schema: "public", table: "app_settings", filter: "id=eq.1" },
                        (payload) => this._handleAppSettingsEvent(payload)
                    )
                    .subscribe();
            } catch (e) {
                console.warn("[Realtime] app_settings kanalı açılamadı:", e);
            }
            try {
                this._statusChan = sb
                    .channel("borsa-transactions-public")
                    .on("postgres_changes",
                        { event: "INSERT", schema: "public", table: "transactions" },
                        (payload) => this._handleTransactionEvent(payload)
                    )
                    .subscribe();
            } catch (e) {
                console.warn("[Realtime] transactions kanalı açılamadı:", e);
            }
            try {
                this._newsChan = sb
                    .channel("borsa-news-public")
                    .on("postgres_changes",
                        { event: "INSERT", schema: "public", table: "news_feed" },
                        (payload) => this._handleNewsEvent(payload)
                    )
                    .subscribe();
            } catch (e) {
                console.warn("[Realtime] news_feed kanalı açılamadı:", e);
            }
            try {
                window.addEventListener("beforeunload", () => this.stop(), { once: true });
            } catch (_) {}
        },

        stop() {
            const sb = this._sb();
            if (!sb || typeof sb.removeChannel !== "function") return;
            [this._chan, this._statusChan, this._appSettingsChan, this._newsChan].forEach(c => {
                if (!c) return;
                try { sb.removeChannel(c); } catch (_) {}
            });
            this._chan = null;
            this._statusChan = null;
            this._appSettingsChan = null;
            this._bound = false;
            this._enabled = false;
            console.log("[Realtime] Kanallar kapatıldı.");
        },
    },

    async bumpPricePercent(symbol, percent) {
        const stock = this.state.stocks[symbol];
        if (!stock) return;
        const newPrice = stock.price * (1 + Number(percent) / 100);
        return await this.setPrice(symbol, newPrice);
    },

    applyNewsImpact(symbol, impactPct) {
        const stock = this.state.stocks[symbol];
        if (!stock) return;
        const sb = (typeof window.sb !== "undefined" && window.sb) ? window.sb : null;
        if (sb && sb.rpc) {
            sb.rpc("admin_apply_news_impact", {
                p_symbol: symbol,
                p_impact_pct: Number(impactPct) || 0,
            }).catch(err => {
                console.warn("[Realtime] admin_apply_news_impact RPC başarısız:", err && err.message || err);
            });
            return;
        }
        console.warn("[Realtime] Supabase RPC hazır değil; haber etkisi uygulanmadı.");
    },

    async setPrice(symbol, exactPriceTL) {
        const stock = this.state.stocks[symbol];
        if (!stock) throw new Error("Hisse bulunamadı.");
        const sb = (typeof window.sb !== "undefined" && window.sb) ? window.sb : null;
        if (!sb || !sb.rpc) throw new Error("Supabase bağlantısı hazır değil.");
        const p = Math.max(0.05, Number(exactPriceTL) || 0);
        const { data, error } = await sb.rpc("admin_set_stock_price", {
            p_symbol: symbol,
            p_price: Number(this.round2(p)),
        });
        if (error) throw error;
        const updated = Array.isArray(data) ? data[0] : data;
        if (!updated) throw new Error("Fiyat güncellendi yanıtı alınamadı.");
        this.Realtime.updateOneStockFromPayload(updated);
        return this.round2(Number(updated.current_price));
    },

    async publishNews({ title, target, impact }) {
        const impactPct = Number(impact) || 0;
        const sb = (typeof window.sb !== "undefined" && window.sb) ? window.sb : null;
        if (!sb || !sb.rpc) throw new Error("Supabase bağlantısı hazır değil.");
        const { data, error } = await sb.rpc("admin_publish_news", {
            p_title: String(title || "").slice(0, 280),
            p_symbol: target || null,
            p_impact_pct: impactPct,
        });
        if (error) throw error;
        const saved = Array.isArray(data) ? data[0] : data;
        if (!saved) throw new Error("Haber kaydedildi yanıtı alınamadı.");
        const newsItem = {
            id: Number(saved.id || Date.now()),
            title: String(saved.title || title || ""),
            target: String(saved.stock_symbol || target || "").trim() || null,
            impact: Number(saved.impact_pct ?? impactPct),
            timestamp: saved.created_at ? new Date(saved.created_at).getTime() : Date.now(),
        };
        if (!this.state.news.some(item => String(item.id) === String(newsItem.id))) {
            this.state.news.unshift(newsItem);
            if (this.state.news.length > 150) this.state.news.pop();
        }
        this.saveState();
        try { this.renderNewsFeed(); } catch (_) {}
        return newsItem;
    },

    Theme: {
        _storageKey: "borsa_theme_pref_v1",
        _lightClass: "light-mode",

        _isLight() {
            return document.body.classList.contains(this._lightClass);
        },

        _chartColors() {
            if (this._isLight()) {
                return {
                    tooltipBg: "#ffffff",
                    tooltipTitle: "#0f172a",
                    tooltipBody: "#334155",
                    tooltipBorder: "#e2e8f0",
                    grid: "rgba(148, 163, 184, 0.4)",
                    ticks: "#64748b",
                };
            }
            return {
                tooltipBg: "#1a2236",
                tooltipTitle: "#e5e7eb",
                tooltipBody: "#9ca3af",
                tooltipBorder: "#2a3550",
                grid: "rgba(42, 53, 80, 0.5)",
                ticks: "#6b7280",
            };
        },

        _updateIcons() {
            const icons = document.querySelectorAll(".theme-toggle .theme-icon");
            icons.forEach(el => {
                el.textContent = this._isLight() ? "☀️" : "🌙";
            });
        },

        _reRenderChartIfOwner() {
            if (typeof Borsa !== "undefined" && Borsa.priceChart) {
                Borsa.renderChart();
            }
        },

        _apply(theme) {
            const isLight = theme === "light";
            document.body.classList.toggle(this._lightClass, isLight);
            document.documentElement.style.colorScheme = isLight ? "light" : "dark";
            this._updateIcons();
        },

        _save(theme) {
            try { localStorage.setItem(this._storageKey, theme); } catch (e) {}
        },

        _load() {
            try {
                const v = localStorage.getItem(this._storageKey);
                return v === "light" ? "light" : "dark";
            } catch (e) { return "dark"; }
        },

        toggle() {
            const next = this._isLight() ? "dark" : "light";
            this._apply(next);
            this._save(next);
            this._reRenderChartIfOwner();
        },

        bindToggle(buttonId) {
            const btn = document.getElementById(buttonId);
            if (!btn) return;
            btn.onclick = () => this.toggle();
            const icon = btn.querySelector(".theme-icon");
            if (icon) icon.textContent = this._isLight() ? "☀️" : "🌙";
        },

        bindAllToggles() {
            document.querySelectorAll(".theme-toggle").forEach((btn, i) => {
                const b = btn;
                if (b.dataset.bound === "1") return;
                b.dataset.bound = "1";
                b.addEventListener("click", () => this.toggle());
                const icon = b.querySelector(".theme-icon");
                if (icon) icon.textContent = this._isLight() ? "☀️" : "🌙";
            });
        },

        init() {
            const pref = this._load();
            this._apply(pref);
            this.bindAllToggles();
            const self = this;
            if (typeof window !== "undefined") {
                window.addEventListener("DOMContentLoaded", () => self.bindAllToggles(), { once: true });
            }
            if (document.readyState === "complete" || document.readyState === "interactive") {
                self.bindAllToggles();
            }
        },
    },

    async ensureInitializedWithRealtime() {
        this.ensureInitialized();
        let usedDB = false;
        try {
            if (this.Realtime && typeof this.Realtime._loadInitialStocksFromDB === "function") {
                usedDB = await this.Realtime._loadInitialStocksFromDB();
            }
        } catch (e) {
            console.warn("[Realtime] Başlangıç DB yüklemesi başarısız (fallback localStorage):", e && e.message || e);
        }
        if (usedDB && this.state.selectedStock) {
            await this.Realtime.loadPriceHistory(this.state.selectedStock);
        }
        try {
            if (this.Realtime && typeof this.Realtime.start === "function") {
                this.Realtime.start();
            }
        } catch (e) {
            console.warn("[Realtime] start() başarısız:", e);
        }
    },
};
