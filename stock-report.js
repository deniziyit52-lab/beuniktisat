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
                <p class="report-note">Bu hisse, gerçek borsada aynı sektördeki bir şirketin fiyat hareketini izler. Yukarıdaki getiriler o gerçek hareketten gelir. Oyuncuların alım-satımı fiyatı kısa süreliğine oynatabilir, ama fiyat zamanla gerçek ize geri döner.</p>`;
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
