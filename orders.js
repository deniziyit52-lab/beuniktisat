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
    const stockName = (sym) => (window.Borsa && Borsa.state && Borsa.state.stocks[sym] && Borsa.state.stocks[sym].name) || sym;
    const when = (iso) => iso ? new Date(iso).toLocaleString("tr-TR", { day: "2-digit", month: "2-digit", hour: "2-digit", minute: "2-digit" }) : "";
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
                const price = $("orderPrice");
                if (price && !price.value && this.symbol) {
                    const s = window.Borsa && Borsa.state.stocks[this.symbol];
                    if (s) price.placeholder = "Şu an " + Number(s.price).toLocaleString("tr-TR", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
                }
            }
            this.updateHint();
        },

        updateHint() {
            const hint = $("orderHint");
            if (!hint) return;
            const p = Number(($("orderPrice") || {}).value || 0);
            const ps = p > 0 ? tl(p) : "yazdığın fiyat";
            hint.textContent = this.mode === "STOP"
                ? `Fiyat ${ps} ya da altına inince elindeki hisse o anki fiyattan satılır; zararı sınırlamak için kullanılır.`
                : `Limit Al: fiyat ${ps} ya da altına inince alır. Limit Sat: fiyat ${ps} ya da üstüne çıkınca satar. ` +
                  "Gerçekleşince o anki fiyattan, komisyon ve kayma dahil işlem yapılır. Para şimdi ayrılmaz; o an bakiyen yetmezse emir gerçekleşmez.";
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
