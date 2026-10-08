/* Altın, gümüş, dolar ve euro: fiyat gösterimi + alım satım.
 * Fiyatlar asset_prices tablosundaki tek satırdan okunur; işlem execute_asset_trade RPC'si ile yapılır.
 */
(function () {
    const ASSETS = {
        XAU: { name: "Altın", unit: "gram", icon: "🥇", color: "#f59e0b" },
        XAG: { name: "Gümüş", unit: "gram", icon: "🥈", color: "#94a3b8" },
        USD: { name: "Dolar", unit: "adet", icon: "$", color: "#10b981" },
        EUR: { name: "Euro", unit: "adet", icon: "€", color: "#3b82f6" },
    };
    const ORDER = ["XAU", "XAG", "USD", "EUR"];

    const $ = (id) => document.getElementById(id);
    const fmt = (n) => BorsaFirebase.formatTL(n);
    const fmtQty = (n) => Number(n || 0).toLocaleString("tr-TR", { maximumFractionDigits: 4 });
    const floor4 = (n) => Math.floor(Number(n || 0) * 10000) / 10000;

    const BorsaAssets = {
        ASSETS,
        state: { prices: {}, prevClose: {}, spread: 0.005, updatedAt: null },
        _current: null,
        _side: "BUY",
        _busy: false,
        _chan: null,
        _started: false,

        mid(sym) { return Number(this.state.prices[sym] || 0); },
        buyPrice(sym) { return this.mid(sym) * (1 + this.state.spread / 2); },
        sellPrice(sym) { return this.mid(sym) * (1 - this.state.spread / 2); },
        changePct(sym) {
            const prev = Number(this.state.prevClose[sym] || 0);
            return prev > 0 ? (this.mid(sym) - prev) / prev * 100 : 0;
        },
        held(sym) {
            const doc = BorsaFirebase.currentUserData();
            return Number(doc?.assets?.[sym]?.qty || 0);
        },
        cost(sym) {
            const doc = BorsaFirebase.currentUserData();
            return Number(doc?.assets?.[sym]?.cost || 0);
        },

        // Portföy özetine eklenecek toplamlar (piyasa değeri orta fiyattan).
        portfolioTotals() {
            let value = 0, cost = 0;
            ORDER.forEach(sym => {
                const qty = this.held(sym);
                if (qty > 0) {
                    value += qty * this.mid(sym);
                    cost += this.cost(sym);
                }
            });
            return { value: Math.round(value * 100) / 100, cost: Math.round(cost * 100) / 100 };
        },

        _applyRow(row) {
            if (!row) return;
            this.state.prices = row.prices || {};
            this.state.prevClose = row.prev_close || {};
            if (row.spread != null) this.state.spread = Number(row.spread);
            this.state.updatedAt = row.updated_at || null;
            this.renderGrid();
            this.updateModal();
            window.dispatchEvent(new CustomEvent("borsa:asset-prices-updated"));
        },

        async load() {
            if (!window.sb || !window.sb.from) return;
            const { data, error } = await window.sb
                .from("asset_prices")
                .select("prices, prev_close, spread, updated_at")
                .eq("id", 1)
                .maybeSingle();
            if (error) {
                console.warn("[Varlıklar] Fiyatlar okunamadı:", error.message);
                return;
            }
            this._applyRow(data);
        },

        start() {
            if (this._started || !window.sb || typeof window.sb.channel !== "function") return;
            this._started = true;
            this.load();
            try {
                this._chan = window.sb
                    .channel("borsa-asset-prices")
                    .on("postgres_changes",
                        { event: "UPDATE", schema: "public", table: "asset_prices", filter: "id=eq.1" },
                        (payload) => this._applyRow(payload.new)
                    )
                    .subscribe();
            } catch (e) {
                console.warn("[Varlıklar] Realtime kanalı açılamadı:", e);
            }
        },

        renderGrid() {
            const grid = $("assetsGrid");
            if (!grid) return;
            grid.innerHTML = "";
            ORDER.forEach(sym => {
                const meta = ASSETS[sym];
                const price = this.mid(sym);
                const pct = this.changePct(sym);
                const isUp = pct >= 0;
                const card = document.createElement("div");
                card.className = `stock-card asset-card ${isUp ? "up" : "down"}`;
                card.dataset.asset = sym;
                card.innerHTML = `
                    <div class="stock-avatar" style="background: linear-gradient(135deg, ${meta.color}, ${meta.color}aa);">${meta.icon}</div>
                    <div class="stock-body">
                        <div class="stock-name">${meta.name}</div>
                        <div class="stock-symbol">TL / ${meta.unit}</div>
                        <div class="stock-price-row">
                            <div class="stock-price">${price > 0 ? fmt(price) : "—"}</div>
                            <div class="stock-change ${isUp ? "up" : "down"}">
                                ${isUp ? "▲" : "▼"} ${Math.abs(pct).toFixed(2)}%
                            </div>
                        </div>
                    </div>
                `;
                card.addEventListener("click", () => this.open(sym));
                grid.appendChild(card);
            });
            const stamp = $("assetsUpdatedAt");
            if (stamp) {
                stamp.textContent = this.state.updatedAt
                    ? "Son güncelleme: " + new Date(this.state.updatedAt).toLocaleTimeString("tr-TR", { hour: "2-digit", minute: "2-digit" })
                    : "";
            }
        },

        open(sym) {
            if (!ASSETS[sym]) return;
            this._current = sym;
            this._side = "BUY";
            const modal = $("assetModal");
            if (!modal) return;
            const meta = ASSETS[sym];
            $("assetAvatar").textContent = meta.icon;
            $("assetAvatar").style.background = `linear-gradient(135deg, ${meta.color}, ${meta.color}aa)`;
            $("assetName").textContent = meta.name;
            $("assetUnit").textContent = "TL / " + meta.unit;
            $("assetQtyLabel").textContent = meta.unit === "gram" ? "Miktar (gram)" : "Miktar (adet)";
            $("assetQty").value = "1";
            this.setFeedback(null);
            modal.style.display = "flex";
            modal.setAttribute("aria-hidden", "false");
            this.updateModal();
            (async () => {
                try {
                    if (BorsaFirebase.currentUser() && BorsaFirebase.refreshUserDoc) {
                        await BorsaFirebase.refreshUserDoc();
                        this.updateModal();
                    }
                } catch (e) {}
            })();
        },

        close() {
            const modal = $("assetModal");
            if (!modal || this._busy) return;
            modal.style.display = "none";
            modal.setAttribute("aria-hidden", "true");
            this._current = null;
        },

        setFeedback(type, msg) {
            const el = $("assetFeedback");
            if (!el) return;
            if (!type || !msg) { el.style.display = "none"; el.textContent = ""; return; }
            const tone = type === "error"
                ? ["rgba(239,68,68,0.1)", "var(--red-bright)", "rgba(239,68,68,0.3)"]
                : ["rgba(16,185,129,0.1)", "var(--green-bright)", "rgba(16,185,129,0.3)"];
            el.style.display = "block";
            el.style.background = tone[0];
            el.style.color = tone[1];
            el.style.border = "1px solid " + tone[2];
            el.textContent = msg;
        },

        updateModal() {
            const sym = this._current;
            if (!sym || !$("assetModal")) return;
            const meta = ASSETS[sym];
            const pct = this.changePct(sym);
            const isUp = pct >= 0;
            $("assetPrice").textContent = this.mid(sym) > 0 ? fmt(this.mid(sym)) : "—";
            const ch = $("assetChange");
            ch.textContent = `${isUp ? "▲" : "▼"} %${Math.abs(pct).toFixed(2)}`;
            ch.className = "trade-change " + (isUp ? "up" : "down");
            $("assetBalance").textContent = fmt(BorsaFirebase.balance());
            $("assetOwned").textContent = `${fmtQty(this.held(sym))} ${meta.unit}`;
            $("assetBuyPrice").textContent = fmt(this.buyPrice(sym));
            $("assetSellPrice").textContent = fmt(this.sellPrice(sym));

            const user = BorsaFirebase.currentUser();
            $("assetGuestBanner").style.display = user ? "none" : "flex";
            $("assetLoggedInBlock").style.display = user ? "block" : "none";
            $("assetClosedNote").style.display = Borsa.state.marketOpen === true ? "none" : "block";
            this.updateTotals();
        },

        updateTotals(side) {
            if (side) this._side = side;
            const sym = this._current;
            if (!sym) return;
            const qty = Math.max(0, Number($("assetQty").value || 0));
            const isBuy = this._side === "BUY";
            const price = isBuy ? this.buyPrice(sym) : this.sellPrice(sym);
            const raw = qty * price;
            const total = isBuy ? Math.ceil(raw * 100) / 100 : Math.floor(raw * 100) / 100;
            $("assetTotalLabel").textContent = isBuy ? "Ödenecek Tutar (yaklaşık)" : "Alacağınız Tutar (yaklaşık)";
            $("assetTotal").textContent = fmt(total);
            const row = $("assetTotalRow");
            row.classList.remove("buy", "sell");
            row.classList.add(isBuy ? "buy" : "sell");
        },

        _setBusy(busy) {
            this._busy = busy;
            ["assetBuyBtn", "assetSellBtn"].forEach(id => {
                const btn = $(id);
                if (!btn) return;
                btn.dataset.tradeBusy = String(busy);
                btn.disabled = busy || Borsa.state.marketOpen !== true;
            });
        },

        async trade(side) {
            const sym = this._current;
            if (!sym || this._busy) return;
            this.updateTotals(side);
            const meta = ASSETS[sym];
            const qty = floor4($("assetQty").value);
            if (!BorsaFirebase.currentUser()) { this.setFeedback("error", "Önce giriş yapın."); return; }
            if (Borsa.state.marketOpen !== true) { this.setFeedback("error", "Piyasa kapalı. Alım-satım yapılamaz."); return; }
            if (!(qty > 0)) { this.setFeedback("error", "Geçerli bir miktar girin."); return; }

            this._setBusy(true);
            this.setFeedback(null);
            try {
                const { data, error } = await window.sb.rpc("execute_asset_trade", {
                    p_asset: sym,
                    p_quantity: qty,
                    p_side: side,
                });
                if (error) throw new Error(error.message || "İşlem başarısız.");
                const doc = BorsaFirebase.currentUserData();
                if (doc && data) {
                    doc.balance = Number(data.balance ?? doc.balance);
                    doc.assets = data.assets || {};
                    BorsaFirebase._emit();
                }
                const total = Number(data?.total || 0);
                this.setFeedback("ok", side === "BUY"
                    ? `${fmtQty(qty)} ${meta.unit} ${meta.name} alındı, ${fmt(total)} ödendi.`
                    : `${fmtQty(qty)} ${meta.unit} ${meta.name} satıldı, ${fmt(total)} bakiyenize eklendi.`);
                this.updateModal();
                if (typeof window.invalidateSidebarCaches === "function") window.invalidateSidebarCaches();
            } catch (err) {
                this.setFeedback("error", err.message || "İşlem başarısız.");
            } finally {
                this._setBusy(false);
            }
        },

        // Portföy penceresindeki "Altın & Döviz" tablosu.
        renderPortfolio() {
            const root = $("portfolioAssets");
            if (!root) return;
            const rows = ORDER.filter(sym => this.held(sym) > 0);
            if (!rows.length) { root.innerHTML = ""; return; }
            const body = rows.map(sym => {
                const meta = ASSETS[sym];
                const qty = this.held(sym);
                const cost = this.cost(sym);
                const avg = qty > 0 ? cost / qty : 0;
                const price = this.mid(sym);
                const value = Math.round(qty * price * 100) / 100;
                const pnl = Math.round((value - cost) * 100) / 100;
                const pnlPct = cost > 0 ? pnl / cost * 100 : 0;
                const dir = pnl >= 0 ? "pf-up" : "pf-down";
                return `<tr>
                    <td>
                        <div class="pf-stock">
                            <div class="pf-avatar" style="background: linear-gradient(135deg, ${meta.color}, ${meta.color}aa);">${meta.icon}</div>
                            <div>
                                <div class="pf-name">${meta.name}</div>
                                <div class="pf-sym">TL / ${meta.unit}</div>
                            </div>
                        </div>
                    </td>
                    <td class="num pf-bold pf-cost">${avg > 0 ? fmt(avg) : "—"}</td>
                    <td class="num pf-bold">${price > 0 ? fmt(price) : "—"}</td>
                    <td class="num">${fmtQty(qty)} ${meta.unit}</td>
                    <td class="num pf-bold">${fmt(value)}</td>
                    <td class="num pf-pnl ${dir}"><span class="pf-pnl-tl">${pnl >= 0 ? "▲" : "▼"} ${fmt(Math.abs(pnl))}</span></td>
                    <td class="num pf-pnl ${dir}"><span class="pf-pnl-pct">${pnl >= 0 ? "+" : ""}${pnlPct.toFixed(2)}%</span></td>
                    <td class="num pf-action"><button type="button" class="portfolio-sell-btn" data-asset-open="${sym}">Al / Sat</button></td>
                </tr>`;
            }).join("");
            root.innerHTML = `
                <table class="portfolio-table">
                    <thead>
                        <tr>
                            <th>Altın &amp; Döviz</th>
                            <th class="num">Ort. Maliyet</th>
                            <th class="num">Güncel Fiyat</th>
                            <th class="num">Miktar</th>
                            <th class="num">Piyasa Değeri</th>
                            <th class="num">Anlık K / Z (₺)</th>
                            <th class="num">K / Z (%)</th>
                            <th class="num">İşlem</th>
                        </tr>
                    </thead>
                    <tbody>${body}</tbody>
                </table>`;
            root.querySelectorAll("[data-asset-open]").forEach(btn => {
                btn.addEventListener("click", () => this.open(btn.dataset.assetOpen));
            });
        },

        wire() {
            const modal = $("assetModal");
            if (!modal) return;
            $("assetCloseBtn").addEventListener("click", () => this.close());
            modal.addEventListener("click", (e) => { if (e.target === modal) this.close(); });
            $("assetQty").addEventListener("input", () => this.updateTotals());
            $("assetBuyBtn").addEventListener("click", () => this.trade("BUY"));
            $("assetSellBtn").addEventListener("click", () => this.trade("SELL"));
            $("assetMaxBuyBtn").addEventListener("click", () => {
                const sym = this._current;
                if (!sym || !(this.buyPrice(sym) > 0)) return;
                $("assetQty").value = String(floor4(BorsaFirebase.balance() / this.buyPrice(sym)));
                this.updateTotals("BUY");
            });
            $("assetSellAllBtn").addEventListener("click", () => {
                const sym = this._current;
                if (!sym) return;
                $("assetQty").value = String(this.held(sym));
                this.updateTotals("SELL");
            });
            BorsaFirebase.onChange(() => this.updateModal());
            window.addEventListener("borsa:market-status-updated", () => this.updateModal());
            this.renderGrid();
        },
    };

    window.BorsaAssets = BorsaAssets;

    document.addEventListener("DOMContentLoaded", () => {
        BorsaAssets.wire();
        if (window.sb && typeof window.sb.channel === "function") {
            BorsaAssets.start();
        } else {
            window.addEventListener("borsa:supabase-ready", () => BorsaAssets.start(), { once: true });
        }
    });
})();
