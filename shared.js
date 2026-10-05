const DEFAULT_MEMBERS = [
    { name: "Deniz",   symbol: "DEN",  color: "#3b82f6" },
    { name: "Ahmet",   symbol: "AHM",  color: "#ef4444" },
    { name: "Ayşe",    symbol: "AYS",  color: "#f59e0b" },
    { name: "Mehmet",  symbol: "MEH",  color: "#10b981" },
    { name: "Zeynep",  symbol: "ZEY",  color: "#8b5cf6" },
    { name: "Can",     symbol: "CAN",  color: "#ec4899" },
    { name: "Elif",    symbol: "ELI",  color: "#14b8a6" },
    { name: "Burak",   symbol: "BUR",  color: "#f97316" },
];

const STORAGE_KEY = "borsa_economics_club_v1";

const Borsa = {
    state: {
        stocks: {},
        news: [],
        selectedStock: null,
    },
    priceChart: null,
    /* =========================================================
     * FİYATLANDIRMA MOTORU / PRICING ENGINE — AYARLAMA KILAVUZU
     * =========================================================
     *
     * Doğal "rassal dalgalanma" (volatilite) 4 bileşenden oluşur:
     *
     * 1) ARKA PLAN TICK HIZI (KAÇ SANİYEDE BİR GÜNCELLEME)
     *    → startAutoUpdates() içinde, satır ~443:
     *      setInterval(() => this.randomMarketTick(), 4000)
     *      4000 ms = 4 sn.
     *
     *    Daha AGRESİF piyasa istiyorsan 2000 (2 sn), 1500, 1000 yap.
     *    Daha SABİT / DURAĞAN piyasa istiyorsan 6000 (6 sn), 8000, 10000 yap.
     *
     * 2) HER TICK'TE HANGİ ORANDA HİSSE FİYATI DEĞİŞİR
     *    → randomMarketTick() içinde, satır ~174:
     *      if (Math.random() < 0.4)  → %40 olasılıkla her hisse hareket eder.
     *
     *    Daha hareketli piyasa: 0.6 → %60, 0.7 → %70
     *    Daha durağan: 0.2 → %20, 0.15 → %15
     *
     * 3) TEK BİR HAREKETİN BÜYÜKLÜĞÜ (VOLATİLİTE)
     *    → randomMarketTick() içinde, satır ~176:
     *      const volatility = (Math.random() - 0.5) * 0.018;
     *
     *    0.018 → % -0,90  ~  +0,90 aralığında (her tick için).
     *    Çift yönlü: (Math.random()-0.5) -0.5 ile +0.5 arasındadır.
     *    Çarpan (0.018) VOLATİLİTE KATSAYISIDIR:
     *      0.01  → % -0,5  ~  +0,5  (çok stabil, düşük oynaklık)
     *      0.03  → % -1,5  ~  +1,5  (daha agresif)
     *      0.05  → % -2,5  ~  +2,5  (yüksek oynaklık — crypto tadında)
     *
     * 4) İLK GEÇMİŞ (HİSTORY) OLUŞTURURKENKİ VOLATİLİTE
     *    → _generatePriceHistory() içinde, satır ~51:
     *      const volatility = (Math.random() - 0.5) * 0.04;
     *
     *    Bu, chart'ın grafiğinin başlangıç seviyesini belirler (geçmiş 40 bar).
     *    0.04 → her 1 dklık bar için % -2 ~ +2 arası.
     *
     *
     * HABER (NEWS) ETKİSİ:
     *    applyNewsImpact(symbol, impactPct)  satır ~137
     *    impactPct = Admin panel'den -15 ~ +15 girilebilen yüzde etkisi.
     *    Örn: +8 → fiyat %8 artar, -12 → fiyat %12 düşer.
     *    Haber etkisi ANLIKTIR; randomMarketTick() ile aynı "history push"
     *    mekanizmasını kullanır ve bir sonraki tick'te devam eder.
     *
     * ÖNEMLİ NOT: Fiyatları "manuel, sessizce" değiştirmek istiyorsan
     *    Admin paneldeki "Sessiz Fiyat Manipülasyonu" aracını kullan.
     *    Bu fonksiyonları (applyNewsImpact / randomMarketTick) elle
     *    çağırmana GEREK KALMAZ; admin scriptinde Borsa.setPrice(sym, p)
     *    veya Borsa.bumpPricePercent(sym, pct) var.
     * =========================================================
     */

    _tickInterval: null,
    _clockInterval: null,

    round2(n) {
        return Math.round(n * 100) / 100;
    },

    formatTime(ts) {
        const d = new Date(ts);
        const hh = String(d.getHours()).padStart(2, "0");
        const mm = String(d.getMinutes()).padStart(2, "0");
        return `${hh}:${mm}`;
    },

    formatDateTime(ts) {
        return new Date(ts).toLocaleTimeString("tr-TR", {
            hour: "2-digit", minute: "2-digit", second: "2-digit",
        });
    },

    formatCurrency(n) {
        return "₺" + n.toFixed(2);
    },

    _generatePriceHistory(basePrice, points = 30) {
        const history = [];
        let price = basePrice;
        const now = Date.now();
        const interval = 60000;
        for (let i = points - 1; i >= 0; i--) {
            // [AYAR] İlk 40 bar (geçmiş grafiği) için VOLATİLİTE:
            // 0.04 → ±%2 / bar (1 dklık). 0.02= sakin, 0.06= çalkantılı.
            const volatility = (Math.random() - 0.5) * 0.04;
            price = Math.max(1, price * (1 + volatility));
            history.push({
                time: now - i * interval,
                price: this.round2(price),
            });
        }
        return history;
    },

    initStocks() {
        const stocks = {};
        DEFAULT_MEMBERS.forEach(m => {
            const basePrice = 50 + Math.random() * 150;
            const history = this._generatePriceHistory(basePrice, 40);
            const currentPrice = history[history.length - 1].price;
            const startPrice = history[0].price;
            const change = this.round2(currentPrice - startPrice);
            const changePct = this.round2((change / startPrice) * 100);
            stocks[m.symbol] = {
                name: m.name,
                symbol: m.symbol,
                color: m.color,
                price: currentPrice,
                previousClose: startPrice,
                change: change,
                changePct: changePct,
                history: history,
                shares: Math.floor(100000 + Math.random() * 500000),
            };
        });
        return stocks;
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
                if (parsed.stocks && Object.keys(parsed.stocks).length > 0) {
                    this.state.stocks = parsed.stocks;
                    this.state.news = parsed.news || [];
                    return true;
                }
            }
        } catch (e) {
            console.warn("Failed to load from localStorage", e);
        }
        return false;
    },

    saveState() {
        try {
            localStorage.setItem(STORAGE_KEY, JSON.stringify({
                stocks: this.state.stocks,
                news: this.state.news,
            }));
        } catch (e) {
            console.warn("Failed to save to localStorage", e);
        }
    },

    resetMarket() {
        if (!confirm("Tüm piyasayı sıfırlamak istiyor musunuz? Tüm fiyatlar ve haberler silinecektir.")) return false;
        this.state.stocks = this.initStocks();
        this.state.news = this.seedNews();
        const symbols = Object.keys(this.state.stocks);
        this.state.selectedStock = symbols[0];
        this.saveState();
        return true;
    },

    applyNewsImpact(symbol, impactPct) {
        const stock = this.state.stocks[symbol];
        if (!stock) return;
        const oldPrice = stock.price;
        const newPrice = this.round2(Math.max(0.5, oldPrice * (1 + impactPct / 100)));
        stock.price = newPrice;
        stock.history.push({
            time: Date.now(),
            price: newPrice,
        });
        if (stock.history.length > 200) stock.history.shift();
        const change = this.round2(newPrice - stock.previousClose);
        stock.change = change;
        stock.changePct = this.round2((change / stock.previousClose) * 100);
        this.flashCard(symbol, impactPct >= 0);
    },

    /* ===== ADMIN PANEL YARDIMCILARI =====
     * Sessiz fiyat manipülasyonu (habersiz) + Stock CRUD
     */

    // Bir hissenin fiyatını DOĞRUDAN, habersizce set eder. Admin "Sessiz Fiyat" aracı.
    setPrice(symbol, exactPriceTL) {
        const stock = this.state.stocks[symbol];
        if (!stock) return false;
        const p = Math.max(0.05, Number(exactPriceTL) || 0);
        const newPrice = this.round2(p);
        const up = newPrice >= stock.price;
        stock.price = newPrice;
        stock.history.push({ time: Date.now(), price: newPrice });
        if (stock.history.length > 200) stock.history.shift();
        const change = this.round2(newPrice - stock.previousClose);
        stock.change = change;
        stock.changePct = this.round2((change / stock.previousClose) * 100);
        this.flashCard(symbol, up);
        this.saveState();
        this.renderCommon();
        return newPrice;
    },

    // Bir hissenin fiyatını yüzde olarak yukarı/aşağı çarpar (habersizce). pct: -15..+25 vs.
    bumpPricePercent(symbol, pct) {
        const stock = this.state.stocks[symbol];
        if (!stock) return false;
        const p = Number(pct) || 0;
        const newPrice = this.round2(Math.max(0.05, stock.price * (1 + p / 100)));
        return this.setPrice(symbol, newPrice);
    },

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
        const history = this._generatePriceHistory(base, 40);
        const last = history[history.length - 1].price;
        const first = history[0].price;
        const change = this.round2(last - first);
        const changePct = this.round2(first > 0 ? (change / first) * 100 : 0);
        this.state.stocks[symbol] = {
            name,
            symbol,
            color,
            price: last,
            previousClose: first,
            change,
            changePct,
            history,
            shares: Math.floor(100000 + Math.random() * 500000),
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

    randomMarketTick() {
        // [AYAR] Doğal arka plan dalgalanması — haber olmadan price ne kadar oynar?
        let changed = false;
        Object.keys(this.state.stocks).forEach(sym => {
            // [AYAR] BU HİSSE BU TICK'TE OYNASIN MI?
            // 0.4 → %40 olasılıkla her hisse hareket eder. 0.2 = daha durağan, 0.8 = daha hareketli.
            if (Math.random() < 0.4) {
                const stock = this.state.stocks[sym];
                // [AYAR] TEK BİR HAREKETİN YÜZDESİ (VOLATİLİTE):
                // 0.018  → -%0,9 ~ +%0,9  aralığı / tek tick başına
                // 0.01   → -%0,5 ~ +%0,5  (durgun)
                // 0.03   → -%1,5 ~ +%1,5  (agresif)
                // 0.05   → -%2,5 ~ +%2,5  (crypto)
                const volatility = (Math.random() - 0.5) * 0.018;
                const oldPrice = stock.price;
                const newPrice = this.round2(Math.max(0.5, oldPrice * (1 + volatility)));
                stock.price = newPrice;
                stock.history.push({ time: Date.now(), price: newPrice });
                if (stock.history.length > 200) stock.history.shift();
                const change = this.round2(newPrice - stock.previousClose);
                stock.change = change;
                stock.changePct = this.round2((change / stock.previousClose) * 100);
                changed = true;
            }
        });
        if (changed) {
            this.saveState();
            this.renderStocksGrid();
            this.renderTickerTape();
            this.renderMarketCap();
            if (this.state.selectedStock) this.renderChart();
        }
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
        if (!canvas) return;
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
                    pointRadius: 0,
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

    startAutoUpdates(enableTicks = true) {
        if (this._clockInterval) clearInterval(this._clockInterval);
        this.updateClock();
        this._clockInterval = setInterval(() => this.updateClock(), 1000);

        if (enableTicks) {
            if (this._tickInterval) clearInterval(this._tickInterval);
            // [AYAR] ARKA PLAN FİYAT GÜNCELLEME HIZI (ms):
            // 4000  → 4 saniyede bir tick
            // 2000  → 2 sn (agresif)
            // 10000 → 10 sn (çok sakin)
            this._tickInterval = setInterval(() => this.randomMarketTick(), 4000);
        }
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
        if (!this.loadState()) {
            this.state.stocks = this.initStocks();
            this.state.news = this.seedNews();
        }
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
     * - Admin: randomMarketTick / setPrice / publishNews çalıştırdığında
     *   değişiklikler Supabase'e de yazılır, diğer clientlar realtime alır.
     */
    Realtime: {
        _chan: null,
        _statusChan: null,
        _appSettingsChan: null,
        _newsChan: null,
        _bound: false,
        _enabled: false,
        _lastStatus: null,

        async seedDefaultStocksIfDBEmpty() {
            const sb = this._sb();
            if (!sb) return;
            try {
                const { data, error } = await sb.from("stocks").select("symbol").limit(1);
                if (error) return;
                if (data && data.length > 0) return;
            } catch (_) { return; }
            const tmp = (typeof Borsa !== "undefined" && Borsa.initStocks) ? Borsa.initStocks() : null;
            if (!tmp) return;
            const symbols = Object.keys(tmp);
            for (const sym of symbols) {
                try {
                    const s = tmp[sym];
                    const payload = {
                        symbol: s.symbol,
                        name: s.name,
                        color: s.color,
                        current_price: s.price,
                        previous_close: s.previousClose,
                        shares: s.shares,
                        price_history: (s.history || []).slice(-100),
                    };
                    await sb.from("stocks").insert([payload], { onConflict: "symbol" });
                } catch (_) {}
            }
            console.log(`[Realtime] DB boştu, ${symbols.length} varsayılan hisse seed edildi.`);
        },

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
            const change = Borsa.round2(price - previousClose);
            const changePct = Borsa.round2(previousClose > 0 ? (change / previousClose) * 100 : 0);
            const color = String(row.color || "#3b82f6").trim();
            const shares = Number(row.shares ?? row.shares_outstanding ?? row.total_shares ?? 100000);
            let history;
            try {
                if (row.price_history && Array.isArray(row.price_history)) {
                    history = row.price_history.map(h => ({
                        time: Number(h.time ?? h.t ?? Date.now()),
                        price: Borsa.round2(Number(h.price ?? h.p ?? price)),
                    }));
                }
            } catch (_) { history = null; }
            if (!history || history.length === 0) {
                history = Borsa._generatePriceHistory(price, 40);
            }
            if (history.length > 0) {
                const last = history[history.length - 1];
                if (Math.abs(Number(last.price) - price) > 0.01) {
                    history.push({ time: Date.now(), price: Borsa.round2(price) });
                }
            }
            return {
                name,
                symbol,
                color,
                price: Borsa.round2(price),
                previousClose: Borsa.round2(previousClose),
                change,
                changePct,
                history,
                shares: Math.max(1, Math.floor(shares)),
                _src: "supabase",
                _updatedAt: row.updated_at ? new Date(row.updated_at).getTime() : Date.now(),
            };
        },

        async _loadInitialStocksFromDB() {
            const sb = this._sb();
            if (!sb) return false;
            try {
                await this.seedDefaultStocksIfDBEmpty();
                const { data, error } = await sb
                    .from("stocks")
                    .select("*")
                    .order("symbol", { ascending: true });
                if (error) {
                    console.warn("[Realtime] stocks tablosu okunamadı (tablo yok veya RLS?):", error.message);
                    return false;
                }
                if (!data || !Array.isArray(data) || data.length === 0) return false;
                const normalized = {};
                data.forEach(row => {
                    const s = this._normalizeStockRow(row);
                    if (s) normalized[s.symbol] = s;
                });
                const symbols = Object.keys(normalized);
                if (symbols.length === 0) return false;
                Borsa.state.stocks = normalized;
                Borsa.state.news = Borsa.state.news || Borsa.seedNews();
                await this._loadInitialNewsFromDB();
                if (!Borsa.state.selectedStock || !Borsa.state.stocks[Borsa.state.selectedStock]) {
                    Borsa.state.selectedStock = symbols[0];
                }
                console.log(`[Realtime] DB'den ${symbols.length} hisse yüklendi: ${symbols.join(", ")}`);
                return true;
            } catch (e) {
                console.warn("[Realtime] İlk hisse yükleme hatası:", e && e.message || e);
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
            Borsa.state.news.unshift(item);
            if (Borsa.state.news.length > 150) Borsa.state.news.pop();
            if (item.target && Borsa.state.stocks[item.target]) {
                const impactPct = Number(item.impact) || 0;
                if (Math.abs(impactPct) > 0.001) {
                    const stock = Borsa.state.stocks[item.target];
                    const newPrice = Borsa.round2(Math.max(0.5, stock.price * (1 + impactPct / 100)));
                    const old = stock.price;
                    stock.price = newPrice;
                    stock.history.push({ time: Date.now(), price: newPrice });
                    if (stock.history.length > 200) stock.history.shift();
                    const change = Borsa.round2(newPrice - stock.previousClose);
                    stock.change = change;
                    stock.changePct = Borsa.round2(stock.previousClose > 0 ? (change / stock.previousClose) * 100 : 0);
                    Borsa.flashCard(item.target, impactPct >= 0);
                    if (Borsa.state.selectedStock === item.target) {
                        try { Borsa.renderChart(); } catch (_) {}
                    }
                }
            }
            try { Borsa.renderNewsFeed(); } catch (_) {}
            try { Borsa.saveState(); } catch (_) {}
        },

        async _syncStockToDB(symbol) {
            const sb = this._sb();
            if (!sb) return false;
            const stock = Borsa.state.stocks[symbol];
            if (!stock) return false;
            try {
                const payload = {
                    symbol: stock.symbol,
                    name: stock.name,
                    color: stock.color,
                    current_price: stock.price,
                    previous_close: stock.previousClose,
                    shares: stock.shares,
                    price_history: (stock.history || []).slice(-100),
                    updated_at: new Date().toISOString(),
                };
                const { error } = await sb
                    .from("stocks")
                    .upsert([payload], { onConflict: "symbol" });
                if (error) {
                    console.debug(`[Realtime] ${symbol} DB sync başarısız:`, error.message);
                    return false;
                }
                return true;
            } catch (e) {
                console.debug(`[Realtime] ${symbol} DB sync exception:`, e && e.message || e);
                return false;
            }
        },

        async syncAllLocalStocksToDB() {
            const sb = this._sb();
            if (!sb) return;
            const symbols = Object.keys(Borsa.state.stocks || {});
            let ok = 0;
            for (const sym of symbols) {
                try {
                    if (await this._syncStockToDB(sym)) ok++;
                } catch (_) {}
            }
            if (ok > 0) console.log(`[Realtime] ${ok}/${symbols.length} hisse DB ile senkronize edildi.`);
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
                    try { Borsa.renderChart(); } catch (_) {}
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

    /* =========================================================
     *  SETPRICE / BUMP / PUBLISHNEWS / RANDOMMARKETTICK
     *  Yerel değişiklikleri Realtime sync + DB write ile genişlet
     * ========================================================= */
    _rtSyncAfterLocalChange(symbols) {
        const list = Array.isArray(symbols) ? symbols.slice() : [symbols];
        try {
            if (this.Realtime && this.Realtime.isEnabled() && typeof this.Realtime._syncStockToDB === "function") {
                list.forEach(sym => { if (sym) this.Realtime._syncStockToDB(sym); });
            }
        } catch (_) {}
    },

    applyNewsImpact(symbol, impactPct) {
        const stock = this.state.stocks[symbol];
        if (!stock) return;
        const oldPrice = stock.price;
        const newPrice = this.round2(Math.max(0.5, oldPrice * (1 + impactPct / 100)));
        stock.price = newPrice;
        stock.history.push({
            time: Date.now(),
            price: newPrice,
        });
        if (stock.history.length > 200) stock.history.shift();
        const change = this.round2(newPrice - stock.previousClose);
        stock.change = change;
        stock.changePct = this.round2((change / stock.previousClose) * 100);
        this.flashCard(symbol, impactPct >= 0);
        try {
            this.renderStocksGrid();
            this.renderTickerTape();
            this.renderMarketCap();
            if (this.state.selectedStock === symbol) this.renderChart();
            this.saveState();
        } catch (_) {}
        this._rtSyncAfterLocalChange(symbol);
    },

    setPrice(symbol, exactPriceTL) {
        const stock = this.state.stocks[symbol];
        if (!stock) return false;
        const p = Math.max(0.05, Number(exactPriceTL) || 0);
        const newPrice = this.round2(p);
        const up = newPrice >= stock.price;
        stock.price = newPrice;
        stock.history.push({ time: Date.now(), price: newPrice });
        if (stock.history.length > 200) stock.history.shift();
        const change = this.round2(newPrice - stock.previousClose);
        stock.change = change;
        stock.changePct = this.round2((change / stock.previousClose) * 100);
        this.flashCard(symbol, up);
        this.saveState();
        this.renderCommon();
        this._rtSyncAfterLocalChange(symbol);
        return newPrice;
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
        try { this.renderNewsFeed(); } catch (_) {}
        try {
            const sb = (typeof window.sb !== "undefined" && window.sb) ? window.sb : null;
            if (sb && sb.from) {
                sb.from("news_feed").insert([{
                    id: newsItem.id,
                    title: String(title || "").slice(0, 280),
                    stock_symbol: target || null,
                    impact_pct: Number(impact) || 0,
                    created_at: new Date(newsItem.timestamp).toISOString(),
                }]).catch(() => {});
            }
        } catch (_) {}
        return newsItem;
    },

    randomMarketTick() {
        let changed = false;
        const changedSymbols = [];
        Object.keys(this.state.stocks).forEach(sym => {
            if (Math.random() < 0.4) {
                const stock = this.state.stocks[sym];
                const volatility = (Math.random() - 0.5) * 0.018;
                const oldPrice = stock.price;
                const newPrice = this.round2(Math.max(0.5, oldPrice * (1 + volatility)));
                stock.price = newPrice;
                stock.history.push({ time: Date.now(), price: newPrice });
                if (stock.history.length > 200) stock.history.shift();
                const change = this.round2(newPrice - stock.previousClose);
                stock.change = change;
                stock.changePct = this.round2((change / stock.previousClose) * 100);
                changed = true;
                changedSymbols.push(sym);
            }
        });
        if (changed) {
            this.saveState();
            this.renderStocksGrid();
            this.renderTickerTape();
            this.renderMarketCap();
            if (this.state.selectedStock) this.renderChart();
            this._rtSyncAfterLocalChange(changedSymbols);
        }
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
        try {
            if (this.Realtime && typeof this.Realtime.start === "function") {
                this.Realtime.start();
            }
        } catch (e) {
            console.warn("[Realtime] start() başarısız:", e);
        }
        if (!usedDB) {
            try {
                if (this.Realtime && typeof this.Realtime.syncAllLocalStocksToDB === "function") {
                    setTimeout(() => this.Realtime.syncAllLocalStocksToDB(), 2500);
                }
            } catch (_) {}
        }
    },
};
