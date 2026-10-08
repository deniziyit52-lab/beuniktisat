/* Admin paneli: oyun ayarları, sınav soruları ve oyunu sıfırlama.
 * Okuma admin_get_settings, yazma admin_save_settings / admin_save_quiz_question / admin_reset_game RPC'leri ile.
 */
(function () {
    const TYPE_LABELS = { guvenli: "Güvenli", orta: "Orta", riskli: "Riskli" };
    const REFERENCE_TRADE = 100000; // "100.000 TL'lik işlem fiyatı % kaç oynatır" gösterimi için

    const $ = (id) => document.getElementById(id);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML.replace(/"/g, "&quot;");
    };
    // Kesir <-> yüzde (0.05 <-> 5); kayan nokta artıklarını temizler.
    const toPct = (v) => Number((Number(v || 0) * 100).toFixed(4));
    const fromPct = (v) => Number((Number(v || 0) / 100).toFixed(6));
    const ok = (msg) => (typeof window.showToast === "function" ? window.showToast(msg) : alert(msg));
    const fail = (msg) => (typeof window.showErr === "function" ? window.showErr(msg) : alert(msg));

    const AdminSettings = {
        _data: null,
        _loadedFor: null,

        async load() {
            const root = $("adminSettingsBody");
            if (!root || !window.sb || !window.sb.rpc) return;
            const { data, error } = await window.sb.rpc("admin_get_settings");
            if (error || !data) {
                root.innerHTML = `<p class="field-hint">Ayarlar yüklenemedi: ${esc(error ? error.message : "boş cevap")}</p>`;
                return;
            }
            this._data = data;
            this.render();
        },

        render() {
            const root = $("adminSettingsBody");
            const d = this._data;
            if (!root || !d) return;
            const engine = d.engine || {};
            const tiers = Array.isArray(engine.quiz_bonus_tiers) ? engine.quiz_bonus_tiers : [];

            const typeRows = (d.types || []).map(t => `
                <tr data-type="${esc(t.risk_type)}">
                    <th>${esc(TYPE_LABELS[t.risk_type] || t.label || t.risk_type)}</th>
                    <td><input type="number" step="0.1" min="0" data-f="daily_sigma" value="${toPct(t.daily_sigma)}"></td>
                    <td><input type="number" step="0.1" min="0" data-f="shock_per_day" value="${Number(t.shock_per_day)}"></td>
                    <td><input type="number" step="0.1" min="0" data-f="shock_min" value="${toPct(t.shock_min)}"></td>
                    <td><input type="number" step="0.1" min="0" data-f="shock_max" value="${toPct(t.shock_max)}"></td>
                    <td><input type="number" step="0.1" min="0.1" data-f="impact" value="${toPct(REFERENCE_TRADE / Number(t.impact_depth))}"></td>
                </tr>`).join("");

            const tierRows = tiers.map(t => `
                <div class="form-row settings-tier">
                    <div class="form-group">
                        <label>En az doğru sayısı</label>
                        <input type="number" step="1" min="0" data-tier="min" value="${Number(t.min)}">
                    </div>
                    <div class="form-group">
                        <label>Bonus (₺)</label>
                        <input type="number" step="1000" min="0" data-tier="bonus" value="${Number(t.bonus)}">
                    </div>
                </div>`).join("");

            const questions = (d.questions || []).map((q, i) => `
                <details class="settings-question" data-qid="${Number(q.id)}">
                    <summary>${i + 1}. ${esc(q.question)}</summary>
                    <div class="form-group">
                        <label>Soru</label>
                        <textarea rows="2" data-q="question">${esc(q.question)}</textarea>
                    </div>
                    ${(q.options || []).map((opt, j) => `
                        <div class="settings-option">
                            <input type="radio" name="settings-correct-${Number(q.id)}" value="${j}" ${j === Number(q.correct_index) ? "checked" : ""} title="Doğru cevap">
                            <input type="text" data-q="option" value="${esc(opt)}">
                        </div>`).join("")}
                    <small class="field-hint">Soldaki yuvarlak, doğru cevabı işaretler.</small>
                    <button type="button" class="submit-btn" data-q="save">Bu Soruyu Kaydet</button>
                </details>`).join("");

            root.innerHTML = `
                <div class="panel-sub">📈 Hisse Türleri</div>
                <div class="table-scroll">
                    <table class="settings-table">
                        <thead>
                            <tr>
                                <th>Tür</th>
                                <th>Günlük oynaklık (%)</th>
                                <th>Günde şok sayısı</th>
                                <th>Şok en az (%)</th>
                                <th>Şok en çok (%)</th>
                                <th>100.000 ₺'lik işlemin etkisi (%)</th>
                            </tr>
                        </thead>
                        <tbody>${typeRows}</tbody>
                    </table>
                </div>

                <div class="panel-sub">⚡ Devre Kesici ve İşlemler</div>
                <div class="form-row">
                    <div class="form-group">
                        <label for="setBreakerPct">Devre kesici eşiği (%)</label>
                        <input type="number" id="setBreakerPct" step="0.5" min="1" value="${toPct(engine.breaker_pct)}">
                    </div>
                    <div class="form-group">
                        <label for="setBreakerMinutes">Durma süresi (dakika)</label>
                        <input type="number" id="setBreakerMinutes" step="1" min="1" value="${Number(engine.breaker_minutes)}">
                    </div>
                </div>
                <div class="form-row">
                    <div class="form-group">
                        <label for="setMaxImpact">Tek işlemde en fazla fiyat etkisi (%)</label>
                        <input type="number" id="setMaxImpact" step="0.5" min="0.5" value="${toPct(engine.max_trade_impact)}">
                    </div>
                    <div class="form-group">
                        <label for="setAssetSpread">Altın/döviz alış-satış farkı (%)</label>
                        <input type="number" id="setAssetSpread" step="0.1" min="0" value="${toPct(d.asset_spread)}">
                    </div>
                </div>

                <div class="panel-sub">📝 Sınav Bonusları</div>
                <div id="setTiers">${tierRows}</div>

                <button type="button" id="saveSettingsBtn" class="submit-btn" style="width:100%;">💾 Ayarları Kaydet</button>

                <div class="panel-sub">📝 Sınav Soruları</div>
                ${questions || '<p class="field-hint">Soru yok.</p>'}

                <div class="panel-sub">🧨 Oyunu Sıfırla</div>
                <p class="field-hint">Herkesin bakiyesi 100.000 ₺ olur; portföyler, altın/döviz, işlem geçmişi, sınav sonuçları, haberler, tüyolar ve grafik geçmişi silinir. Hisseler ve güncel fiyatları korunur. Geri alınamaz.</p>
                <button type="button" id="resetGameBtn" class="reset-btn" style="width:100%; margin:0;">🧨 Oyunu Sıfırla</button>
            `;

            $("saveSettingsBtn").addEventListener("click", () => this.save());
            $("resetGameBtn").addEventListener("click", () => this.resetGame());
            root.querySelectorAll('[data-q="save"]').forEach(btn => {
                btn.addEventListener("click", () => this.saveQuestion(btn.closest(".settings-question")));
            });
        },

        async save() {
            const root = $("adminSettingsBody");
            const num = (el) => Number(el && el.value);
            const types = [...root.querySelectorAll("tr[data-type]")].map(tr => {
                const f = (name) => num(tr.querySelector(`[data-f="${name}"]`));
                return {
                    risk_type: tr.dataset.type,
                    daily_sigma: fromPct(f("daily_sigma")),
                    shock_per_day: f("shock_per_day"),
                    shock_min: fromPct(f("shock_min")),
                    shock_max: fromPct(f("shock_max")),
                    impact_depth: f("impact") > 0 ? Math.round(REFERENCE_TRADE / (f("impact") / 100)) : 0,
                };
            });
            const tiers = [...root.querySelectorAll(".settings-tier")].map(row => ({
                min: Math.round(num(row.querySelector('[data-tier="min"]'))),
                bonus: num(row.querySelector('[data-tier="bonus"]')),
            })).sort((a, b) => a.min - b.min);

            const btn = $("saveSettingsBtn");
            btn.disabled = true;
            try {
                const { data, error } = await window.sb.rpc("admin_save_settings", {
                    p_settings: {
                        types,
                        engine: {
                            breaker_pct: fromPct($("setBreakerPct").value),
                            breaker_minutes: Math.round(num($("setBreakerMinutes"))),
                            max_trade_impact: fromPct($("setMaxImpact").value),
                            quiz_bonus_tiers: tiers,
                        },
                        asset_spread: fromPct($("setAssetSpread").value),
                    },
                });
                if (error) throw error;
                this._data = data;
                this.render();
                ok("Ayarlar kaydedildi.");
            } catch (err) {
                fail(err.message || "Ayarlar kaydedilemedi.");
            } finally {
                const b = $("saveSettingsBtn");
                if (b) b.disabled = false;
            }
        },

        async saveQuestion(box) {
            if (!box) return;
            const id = Number(box.dataset.qid);
            const question = box.querySelector('[data-q="question"]').value;
            const options = [...box.querySelectorAll('[data-q="option"]')].map(i => i.value.trim());
            const picked = box.querySelector(`input[name="settings-correct-${id}"]:checked`);
            try {
                const { error } = await window.sb.rpc("admin_save_quiz_question", {
                    p_id: id,
                    p_question: question,
                    p_options: options,
                    p_correct_index: picked ? Number(picked.value) : null,
                });
                if (error) throw error;
                box.querySelector("summary").textContent = question.trim();
                ok("Soru kaydedildi.");
            } catch (err) {
                fail(err.message || "Soru kaydedilemedi.");
            }
        },

        async resetGame() {
            const typed = prompt('Bu işlem geri alınamaz. Bütün oyuncuların bakiyesi, portföyü ve geçmişi sıfırlanacak.\n\nOnaylamak için SIFIRLA yazın:');
            if (typed === null) return;
            if (typed.trim().toUpperCase() !== "SIFIRLA") {
                fail("Onay metni eşleşmedi; hiçbir şey sıfırlanmadı.");
                return;
            }
            const btn = $("resetGameBtn");
            btn.disabled = true;
            try {
                const { data, error } = await window.sb.rpc("admin_reset_game");
                if (error) throw error;
                ok(`Oyun sıfırlandı: ${Number(data && data.users || 0)} oyuncu 100.000 ₺ ile baştan başlıyor.`);
                setTimeout(() => window.location.reload(), 1500);
            } catch (err) {
                fail(err.message || "Oyun sıfırlanamadı.");
                btn.disabled = false;
            }
        },

        wire() {
            const refresh = $("adminSettingsRefresh");
            if (refresh) refresh.addEventListener("click", () => this.load());
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (!uid || uid === this._loadedFor) return;
                this._loadedFor = uid;
                this.load();
            });
        },
    };

    window.AdminSettings = AdminSettings;
    document.addEventListener("DOMContentLoaded", () => AdminSettings.wire());
})();
