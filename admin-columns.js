/* Admin paneli: köşe yazısı yayınlama ve silme.
 * Yazma admin_publish_column / admin_delete_column RPC'leri ile; liste guest_columns tablosundan okunur.
 */
(function () {
    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML.replace(/"/g, "&quot;");
    };
    const ok = (msg) => (typeof window.showToast === "function" ? window.showToast(msg) : alert(msg));
    const fail = (msg) => (typeof window.showErr === "function" ? window.showErr(msg) : alert(msg));

    const AdminColumns = {
        _loadedFor: null,

        fillStocks() {
            const select = $("columnSymbol");
            if (!select) return;
            const previous = select.value;
            const stocks = (window.Borsa && Borsa.state.stocks) || {};
            select.innerHTML = '<option value="">Tahmin yok</option>' + Object.keys(stocks).sort().map(sym =>
                `<option value="${esc(sym)}">${esc(stocks[sym].name)} (${esc(sym)})</option>`).join("");
            if (previous && stocks[previous]) select.value = previous;
            this.togglePrediction();
        },

        togglePrediction() {
            const has = Boolean($("columnSymbol") && $("columnSymbol").value);
            ["columnDirection", "columnDays"].forEach(id => { if ($(id)) $(id).disabled = !has; });
        },

        async loadList() {
            const list = $("columnList");
            if (!list || !window.sb || !window.sb.from) return;
            const { data, error } = await window.sb
                .from("guest_columns")
                .select("id, author_name, title, stock_symbol, direction, result, created_at")
                .order("created_at", { ascending: false })
                .limit(20);
            if (error) {
                list.innerHTML = `<p class="field-hint">Yazılar okunamadı: ${esc(error.message)}</p>`;
                return;
            }
            if (!data || data.length === 0) {
                list.innerHTML = '<p class="field-hint">Henüz yayınlanmış köşe yazısı yok.</p>';
                return;
            }
            list.innerHTML = data.map(c => {
                const prediction = c.stock_symbol && c.direction
                    ? ` · ${esc(c.stock_symbol)} ${c.direction === "UP" ? "yükselir" : "düşer"}${c.result === "HIT" ? " ✅" : c.result === "MISS" ? " ❌" : " ⏳"}`
                    : "";
                return `
                <div class="column-admin-row">
                    <div class="column-admin-text">
                        <strong>${esc(c.title)}</strong>
                        <span>${esc(c.author_name)} · ${new Date(c.created_at).toLocaleDateString("tr-TR")}${prediction}</span>
                    </div>
                    <button type="button" class="reset-btn" data-column-delete="${Number(c.id)}">Sil</button>
                </div>`;
            }).join("");
        },

        async publish(event) {
            event.preventDefault();
            const button = $("columnSubmitBtn");
            button.disabled = true;
            try {
                const symbol = $("columnSymbol").value || null;
                const { error } = await window.sb.rpc("admin_publish_column", {
                    p_author_name: $("columnAuthor").value,
                    p_author_title: $("columnAuthorTitle").value,
                    p_title: $("columnTitle").value,
                    p_body: $("columnBody").value,
                    p_symbol: symbol,
                    p_direction: symbol ? $("columnDirection").value : null,
                    p_days: Math.round(Number($("columnDays").value || 7)),
                });
                if (error) throw error;
                ["columnTitle", "columnBody"].forEach(id => { $(id).value = ""; });
                $("columnSymbol").value = "";
                this.togglePrediction();
                ok("Köşe yazısı yayınlandı.");
                await this.loadList();
                if (window.Borsa && typeof Borsa.loadColumns === "function") Borsa.loadColumns();
            } catch (err) {
                fail(err.message || "Köşe yazısı yayınlanamadı.");
            } finally {
                button.disabled = false;
            }
        },

        async remove(id) {
            if (!confirm("Bu köşe yazısı silinsin mi? Geri alınamaz.")) return;
            try {
                const { error } = await window.sb.rpc("admin_delete_column", { p_id: id });
                if (error) throw error;
                ok("Köşe yazısı silindi.");
                await this.loadList();
                if (window.Borsa && typeof Borsa.loadColumns === "function") Borsa.loadColumns();
            } catch (err) {
                fail(err.message || "Köşe yazısı silinemedi.");
            }
        },

        wire() {
            const form = $("columnForm");
            if (!form) return;
            form.addEventListener("submit", (e) => this.publish(e));
            $("columnSymbol").addEventListener("focus", () => this.fillStocks());
            $("columnSymbol").addEventListener("change", () => this.togglePrediction());
            $("columnList").addEventListener("click", (e) => {
                const button = e.target.closest("[data-column-delete]");
                if (button) this.remove(Number(button.dataset.columnDelete));
            });
            this.togglePrediction();
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (!uid || uid === this._loadedFor) return;
                this._loadedFor = uid;
                this.loadList();
                // Hisseler yüklendikten sonra tahmin listesi doldurulur.
                setTimeout(() => this.fillStocks(), 2500);
            });
        },
    };

    window.AdminColumns = AdminColumns;
    document.addEventListener("DOMContentLoaded", () => AdminColumns.wire());
})();
