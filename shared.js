const STORAGE_KEY = "borsa_economics_club_v1";

const Borsa = {
    state: {
        stocks: {},
        news: [],
        selectedStock: null,
        marketOpen: false,
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

    formatNewsDateTime(ts) {
        const date = new Date(ts);
        return `${date.toLocaleDateString("tr-TR", {
            day: "numeric", month: "long", year: "numeric",
        })} - ${date.toLocaleTimeString("tr-TR", {
            hour: "2-digit", minute: "2-digit",
        })}`;
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
        if (!confirm("Haber arşivi ve piyasa tüyoları silinsin mi? Hisse fiyatları, grafik geçmişi ve portföyler korunur.")) return false;
        const sb = (typeof window.sb !== "undefined" && window.sb) ? window.sb : null;
        if (!sb || !sb.rpc) throw new Error("Supabase bağlantısı hazır değil.");
        const { error } = await sb.rpc("admin_reset_market");
        if (error) throw error;
        this.state.news = [];
        this.saveState();
        this.renderNewsFeed();
        await this.Realtime._loadInitialStocksFromDB();
        this.renderCommon();
        return true;
    },

    /* ===== ADMIN PANEL YARDIMCILARI =====
     * Sessiz fiyat manipülasyonu (habersiz) + Stock CRUD
     */

    // Admin: yeni hisse ekle. color opsiyonel, atanmazsa rastgele.
    RISK_TYPES: { guvenli: "Güvenli", orta: "Orta", riskli: "Riskli" },

    isHalted(stock) {
        return !!(stock && stock.haltUntil && stock.haltUntil > Date.now());
    },

    haltEndsAt(stock) {
        return new Date(stock.haltUntil).toLocaleTimeString("tr-TR", { hour: "2-digit", minute: "2-digit" });
    },

    addStock({ symbol, name, price, riskType }) {
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
            riskType: this.RISK_TYPES[riskType] ? riskType : "orta",
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
        // Devre kesici süresi dolunca etiket kalksın diye en yakın bitiş anında yeniden çizilir.
        clearTimeout(this._haltTimer);
        const now = Date.now();
        const nextHaltEnd = symbols
            .map(sym => this.state.stocks[sym].haltUntil || 0)
            .filter(t => t > now)
            .sort((a, b) => a - b)[0];
        if (nextHaltEnd) {
            this._haltTimer = setTimeout(() => this.renderStocksGrid({ onSelect }), nextHaltEnd - now + 500);
        }
        symbols.forEach(sym => {
            const s = this.state.stocks[sym];
            const isUp = s.changePct >= 0;
            const halted = this.isHalted(s);
            const card = document.createElement("div");
            card.className = `stock-card ${isUp ? "up" : "down"} ${halted ? "halted" : ""} ${this.state.selectedStock === sym ? "selected" : ""}`;
            card.dataset.symbol = sym;
            card.innerHTML = `
                <div class="stock-avatar" style="background: linear-gradient(135deg, ${s.color}, ${s.color}aa);">
                    ${s.name.charAt(0).toUpperCase()}
                </div>
                <div class="stock-body">
                    <div class="stock-name">${s.name}</div>
                    <div class="stock-symbol">${s.symbol}<span class="stock-risk stock-risk--${s.riskType || "orta"}">${this.RISK_TYPES[s.riskType] || this.RISK_TYPES.orta}</span></div>
                    <div class="stock-price-row">
                        <div class="stock-price">${this.formatCurrency(s.price)}</div>
                        <div class="stock-change ${isUp ? "up" : "down"}">
                            ${isUp ? "▲" : "▼"} ${Math.abs(s.changePct).toFixed(2)}%
                        </div>
                    </div>
                    ${halted ? `<div class="stock-halt">⚡ DEVRE KESİCİ · ${this.haltEndsAt(s)}'de açılır</div>` : ""}
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
                            maxTicksLimit: 5, font: { size: 10 },
                            // Eksende saniye gösterilmez ("07.10 13:14"); ipucunda tam saat durur.
                            callback: function (value) {
                                return String(this.getLabelForValue(value) || "").slice(0, 11);
                            },
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
        const elements = [
            document.getElementById("newsFeed"),
            document.getElementById("newsModalFeed"),
        ].filter(Boolean);
        const sorted = [...this.state.news].sort((a, b) => b.timestamp - a.timestamp).slice(0, this.NEWS_MAX);
        this._renderHeadlines(sorted);
        if (elements.length === 0) return;
        elements.forEach(el => {
            if (el.classList.contains("news-paper")) {
                this._renderNewspaper(el, sorted);
                return;
            }
            el.innerHTML = "";
            if (sorted.length === 0) {
                el.innerHTML = `
                    <div class="empty-state">
                        <div class="empty-state-icon">📰</div>
                        <p>Henüz haber yok. Yakında tekrar kontrol edin!</p>
                    </div>
                `;
                return;
            }
            sorted.forEach(n => {
                const impact = Number(n.impact) || 0;
                const positive = impact >= 0;
                const stock = n.target && this.state.stocks[n.target];
                const item = document.createElement("div");
                item.className = `news-item ${positive ? "positive" : "negative"}`;
                item.innerHTML = `
                    <div class="news-header">
                        <div class="news-title">${this.escapeHtml(n.title)}</div>
                        <time class="news-time" datetime="${new Date(n.timestamp).toISOString()}">${this.formatNewsDateTime(n.timestamp)}</time>
                    </div>
                    ${n.summary ? `<p class="news-summary">${this.escapeHtml(n.summary)}</p>` : ""}
                    <div class="news-meta">
                        <span class="news-target">${stock ? this.escapeHtml(stock.name) : "Piyasa"}</span>
                        <span class="news-impact ${positive ? "positive" : "negative"}">${positive ? "+" : ""}${impact.toFixed(1)}%</span>
                    </div>
                `;
                el.appendChild(item);
            });
        });
    },

    // Grafiğin altındaki kısa liste: en yeni birkaç başlık, tıklanınca haberin detayı açılır.
    _renderHeadlines(news) {
        const el = document.getElementById("newsHeadlines");
        if (!el) return;
        const top = news.slice(0, 5);
        if (top.length === 0) {
            el.innerHTML = `<li class="headlines-empty">Henüz haber yok.</li>`;
            return;
        }
        el.innerHTML = top.map((n, index) => `
            <li>
                <button type="button" data-headline-index="${index}">
                    <span class="headline-title">${this.escapeHtml(n.title)}</span>
                    <time datetime="${new Date(n.timestamp).toISOString()}">${this.formatTime(n.timestamp).slice(0, 11)}</time>
                </button>
            </li>`).join("");
        el.querySelectorAll("[data-headline-index]").forEach(button => {
            button.addEventListener("click", () => this._showNewsDetailModal(top[Number(button.dataset.headlineIndex)]));
        });
    },

    // Gazetede en fazla NEWS_MAX haber durur, sayfa başına NEWS_PAGE_SIZE haber gösterilir.
    NEWS_MAX: 20,
    NEWS_PAGE_SIZE: 10,
    _newsPage: 1,

    _renderNewspaper(el, news) {
        const masthead = `
            <header class="news-paper-masthead">
                <div class="news-paper-top-border"></div>
                <p class="news-paper-kicker">📰 PİYASA • HABER ARŞİVİ</p>
                <h2 class="news-paper-name">EKONOMİ GAZETESİ</h2>
                <div class="news-paper-bottom-border"></div>
            </header>`;

        if (news.length === 0) {
            el.innerHTML = `${masthead}<p class="news-paper-empty">Henüz haber yok. Yakında tekrar kontrol edin.</p>`;
            return;
        }

        const pageCount = Math.ceil(news.length / this.NEWS_PAGE_SIZE);
        const page = Math.min(Math.max(1, this._newsPage), pageCount);
        this._newsPage = page;
        const start = (page - 1) * this.NEWS_PAGE_SIZE;
        const pageNews = news.slice(start, start + this.NEWS_PAGE_SIZE);

        const metaMarkup = n => {
            const impact = Number(n.impact) || 0;
            const targetInfo = n.target && this.state.stocks[n.target]
                ? `<span class="news-paper-stock-tag">📊 ${this.escapeHtml(this.state.stocks[n.target].symbol)} · ${this.escapeHtml(this.state.stocks[n.target].name)}</span>`
                : `<span class="news-paper-stock-tag">📈 Piyasa</span>`;
            const impactClass = impact >= 0 ? "positive" : "negative";
            const impactEmoji = impact >= 0 ? "📈" : "📉";
            const impactInfo = `<span class="news-paper-impact ${impactClass}">${impactEmoji} ${impact >= 0 ? "+" : ""}${impact.toFixed(1)}%</span>`;
            return `${targetInfo}${impactInfo}`;
        };

        // Manşet yalnızca ilk sayfada; diğer sayfalarda bütün haberler sütunlarda.
        const lead = page === 1 ? pageNews[0] : null;
        const firstSecondary = lead ? 1 : 0;
        const secondaryStories = pageNews.slice(firstSecondary).map((n, index) => `
            <li class="news-paper-story" data-news-id="${n.id}" data-news-index="${start + firstSecondary + index}">
                <h4>💰 ${this.escapeHtml(n.title)}</h4>
                ${n.summary ? `<p class="news-paper-secondary-spot">${this.escapeHtml(n.summary)}</p>` : ""}
                <div class="news-paper-story-meta">
                    ${metaMarkup(n)}
                    <time datetime="${new Date(n.timestamp).toISOString()}">${this.formatNewsDateTime(n.timestamp)}</time>
                </div>
            </li>
        `).join("");

        const pager = pageCount > 1 ? `
            <nav class="news-paper-pager" aria-label="Gazete sayfaları">
                ${Array.from({ length: pageCount }, (_, i) => `
                    <button type="button" data-news-page="${i + 1}" class="${i + 1 === page ? "is-active" : ""}"
                        ${i + 1 === page ? 'aria-current="page"' : ""} aria-label="${i + 1}. sayfa">${i + 1}</button>`).join("")}
            </nav>` : "";

        el.innerHTML = `
            ${masthead}
            ${lead ? `
            <article class="news-paper-lead" data-news-id="${lead.id}" data-news-index="${start}">
                <p class="news-paper-section-label">🔥 GÜNÜN MANŞETİ</p>
                <h3>💎 ${this.escapeHtml(lead.title)}</h3>
                ${lead.summary ? `<p class="news-paper-spot">${this.escapeHtml(lead.summary)}</p>` : ""}
                <div class="news-paper-story-meta">
                    ${metaMarkup(lead)}
                    <time datetime="${new Date(lead.timestamp).toISOString()}">${this.formatNewsDateTime(lead.timestamp)}</time>
                </div>
            </article>` : ""}
            ${secondaryStories ? `<ol class="news-paper-columns">${secondaryStories}</ol>` : ""}
            ${pager}
        `;

        // Add click handlers for expanded view
        this._bindNewsExpandHandlers(el, news);
        el.querySelectorAll("[data-news-page]").forEach(button => {
            button.addEventListener("click", () => {
                this._newsPage = Number(button.dataset.newsPage) || 1;
                this.renderNewsFeed();
                const dialog = el.closest(".news-modal-dialog");
                if (dialog) dialog.scrollTop = 0;
            });
        });
    },

    _bindNewsExpandHandlers(el, news) {
        const stories = el.querySelectorAll('[data-news-id]');
        stories.forEach(story => {
            story.style.cursor = 'pointer';
            story.addEventListener('click', (e) => {
                const newsId = story.dataset.newsId;
                const newsIndex = parseInt(story.dataset.newsIndex);
                const newsItem = news[newsIndex];
                if (newsItem) {
                    this._showNewsDetailModal(newsItem);
                }
            });
        });
    },

    _showNewsDetailModal(newsItem) {
        // Create modal if it doesn't exist
        let modal = document.getElementById('newsDetailModal');
        if (!modal) {
            modal = document.createElement('div');
            modal.id = 'newsDetailModal';
            modal.className = 'news-detail-modal-overlay';
            modal.setAttribute('role', 'dialog');
            modal.setAttribute('aria-modal', 'true');
            modal.setAttribute('aria-labelledby', 'newsDetailTitle');
            document.body.appendChild(modal);
        }

        const impact = Number(newsItem.impact) || 0;
        const impactClass = impact >= 0 ? "positive" : "negative";
        const impactEmoji = impact >= 0 ? "📈" : "📉";
        const targetInfo = newsItem.target && this.state.stocks[newsItem.target]
            ? `📊 ${this.escapeHtml(this.state.stocks[newsItem.target].symbol)} · ${this.escapeHtml(this.state.stocks[newsItem.target].name)}`
            : "📈 Piyasa";

        // Summary'ın tamamını göster (kırpmadan)
        const fullSummary = newsItem.summary || "";
        // Gerçek haberlerde fiyat etkisi yoktur; etki kutuları yalnızca oyun haberlerinde gösterilir.
        const hasImpact = impact !== 0 || Boolean(newsItem.target);
        const sourceUrl = /^https?:\/\//i.test(newsItem.url || "") ? newsItem.url : "";
        const sourceMarkup = (newsItem.source || sourceUrl) ? `
                        <div class="news-detail-source">
                            ${newsItem.source ? `<span>Kaynak: <b>${this.escapeHtml(newsItem.source)}</b></span>` : ""}
                            ${sourceUrl ? `<a href="${this.escapeHtml(sourceUrl)}" target="_blank" rel="noopener noreferrer">Haberin tamamını oku ↗</a>` : ""}
                        </div>` : "";

        modal.innerHTML = `
            <div class="news-detail-modal-dialog">
                <button type="button" class="news-detail-modal-close" aria-label="Kapat" title="Kapat">×</button>
                <div class="news-detail-content">
                    <header class="news-detail-header">
                        <span class="news-detail-badge">📰 Detaylı Haber</span>
                        <h2 id="newsDetailTitle" class="news-detail-title">${this.escapeHtml(newsItem.title)}</h2>
                        <div class="news-detail-meta">
                            <span class="news-detail-stock">${targetInfo}</span>
                            ${hasImpact ? `<span class="news-detail-impact ${impactClass}">${impactEmoji} ${impact >= 0 ? "+" : ""}${impact.toFixed(1)}%</span>` : ""}
                            <time class="news-detail-time" datetime="${new Date(newsItem.timestamp).toISOString()}">${this.formatNewsDateTime(newsItem.timestamp)}</time>
                        </div>
                    </header>
                    <div class="news-detail-body">
                        ${fullSummary ? `<p class="news-detail-summary">${this.escapeHtml(fullSummary)}</p>` : "<p class='news-detail-summary'>Haber detayı bulunmuyor.</p>"}
${sourceMarkup}
                        <div class="news-detail-stats">
                            <div class="stat-item">
                                <span class="stat-label">📅 Tarih</span>
                                <span class="stat-value">${new Date(newsItem.timestamp).toLocaleDateString('tr-TR')}</span>
                            </div>
                            <div class="stat-item">
                                <span class="stat-label">⏰ Saat</span>
                                <span class="stat-value">${new Date(newsItem.timestamp).toLocaleTimeString('tr-TR')}</span>
                            </div>
                            ${hasImpact ? `<div class="stat-item">
                                <span class="stat-label">📊 Etki</span>
                                <span class="stat-value ${impactClass}">${impact >= 0 ? "+" : ""}${impact.toFixed(1)}%</span>
                            </div>` : ""}
                        </div>
                    </div>
                </div>
            </div>
        `;

        modal.classList.add('is-open');
        document.body.classList.add('news-detail-modal-open');

        // Close handler
        const closeBtn = modal.querySelector('.news-detail-modal-close');
        const close = () => {
            modal.classList.remove('is-open');
            document.body.classList.remove('news-detail-modal-open');
        };

        closeBtn.addEventListener('click', close);
        modal.addEventListener('click', (e) => {
            if (e.target === modal) close();
        });
        document.addEventListener('keydown', (e) => {
            if (e.key === 'Escape' && modal.classList.contains('is-open')) close();
        });
    },

    bindNewsModal() {
        const trigger = document.getElementById("openNewsModal");
        const overlay = document.getElementById("newsModal");
        const closeButton = document.getElementById("closeNewsModal");
        if (!trigger || !overlay || !closeButton || trigger.dataset.bound === "1") return;

        const close = () => {
            overlay.classList.remove("is-open");
            overlay.setAttribute("aria-hidden", "true");
            trigger.setAttribute("aria-expanded", "false");
            document.body.classList.remove("news-modal-open");
            trigger.focus();
        };

        trigger.dataset.bound = "1";
        trigger.addEventListener("click", () => {
            overlay.classList.add("is-open");
            overlay.setAttribute("aria-hidden", "false");
            trigger.setAttribute("aria-expanded", "true");
            document.body.classList.add("news-modal-open");
            closeButton.focus();
        });
        document.querySelectorAll("[data-open-news]").forEach(button => {
            button.addEventListener("click", () => trigger.click());
        });
        closeButton.addEventListener("click", close);
        overlay.addEventListener("click", event => {
            if (event.target === overlay) close();
        });
        document.addEventListener("keydown", event => {
            if (event.key === "Escape" && overlay.classList.contains("is-open")) close();
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
        _marketSettingsChan: null,
        _newsChan: null,
        _marketStatusRevision: 0,
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
            const changePct = previousClose > 0
                ? ((price - previousClose) / previousClose) * 100
                : 0;
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
                riskType: Borsa.RISK_TYPES[row.risk_type] ? row.risk_type : "orta",
                haltUntil: row.halt_until ? new Date(row.halt_until).getTime() : null,
                _src: "supabase",
                _updatedAt: updatedAt,
            };
        },

        applyMarketStatus(isOpen, haltUntil) {
            this._marketStatusRevision++;
            Borsa.state.marketOpen = isOpen === true;
            // Piyasa geneli devre kesici: haltUntil verilmediyse eski değer korunur.
            if (haltUntil !== undefined) {
                const t = haltUntil ? new Date(haltUntil).getTime() : 0;
                Borsa.state.marketHaltUntil = Number.isFinite(t) ? t : 0;
            }
            clearTimeout(this._marketHaltTimer);
            const haltLeft = (Borsa.state.marketHaltUntil || 0) - Date.now();
            const marketHalted = Borsa.state.marketOpen && haltLeft > 0;
            if (marketHalted) {
                this._marketHaltTimer = setTimeout(
                    () => this.applyMarketStatus(Borsa.state.marketOpen), haltLeft + 500);
            }
            this._renderMarketHaltBanner(marketHalted);
            const pill = document.getElementById("marketStatusPill");
            if (pill) {
                pill.textContent = marketHalted ? "İŞLEMLER DURDU" : Borsa.state.marketOpen ? "PİYASA AÇIK" : "PİYASA KAPALI";
                pill.setAttribute("aria-label", marketHalted ? "Piyasa geneli devre kesici devrede" : Borsa.state.marketOpen ? "Piyasa açık" : "Piyasa kapalı");
                const status = pill.closest(".market-status");
                if (status) {
                    status.classList.toggle("market-open", Borsa.state.marketOpen && !marketHalted);
                    status.classList.toggle("market-closed", !Borsa.state.marketOpen || marketHalted);
                }
            }
            const hoursNote = document.getElementById("marketHoursNote");
            if (hoursNote) {
                // Piyasa geneli duruşta bilgi büyük uyarı kutusunda verilir; bu şerit gizlenir.
                hoursNote.style.display = marketHalted ? "none" : "";
                hoursNote.textContent = Borsa.state.marketOpen
                    ? "🕘 Piyasa açık. Her gün 09:00–24:00 arası işlem yapılabilir."
                    : "🔒 Piyasa şu an kapalı. Her gün 09:00'da açılır, 24:00'te kapanır.";
                hoursNote.classList.toggle("is-closed", !Borsa.state.marketOpen);
            }
            document.querySelectorAll("[data-market-trade]").forEach(button => {
                const disabled = !Borsa.state.marketOpen || button.dataset.tradeBusy === "true";
                button.disabled = disabled;
                button.setAttribute("aria-disabled", String(disabled));
                button.title = Borsa.state.marketOpen ? "" : "Piyasa kapalı (09:00–24:00 arası açık)";
            });
            window.dispatchEvent(new CustomEvent("borsa:market-status-updated", {
                detail: { isMarketOpen: Borsa.state.marketOpen },
            }));
        },

        // Piyasa geneli devre kesici: sayfanın en üstünde geri sayımlı büyük uyarı kutusu.
        _renderMarketHaltBanner(halted) {
            clearInterval(this._marketHaltTick);
            const main = document.querySelector("main.main-container");
            let banner = document.getElementById("marketHaltBanner");
            if (!halted || !main) {
                if (banner) banner.remove();
                return;
            }
            if (!banner) {
                banner = document.createElement("div");
                banner.id = "marketHaltBanner";
                banner.className = "market-halt-banner";
                banner.setAttribute("role", "alert");
                banner.innerHTML = `
                    <div class="market-halt-icon" aria-hidden="true">⚡</div>
                    <div class="market-halt-text">
                        <strong>PİYASA GENELİ DEVRE KESİCİ DEVREDE</strong>
                        <span>Hisselerin ortalaması gün içinde sert düştüğü için bütün hisse alım-satımları geçici olarak durduruldu. Fiyatlar bu süre boyunca değişmez; altın ve döviz işlemleri açık.</span>
                    </div>
                    <div class="market-halt-clock">
                        <span class="market-halt-label">Yeniden açılışa kalan</span>
                        <span class="market-halt-countdown" id="marketHaltCountdown">--:--</span>
                        <span class="market-halt-label" id="marketHaltAt"></span>
                    </div>`;
                main.prepend(banner);
            }
            const until = Borsa.state.marketHaltUntil;
            const at = document.getElementById("marketHaltAt");
            if (at) {
                at.textContent = "Açılış: " + new Date(until).toLocaleTimeString("tr-TR", { hour: "2-digit", minute: "2-digit" });
            }
            const tick = () => {
                const el = document.getElementById("marketHaltCountdown");
                if (!el) return;
                const left = Math.max(0, Math.ceil((until - Date.now()) / 1000));
                el.textContent = `${String(Math.floor(left / 60)).padStart(2, "0")}:${String(left % 60).padStart(2, "0")}`;
            };
            tick();
            this._marketHaltTick = setInterval(tick, 1000);
        },

        async refreshMarketStatus() {
            const sb = this._sb();
            const revision = this._marketStatusRevision;
            if (!sb) {
                this.applyMarketStatus(false);
                return false;
            }
            try {
                const { data, error } = await sb
                    .from("market_settings")
                    .select("*")
                    .eq("id", 1)
                    .maybeSingle();
                if (error) throw error;
                if (!data || typeof data.is_market_open !== "boolean") {
                    throw new Error("market_settings row id=1 is missing or invalid.");
                }
                if (revision === this._marketStatusRevision) {
                    this.applyMarketStatus(data.is_market_open, data.halt_until || null);
                }
                return true;
            } catch (e) {
                console.warn("[Realtime] Piyasa durumu okunamadı; güvenlik için kapalı sayıldı:", e && e.message || e);
                if (revision === this._marketStatusRevision) {
                    this.applyMarketStatus(false);
                }
                return false;
            }
        },

        async _loadInitialStocksFromDB() {
            const sb = this._sb();
            if (!sb) return false;
            await this._loadInitialNewsFromDB();
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
                const fetchNews = (columns) => sb
                    .from("news_feed")
                    .select(columns)
                    .order("created_at", { ascending: false })
                    .limit(Borsa.NEWS_MAX);
                let { data: rows, error } = await fetchNews("id, title, summary, stock_symbol, impact_pct, created_at, url, source");
                // Kaynak sütunları henüz eklenmemişse eski sütunlarla okunur.
                if (error) ({ data: rows, error } = await fetchNews("id, title, summary, stock_symbol, impact_pct, created_at"));
                if (error) throw error;
                if (!Array.isArray(rows)) {
                    throw new Error("news_feed sorgusu geçerli bir kayıt listesi döndürmedi.");
                }
                const mapped = rows.map(n => ({
                    id: Number(n.id || Date.now()),
                    title: String(n.title || ""),
                    summary: String(n.summary || ""),
                    target: String(n.stock_symbol || "").trim() || null,
                    impact: Number(n.impact_pct || 0),
                    timestamp: n.created_at ? new Date(n.created_at).getTime() : Date.now(),
                    url: String(n.url || ""),
                    source: String(n.source || ""),
                }));
                // Veritabanı esas alınır; tarayıcıda kalmış eski haberler atılır.
                Borsa.state.news = mapped.sort((a, b) => b.timestamp - a.timestamp);
                Borsa.renderNewsFeed();
                Borsa.saveState();
            } catch (e) {
                console.warn("[Realtime] Haber akışı yüklenemedi:", e && e.message || e);
            }
        },

        _handleNewsEvent(evt) {
            if (!evt) return;
            if (evt.eventType !== "INSERT" || !evt.new) return;
            const n = evt.new;
            const item = {
                id: Number(n.id || Date.now()),
                title: String(n.title || ""),
                summary: String(n.summary || ""),
                target: String(n.stock_symbol || "").trim() || null,
                impact: Number(n.impact_pct || 0),
                timestamp: n.created_at ? new Date(n.created_at).getTime() : Date.now(),
                url: String(n.url || ""),
                source: String(n.source || ""),
            };
            if (!item.title) return;
            if (Borsa.state.news.some(existing => String(existing.id) === String(item.id))) return;
            Borsa.state.news.unshift(item);
            Borsa.state.news = Borsa.state.news
                .sort((a, b) => b.timestamp - a.timestamp)
                .slice(0, Borsa.NEWS_MAX);
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
            window.dispatchEvent(new CustomEvent("borsa:stock-updated", {
                detail: { symbol: sym, stock: normalized },
            }));
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

        // Tüm hisseler market_snapshot tablosundaki tek satırda gelir (her güncellemede tek mesaj).
        _handleSnapshotEvent(evt) {
            const row = evt && evt.new;
            if (!row || !Array.isArray(row.stocks)) return;
            const seen = new Set();
            let changed = false;
            row.stocks.forEach(item => {
                const sym = String(item && item.symbol || "").trim().toUpperCase();
                if (!sym) return;
                seen.add(sym);
                const old = Borsa.state.stocks[sym];
                if (old &&
                    old.price === Borsa.round2(Number(item.current_price)) &&
                    old.previousClose === Borsa.round2(Number(item.previous_close)) &&
                    old.name === String(item.name || "").trim() &&
                    old.color === String(item.color || "").trim() &&
                    old.riskType === item.risk_type &&
                    (old.haltUntil || null) === (item.halt_until ? new Date(item.halt_until).getTime() : null)) {
                    return;
                }
                changed = true;
                this.updateOneStockFromPayload(
                    Object.assign({ updated_at: row.updated_at }, item),
                    { render: false }
                );
            });
            Object.keys(Borsa.state.stocks).forEach(sym => {
                if (!seen.has(sym)) this.removeOneStock(sym);
            });
            if (!changed) return;
            try { Borsa.renderStocksGrid(); } catch (_) {}
            try { Borsa.renderTickerTape(); } catch (_) {}
            try { Borsa.renderMarketCap(); } catch (_) {}
            const selected = Borsa.state.stocks[Borsa.state.selectedStock];
            if (selected) {
                try { Borsa.updateLiveChart(selected); } catch (_) {}
            }
            try { Borsa.saveState(); } catch (_) {}
        },

        _handleAppSettingsEvent(evt) {
            if (!evt || !evt.new) return;
            const val = evt.new;
            if (typeof val.maintenance_mode !== "undefined" &&
                typeof window.BorsaMaintenance !== "undefined" &&
                typeof window.BorsaMaintenance.checkAndRedirect === "function") {
                window.BorsaMaintenance.checkAndRedirect().catch(e => {
                    console.error("[Bakım] Realtime bakım kontrolü başarısız:", e);
                });
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
                        { event: "UPDATE", schema: "public", table: "market_snapshot", filter: "id=eq.1" },
                        (payload) => this._handleSnapshotEvent(payload)
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
                this._marketSettingsChan = sb
                    .channel("borsa-market-settings")
                    .on("postgres_changes",
                        { event: "*", schema: "public", table: "market_settings", filter: "id=eq.1" },
                        (payload) => {
                            if (payload.new && typeof payload.new.is_market_open === "boolean") {
                                this.applyMarketStatus(payload.new.is_market_open, payload.new.halt_until || null);
                            }
                        }
                    )
                    .subscribe();
            } catch (e) {
                console.warn("[Realtime] market_settings kanalı açılamadı:", e);
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
            if (window.BorsaMaintenance &&
                typeof window.BorsaMaintenance.subscribeRealtime === "function") {
                window.BorsaMaintenance.subscribeRealtime();
            }
            this.refreshMarketStatus();
            try {
                window.addEventListener("beforeunload", () => this.stop(), { once: true });
            } catch (_) {}
        },

        stop() {
            const sb = this._sb();
            if (!sb || typeof sb.removeChannel !== "function") return;
            [this._chan, this._statusChan, this._appSettingsChan, this._marketSettingsChan, this._newsChan].forEach(c => {
                if (!c) return;
                try { sb.removeChannel(c); } catch (_) {}
            });
            this._chan = null;
            this._statusChan = null;
            this._appSettingsChan = null;
            this._marketSettingsChan = null;
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

    async publishNews({ title, summary, target, impact }) {
        const impactPct = Number(impact) || 0;
        const sb = (typeof window.sb !== "undefined" && window.sb) ? window.sb : null;
        if (!sb || !sb.rpc) throw new Error("Supabase bağlantısı hazır değil.");
        const { data, error } = await sb.rpc("admin_publish_news", {
            p_title: String(title || "").slice(0, 280),
            p_symbol: target || null,
            p_impact_pct: impactPct,
            p_summary: String(summary || "").trim().slice(0, 500) || null,
        });
        if (error) throw error;
        const saved = Array.isArray(data) ? data[0] : data;
        if (!saved) throw new Error("Haber kaydedildi yanıtı alınamadı.");
        const newsItem = {
            id: Number(saved.id || Date.now()),
            title: String(saved.title || title || ""),
            summary: String(saved.summary || summary || ""),
            target: String(saved.stock_symbol || target || "").trim() || null,
            impact: Number(saved.impact_pct ?? impactPct),
            timestamp: saved.created_at ? new Date(saved.created_at).getTime() : Date.now(),
        };
        if (!this.state.news.some(item => String(item.id) === String(newsItem.id))) {
            this.state.news.unshift(newsItem);
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
        this.bindNewsModal();
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

if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => Borsa.bindNewsModal(), { once: true });
} else {
    Borsa.bindNewsModal();
}
