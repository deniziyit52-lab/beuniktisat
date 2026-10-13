/* Şirket Karnesi: hissenin sektörü, neye duyarlı olduğu ve son dönem performansı (get_stock_reports RPC'si).
   Hisseler gerçek borsadaki benzer şirketlerin hareketini izler; hangi şirket olduğu oyuncuya gönderilmez. */
(function () {
    const CACHE_MS = 10 * 60 * 1000;
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML;
    };
    const ARROWS = {
        up: { icon: "▲", label: "Olumlu", cls: "is-up" },
        down: { icon: "▼", label: "Olumsuz", cls: "is-down" },
        mixed: { icon: "◆", label: "Karışık", cls: "is-mixed" },
    };
    const VOL = { low: "Düşük", mid: "Orta", high: "Yüksek" };

    const BorsaReport = {
        _data: null,
        _loadedAt: 0,
        _loading: null,

        async _load() {
            if (this._data && Date.now() - this._loadedAt < CACHE_MS) return this._data;
            if (this._loading) return this._loading;
            if (!window.sb || !window.sb.rpc) return null;
            this._loading = window.sb.rpc("get_stock_reports").then(({ data, error }) => {
                this._loading = null;
                if (error || !data) return this._data;
                this._data = data;
                this._loadedAt = Date.now();
                return data;
            }, () => { this._loading = null; return this._data; });
            return this._loading;
        },

        _pct(value) {
            const n = Number(value);
            if (!Number.isFinite(n)) return '<strong>—</strong>';
            const cls = n > 0 ? "is-up" : n < 0 ? "is-down" : "";
            return `<strong class="${cls}">${n > 0 ? "+" : ""}${n}%</strong>`;
        },

        // 26.990.000.000 -> "26,99 mlr ₺"
        _money(value) {
            const n = Number(value);
            if (value == null || !Number.isFinite(n)) return "—";
            const abs = Math.abs(n);
            const fmt = (x, d) => x.toLocaleString("tr-TR", { minimumFractionDigits: d, maximumFractionDigits: d });
            if (abs >= 1e9) return fmt(n / 1e9, 2) + " mlr ₺";
            if (abs >= 1e6) return fmt(n / 1e6, 0) + " mn ₺";
            return fmt(n, 0) + " ₺";
        },

        _quarter(dateText) {
            const d = new Date(dateText);
            if (isNaN(d)) return "—";
            return `${d.getUTCFullYear()} / ${Math.floor(d.getUTCMonth() / 3) + 1}. çeyrek`;
        },

        _num(value, suffix) {
            const n = Number(value);
            if (value == null || !Number.isFinite(n)) return "—";
            return n.toLocaleString("tr-TR", { maximumFractionDigits: 2 }) + (suffix || "");
        },

        // Mali tablolar: son çeyreklerin satış ve kârı, bilanço özeti ve dört temel oran.
        _financialsMarkup(f) {
            if (!f || !Array.isArray(f.quarters) || !f.quarters.length) return "";
            const rows = f.quarters.slice().reverse().map(q => `
                <tr>
                    <th>${esc(this._quarter(q.d))}</th>
                    <td>${esc(this._money(q.rev))}</td>
                    <td class="${Number(q.net) < 0 ? "is-down" : ""}">${esc(this._money(q.net))}</td>
                </tr>`).join("");
            const tile = (label, value, hint) => `<div><span>${label}</span><strong>${esc(value)}</strong>${hint ? `<small>${hint}</small>` : ""}</div>`;
            return `
                <div class="report-title">Mali tablolar · son açıklanan: ${esc(this._quarter(f.latest))}</div>
                <table class="report-table">
                    <thead><tr><th>Dönem</th><th>Satışlar</th><th>Net kâr</th></tr></thead>
                    <tbody>${rows}</tbody>
                </table>
                <div class="report-stats report-stats--money">
                    ${tile("Toplam varlık", this._money(f.assets))}
                    ${tile("Toplam borç", this._money(f.liabilities))}
                    ${tile("Özkaynak", this._money(f.equity))}
                    ${tile("Nakit", this._money(f.cash))}
                </div>
                <div class="report-title">Temel oranlar</div>
                <div class="report-stats report-stats--ratios">
                    ${tile("Fiyat / Kazanç", this._num(f.pe), "Hisse, yıllık kârının kaç katına satılıyor. Düşükse ucuz sayılır.")}
                    ${tile("PD / DD", this._num(f.pb), "Şirketin borsa değeri, özkaynağının kaç katı.")}
                    ${tile("Net kâr marjı", this._num(f.margin, "%"), "100 ₺ satıştan şirkete kalan kâr.")}
                    ${tile("Borç / Özkaynak", this._num(f.debt_equity), "Her 1 ₺ özkaynağa karşılık kaç ₺ borç var.")}
                </div>`;
        },

        _markup(r) {
            const stats = r.stats || null;
            const pos = stats && Number.isFinite(Number(stats.pos52)) ? Math.max(0, Math.min(100, Number(stats.pos52))) : null;
            return `
                <p class="report-sector"><span class="report-chip">${esc(r.sector)}</span>${r.live ? '<span class="report-live">● Gerçek veriyle canlı</span>' : ""}</p>
                <p class="report-summary">${esc(r.summary)}</p>
                <div class="report-title">Neye duyarlı?</div>
                <ul class="report-list">
                    ${(Array.isArray(r.sensitivities) ? r.sensitivities : []).map(s => {
                        const a = ARROWS[s.d] || ARROWS.mixed;
                        return `<li><span class="report-arrow ${a.cls}" title="${a.label}">${a.icon}</span><span><strong>${esc(s.k)}</strong> ${esc(s.t)}</span></li>`;
                    }).join("")}
                </ul>
                ${stats ? `
                <div class="report-title">Son dönem</div>
                <div class="report-stats">
                    <div><span>1 hafta</span>${this._pct(stats.w1)}</div>
                    <div><span>1 ay</span>${this._pct(stats.m1)}</div>
                    <div><span>3 ay</span>${this._pct(stats.m3)}</div>
                    <div><span>Oynaklık</span><strong>${esc(VOL[stats.vol] || "—")}</strong></div>
                </div>
                ${pos == null ? "" : `
                <div class="report-range" title="Son bir yılın en düşük ve en yüksek fiyatı arasındaki yeri">
                    <span>1 yılın en düşüğü</span>
                    <div class="report-range-bar"><i style="left:${pos}%"></i></div>
                    <span>en yükseği</span>
                </div>`}` : ""}
                ${this._financialsMarkup(r.financials)}
                <p class="report-note">Bu hisse, gerçek borsada aynı sektördeki bir şirketin fiyat hareketini izler. Yukarıdaki getiriler ve mali tablolar o şirketin gerçek verileridir. Oyuncuların alım-satımı fiyatı kısa süreliğine oynatabilir, ama fiyat zamanla gerçek ize geri döner.</p>`;
        },

        // İşlem penceresi açılırken çağrılır.
        async show(symbol) {
            const box = document.getElementById("tradeReport");
            const body = document.getElementById("tradeReportBody");
            if (!box || !body) return;
            box.style.display = "none";
            box.dataset.symbol = symbol;
            const data = await this._load();
            if (box.dataset.symbol !== symbol) return;
            const report = data && data.enabled && data.reports ? data.reports[symbol] : null;
            if (!report) return;
            body.innerHTML = this._markup(report);
            box.style.display = "";
        },
    };

    window.BorsaReport = BorsaReport;
})();
