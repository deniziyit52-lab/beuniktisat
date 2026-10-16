/* Bekleyen emirler: işlem penceresinde emir türü (Hemen / Limit / Zarar Durdur), o hissenin bekleyen emirleri
   ve kenar menüdeki "Emirler" sekmesi. Emirler sunucuda (place_stock_order, cancel_stock_order) tutulur ve
   piyasa açıkken her dakika kontrol edilir; gerçekleşen emir için ekranda kısa bir bildirim çıkar. */
(function () {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML.replace(/"/g, "&quot;");
    };
    const tl = (n) => (window.BorsaFirebase && BorsaFirebase.formatTL) ? BorsaFirebase.formatTL(Number(n || 0))
        : Number(n || 0).toLocaleString("tr-TR", { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + " ₺";
    // shared.js Borsa'yı düz "const" olarak tanımlar; window.Borsa yoktur.
    const B = () => (typeof Borsa !== "undefined" ? Borsa : null);
    const stockName = (sym) => (B() && B().state && B().state.stocks[sym] && B().state.stocks[sym].name) || sym;
    const when = (iso) => iso ? new Date(iso).toLocaleString("tr-TR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }) : "";
    const round2 = (n) => Math.round(Number(n || 0) * 100) / 100;
    const num2 = (n) => Number(n || 0).toLocaleString("tr-TR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    const signedIn = () => Boolean(window.BorsaFirebase && BorsaFirebase.currentUser && BorsaFirebase.currentUser());

    const LABEL = {
        "LIMIT:BUY": "Limit Al",
        "LIMIT:SELL": "Limit Sat",
        "STOP:SELL": "Zarar Durdur",
    };
    const COND = {
        "LIMIT:BUY": "fiyat ≤",
        "LIMIT:SELL": "fiyat ≥",
        "STOP:SELL": "fiyat ≤",
    };
    const STATUS = { pending: "Bekliyor", filled: "Gerçekleşti", cancelled: "İptal", failed: "Gerçekleşemedi" };

    const BorsaOrders = {
        mode: "MARKET",
        symbol: null,
        _pendingIds: new Set(),
        _pollTimer: null,

        // ---------- İşlem penceresi ----------
        setMode(mode) {
            this.mode = mode;
            document.querySelectorAll("[data-order-mode]").forEach(b => {
                const on = b.dataset.orderMode === mode;
                b.classList.toggle("order-mode-btn--active", on);
                b.setAttribute("aria-selected", on ? "true" : "false");
            });
            const market = mode === "MARKET";
            const show = (id, on) => { const el = $(id); if (el) el.hidden = !on; };
            show("orderPriceRow", !market);
            show("orderActions", !market);
            show("tradeSummary", market);
            show("tradeAmountHint", market);
            const amountBox = $("tradeAmount") && $("tradeAmount").closest(".trade-input");
            if (amountBox) amountBox.hidden = !market;
            document.querySelectorAll(".trade-actions:not(#orderActions)").forEach(el => { el.hidden = !market; });
            if (!market) {
                $("orderBuyBtn").hidden = mode === "STOP";
                $("orderSellBtn").textContent = mode === "STOP" ? "🛑 Zarar Durdur Emri Ver" : "📌 Limit Sat Emri Ver";
                // Kendiliğinden makul bir başlangıç: zarar durdurda fiyatın %5 altı ve elindeki adedin tamamı.
                const price = $("orderPrice");
                const now = this.nowPrice();
                if (price && now > 0) {
                    price.placeholder = "Şu an " + num2(now);
                    if (mode === "STOP") {
                        price.value = round2(now * 0.95);
                        const h = this.holding();
                        if (h.qty > 0 && $("tradeQty")) $("tradeQty").value = Math.floor(h.qty);
                    } else if (!price.value) {
                        price.value = round2(now);
                    }
                }
                this.renderChips();
            }
            this.updateHint();
        },

        nowPrice() {
            const s = B() && B().state && B().state.stocks[this.symbol];
            return s ? Number(s.price || 0) : 0;
        },

        holding() {
            const doc = window.BorsaFirebase && BorsaFirebase.currentUserData ? BorsaFirebase.currentUserData() : null;
            const e = doc && doc.portfolio && doc.portfolio[this.symbol];
            return { qty: Number(e && e.qty || 0), cost: Number(e && (e.costBasis || e.avg || e.cost) || 0) };
        },

        // Tetik fiyatını yazdırmak yerine seçtiren düğmeler: güncel fiyata ve (varsa) maliyete göre.
        renderChips() {
            const box = $("orderChips");
            if (!box) return;
            const now = this.nowPrice();
            const h = this.holding();
            const chips = [];
            if (this.mode === "STOP") {
                [-3, -5, -10, -15].forEach(p => chips.push({ label: `%${Math.abs(p)} düşerse`, price: now * (1 + p / 100) }));
                if (h.qty > 0 && h.cost > 0) {
                    if (h.cost < now) chips.push({ label: "Maliyetime inerse", price: h.cost, title: "Kârını korur: fiyat aldığın fiyata inerse satar" });
                    chips.push({ label: "Maliyetin %5 altı", price: h.cost * 0.95 });
                }
            } else {
                [-5, -2].forEach(p => chips.push({ label: `%${Math.abs(p)} ucuz`, price: now * (1 + p / 100), side: "BUY" }));
                chips.push({ label: "Şu an", price: now });
                [2, 5, 10].forEach(p => chips.push({ label: `%${p} pahalı`, price: now * (1 + p / 100), side: "SELL" }));
                if (h.qty > 0 && h.cost > 0) chips.push({ label: "Maliyetin %10 üstü", price: h.cost * 1.10, side: "SELL", title: "Kâr al: %10 kârda satar" });
            }
            box.innerHTML = chips.filter(c => c.price > 0).map(c =>
                `<button type="button" class="chip-btn order-chip${c.side === "BUY" ? " order-chip--buy" : c.side === "SELL" ? " order-chip--sell" : ""}" data-order-price="${round2(c.price)}"${c.title ? ` title="${esc(c.title)}"` : ""}>${esc(c.label)}<small>${num2(c.price)}</small></button>`
            ).join("");
            box.querySelectorAll("[data-order-price]").forEach(b => {
                b.addEventListener("click", () => {
                    $("orderPrice").value = b.dataset.orderPrice;
                    this.updateHint();
                });
            });
        },

        updateHint() {
            const hint = $("orderHint");
            const info = $("orderInfo");
            if (!hint) return;
            const p = Number(($("orderPrice") || {}).value || 0);
            const now = this.nowPrice();
            const qty = Math.floor(Number(($("tradeQty") || {}).value || 0));
            const h = this.holding();
            const ps = p > 0 ? tl(p) : "yazdığın fiyat";

            // Canlı açıklama: tetik güncel fiyattan ne kadar uzak, gerçekleşirse ne olur.
            const lines = [];
            if (p > 0 && now > 0) {
                const diff = (p / now - 1) * 100;
                const away = Math.abs(diff) < 0.05 ? "şu anki fiyatla aynı" : `şu anki fiyattan %${Math.abs(diff).toLocaleString("tr-TR", { maximumFractionDigits: 1 })} ${diff < 0 ? "aşağıda" : "yukarıda"}`;
                lines.push(`Şu an <b>${tl(now)}</b>; tetik ${away}.`);
                if (this.mode === "LIMIT") {
                    if (p >= now) lines.push(`<span class="order-warn">Limit Al bu fiyatta hemen (bir dakika içinde) gerçekleşir.</span>`);
                    if (p <= now) lines.push(`<span class="order-warn">Limit Sat bu fiyatta hemen (bir dakika içinde) gerçekleşir.</span>`);
                    if (qty > 0) lines.push(`Alırsan yaklaşık <b>${tl(qty * p)}</b> ödersin.`);
                } else if (p >= now) {
                    lines.push(`<span class="order-warn">Fiyat zaten bunun altında; emir hemen (bir dakika içinde) satar.</span>`);
                }
                const sellQty = Math.min(qty, Math.floor(h.qty));
                if ((this.mode === "STOP" || p > now) && sellQty > 0 && h.cost > 0) {
                    const pl = (p - h.cost) * sellQty;
                    lines.push(`Satarsan ${sellQty} adet için maliyetine göre yaklaşık <b class="${pl >= 0 ? "order-up" : "order-down"}">${pl >= 0 ? "+" : "−"}${tl(Math.abs(pl))}</b> ${pl >= 0 ? "kâr" : "zarar"} (komisyon hariç).`);
                }
            }
            if (info) info.innerHTML = lines.join("<br>");

            hint.textContent = this.mode === "STOP"
                ? `Fiyat ${ps} ya da altına inince elindeki hisse o anki fiyattan satılır; büyük bir düşüşte zararını sınırlar.`
                : `Ucuza almak için şu anki fiyatın altını seçip "Limit Al"a, kârla satmak için üstünü seçip "Limit Sat"a bas. ` +
                  "Gerçekleşince o anki fiyattan, komisyon dahil işlem yapılır. Para şimdi ayrılmaz; o an bakiyen yetmezse emir gerçekleşmez.";
        },

        async place(side) {
            const fb = $("tradeFeedback");
            const say = (type, msg) => {
                if (!fb) return alert(msg);
                fb.style.display = "block";
                fb.style.background = type === "error" ? "rgba(239,68,68,0.1)" : "rgba(16,185,129,0.1)";
                fb.style.color = type === "error" ? "#f87171" : "#34d399";
                fb.textContent = msg;
            };
            if (!signedIn()) return say("error", "Emir vermek için giriş yapın.");
            const qty = Math.floor(Number(($("tradeQty") || {}).value || 0));
            const price = Number(($("orderPrice") || {}).value || 0);
            if (!(qty > 0)) return say("error", "Geçerli bir adet girin.");
            if (!(price > 0)) return say("error", "Tetik fiyatını yazın.");
            const btns = [$("orderBuyBtn"), $("orderSellBtn")];
            btns.forEach(b => { if (b) b.disabled = true; });
            try {
                const { error } = await window.sb.rpc("place_stock_order", {
                    p_symbol: this.symbol, p_side: side, p_kind: this.mode, p_qty: qty, p_price: price,
                });
                if (error) throw error;
                const label = LABEL[`${this.mode}:${side}`];
                say("success", `✅ ${label} emrin kaydedildi: ${qty} adet, tetik ${tl(price)}. Piyasa açıkken her dakika kontrol edilir.`);
                $("orderPrice").value = "";
                this.updateHint();
                await this.loadForSymbol();
                this.startPolling();
            } catch (err) {
                say("error", err.message || "Emir verilemedi.");
            } finally {
                btns.forEach(b => { if (b) b.disabled = false; });
            }
        },

        async cancel(id) {
            if (!confirm("Bu emir iptal edilsin mi?")) return;
            const { error } = await window.sb.rpc("cancel_stock_order", { p_id: Number(id) });
            if (error) return alert(error.message || "Emir iptal edilemedi.");
            this._pendingIds.delete(Number(id));
            this.loadForSymbol();
            this.loadAll();
        },

        rowHtml(o, withName) {
            const key = `${o.kind}:${o.side}`;
            const done = o.status !== "pending";
            const detail = o.status === "filled"
                ? `${o.fill_qty || o.qty} adet × ${tl(o.fill_price)} · ${when(o.done_at)}`
                : done ? `${esc(o.note || "")} ${when(o.done_at)}` : `${o.qty} adet · ${COND[key]} ${tl(o.trigger_price)}`;
            return `
                <li class="order-row order-row--${esc(o.status)}">
                    <div class="order-row-main">
                        <strong>${esc(LABEL[key] || key)}${withName ? " · " + esc(stockName(o.symbol)) : ""}</strong>
                        <small>${detail}</small>
                    </div>
                    ${done ? `<span class="order-status">${STATUS[o.status] || o.status}</span>`
                           : `<button type="button" class="order-cancel" data-order-cancel="${o.id}">İptal</button>`}
                </li>`;
        },

        bindCancel(root) {
            root.querySelectorAll("[data-order-cancel]").forEach(b => {
                b.addEventListener("click", () => this.cancel(b.dataset.orderCancel));
            });
        },

        async loadForSymbol() {
            const box = $("tradeOrders");
            if (!box) return;
            if (!signedIn() || !this.symbol) { box.hidden = true; return; }
            const { data, error } = await window.sb.from("stock_orders")
                .select("*").eq("symbol", this.symbol).eq("status", "pending").order("created_at", { ascending: false });
            if (error || !Array.isArray(data) || !data.length) { box.hidden = true; return; }
            box.hidden = false;
            box.innerHTML = `<div class="order-list-title">📋 Bu hissedeki bekleyen emirlerin</div><ul class="order-list">${data.map(o => this.rowHtml(o, false)).join("")}</ul>`;
            this.bindCancel(box);
        },

        show(symbol) {
            this.symbol = symbol;
            const fb = $("tradeFeedback");
            if (fb && this.mode !== "MARKET") { fb.style.display = "none"; }
            if ($("orderPrice")) $("orderPrice").value = "";
            this.setMode("MARKET");
            this.loadForSymbol();
        },

        // ---------- Kenar menü: Emirler ----------
        async loadAll() {
            const list = $("ordersList");
            if (!list) return;
            if (!signedIn()) { list.innerHTML = '<li class="transactions-empty">Emirlerini görmek için giriş yapın.</li>'; return; }
            const { data, error } = await window.sb.from("stock_orders")
                .select("*").order("created_at", { ascending: false }).limit(40);
            if (error) { list.innerHTML = `<li class="transactions-empty">Yüklenemedi: ${esc(error.message)}</li>`; return; }
            if (!data.length) {
                list.innerHTML = '<li class="transactions-empty">Henüz emir vermedin. Bir hisseyi açıp "Limit" ya da "Zarar Durdur"u seçerek emir verebilirsin.</li>';
                return;
            }
            const pending = data.filter(o => o.status === "pending");
            const past = data.filter(o => o.status !== "pending");
            list.innerHTML =
                (pending.length ? `<li class="order-list-title">⏳ Bekleyen (${pending.length})</li>${pending.map(o => this.rowHtml(o, true)).join("")}` : "") +
                (past.length ? `<li class="order-list-title">🗂 Geçmiş</li>${past.map(o => this.rowHtml(o, true)).join("")}` : "");
            this.bindCancel(list);
        },

        // ---------- Gerçekleşen emir bildirimi ----------
        toast(msg, ok) {
            const el = document.createElement("div");
            el.className = "order-toast" + (ok ? "" : " order-toast--fail");
            el.textContent = msg;
            document.body.appendChild(el);
            requestAnimationFrame(() => el.classList.add("order-toast--show"));
            setTimeout(() => { el.classList.remove("order-toast--show"); setTimeout(() => el.remove(), 400); }, 7000);
        },

        async poll() {
            if (!signedIn() || document.hidden) return;
            const { data, error } = await window.sb.from("stock_orders")
                .select("id, symbol, side, kind, qty, status, fill_qty, fill_price, note")
                .or(`status.eq.pending${this._pendingIds.size ? `,id.in.(${[...this._pendingIds].join(",")})` : ""}`);
            if (error || !Array.isArray(data)) return;
            let changed = false;
            for (const o of data) {
                if (o.status === "pending") { this._pendingIds.add(o.id); continue; }
                if (!this._pendingIds.has(o.id)) continue;
                this._pendingIds.delete(o.id);
                changed = true;
                const label = LABEL[`${o.kind}:${o.side}`] || "Emir";
                if (o.status === "filled") {
                    this.toast(`✅ ${label} emrin gerçekleşti: ${stockName(o.symbol)}, ${o.fill_qty || o.qty} adet × ${tl(o.fill_price)}`, true);
                } else if (o.status === "failed" || o.status === "cancelled") {
                    this.toast(`⚠️ ${label} emrin gerçekleşemedi (${stockName(o.symbol)}): ${o.note || ""}`, false);
                }
            }
            if (changed) {
                try { if (BorsaFirebase.refreshUserDoc) await BorsaFirebase.refreshUserDoc(); } catch (e) {}
                document.dispatchEvent(new CustomEvent("borsa:orders-changed"));
                this.loadForSymbol();
                if ($("panelOrders") && $("panelOrders").classList.contains("sidebar-panel--active")) this.loadAll();
            }
            if (!this._pendingIds.size) this.stopPolling();
        },

        startPolling() {
            if (this._pollTimer) return;
            this._pollTimer = setInterval(() => this.poll(), 30 * 1000);
            this.poll();
        },
        stopPolling() {
            clearInterval(this._pollTimer);
            this._pollTimer = null;
        },

        wire() {
            document.querySelectorAll("[data-order-mode]").forEach(b => {
                b.addEventListener("click", () => this.setMode(b.dataset.orderMode));
            });
            if ($("orderPrice")) $("orderPrice").addEventListener("input", () => this.updateHint());
            if ($("tradeQty")) $("tradeQty").addEventListener("input", () => { if (this.mode !== "MARKET") this.updateHint(); });
            if ($("tradeQuick")) $("tradeQuick").addEventListener("click", () => { if (this.mode !== "MARKET") setTimeout(() => this.updateHint(), 0); });
            // Pencere açıkken fiyat değiştikçe düğmeler ve açıklama tazelenir.
            setInterval(() => {
                const modal = $("tradeModal");
                if (this.mode === "MARKET" || !modal || modal.style.display !== "flex" || document.hidden) return;
                this.renderChips();
                this.updateHint();
            }, 15 * 1000);
            if ($("orderBuyBtn")) $("orderBuyBtn").addEventListener("click", () => this.place("BUY"));
            if ($("orderSellBtn")) $("orderSellBtn").addEventListener("click", () => this.place("SELL"));
            if ($("refreshOrdersBtn")) $("refreshOrdersBtn").addEventListener("click", () => this.loadAll());
            if (window.BorsaFirebase && BorsaFirebase.onChange) {
                let last = null;
                BorsaFirebase.onChange((user) => {
                    const uid = user ? user.id : null;
                    if (uid === last) return;
                    last = uid;
                    this._pendingIds.clear();
                    this.stopPolling();
                    if (uid) this.startPolling();
                });
            }
        },
    };

    window.BorsaOrders = BorsaOrders;
    document.addEventListener("DOMContentLoaded", () => BorsaOrders.wire());
})();
