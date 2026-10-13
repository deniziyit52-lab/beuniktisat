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
                    <div class="form-group">
                        <label>Açıklama (öğrenci cevabı işaretleyince görür)</label>
                        <textarea rows="2" maxlength="600" data-q="explanation" placeholder="Doğru cevabın neden doğru olduğunu bir iki cümleyle anlat.">${esc(q.explanation || "")}</textarea>
                    </div>
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
                ${engine.daily_limit_pct == null ? "" : `
                <div class="form-group">
                    <label for="setDailyLimit">Günlük tavan / taban (%)</label>
                    <input type="number" id="setDailyLimit" step="1" min="5" max="100" value="${toPct(engine.daily_limit_pct)}">
                    <small class="field-hint">Bir hisse, günün açılış fiyatına göre bu yüzdeden fazla yükselemez ya da düşemez. %100 yazarsan sınır fiilen kalkar.</small>
                </div>`}
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

                ${engine.commission_rate == null ? "" : `
                <div class="form-group">
                    <label for="setCommission">Hisse alım-satım komisyonu (%)</label>
                    <input type="number" id="setCommission" step="0.05" min="0" max="${toPct(engine.legacy_commission_rate)}" value="${toPct(engine.commission_rate)}">
                    <small class="field-hint">Her alım ve satımda işlem tutarından kesilir. Gerçek borsada aracı kurumlar genellikle binde 2 (%0,2) dolayında alır. En fazla %${toPct(engine.legacy_commission_rate)} yazılabilir.</small>
                </div>`}

                ${engine.max_position_pct == null ? "" : `
                <div class="form-row">
                    <div class="form-group">
                        <label for="setMaxPosition">Tek hissede en fazla pay (%)</label>
                        <input type="number" id="setMaxPosition" step="1" min="5" max="100" value="${toPct(engine.max_position_pct)}">
                    </div>
                    <div class="form-group">
                        <label for="setRevertShare">İşlem etkisinin geri dönen kısmı (%)</label>
                        <input type="number" id="setRevertShare" step="5" min="0" max="100" value="${toPct(engine.impact_revert_share)}">
                    </div>
                </div>

                <div class="panel-sub">🛑 Piyasa Geneli Devre Kesici</div>
                <p class="field-hint">Hisselerin gün içindeki ortalama düşüşü bu yüzdelere ulaşınca bütün hisse işlemleri durur. Süre 0 ise piyasa gün sonuna kadar kapanır.</p>
                <div id="setMarketLevels">
                    ${(Array.isArray(engine.market_breaker_levels) ? engine.market_breaker_levels : []).map(l => `
                    <div class="form-row settings-level">
                        <div class="form-group">
                            <label>Ortalama düşüş (%)</label>
                            <input type="number" step="0.5" min="0.5" data-level="drop" value="${toPct(l.drop)}">
                        </div>
                        <div class="form-group">
                            <label>Durma süresi (dakika)</label>
                            <input type="number" step="1" min="0" data-level="minutes" value="${Number(l.minutes)}">
                        </div>
                    </div>`).join("")}
                </div>`}

                ${engine.real_market_enabled == null ? "" : `
                <div class="panel-sub">🌍 Gerçek Borsa Yönü</div>
                <div class="form-group">
                    <label class="checkrow" for="setRealMarket">
                        <input type="checkbox" id="setRealMarket" ${engine.real_market_enabled ? "checked" : ""}>
                        <span>Piyasanın genel yönü BIST 100'den gelsin</span>
                    </label>
                    <small class="field-hint">Açıkken, gerçek borsa çalıştığı saatlerde (hafta içi 10:00–18:00) hisselerin ortak yönü BIST 100'ün gerçek hareketini izler. Diğer saatlerde ve kapalıyken yön rastgeledir.</small>
                </div>
                <div class="form-group">
                    <label for="setRealMarketScale">Gerçek hareketin çarpanı</label>
                    <input type="number" id="setRealMarketScale" step="0.5" min="0" max="5" value="${Number(engine.real_market_scale)}">
                    <small class="field-hint">1 = olduğu gibi. 2 yazarsan BIST %1 oynadığında "Orta" hisseler ortak yönden yaklaşık %2 oynar.</small>
                </div>`}

                ${engine.stock_link_enabled == null ? "" : `
                <div class="panel-sub">🔗 Hisseler Gerçek Hisseleri İzlesin</div>
                <div class="form-group">
                    <label class="checkrow" for="setStockLinks">
                        <input type="checkbox" id="setStockLinks" ${engine.stock_link_enabled ? "checked" : ""}>
                        <span>Her hisse, bağlı olduğu gerçek hissenin hareketini izlesin</span>
                    </label>
                    <small class="field-hint">Açıkken gerçek borsa saatlerinde (hafta içi 10:00–18:00) fiyatı bağlı gerçek hisse oynatır, ani şoklar kapanır. Kapatırsan eski rastgele düzene döner.</small>
                </div>
                <div class="form-group">
                    <label for="setQuietVol">Rastgele kısmın payı (%)</label>
                    <input type="number" id="setQuietVol" step="5" min="0" max="100" value="${toPct(engine.quiet_vol_scale)}">
                    <small class="field-hint">Yukarıdaki tabloda yazan günlük oynaklığın yüzde kaçı rastgele kalsın. Akşam ve hafta sonu fiyatları bu kısım oynatır. Düşük tutarsan şans azalır.</small>
                </div>
                ${engine.link_pull_rate == null ? "" : `
                <div class="form-group">
                    <label for="setLinkPull">Gerçek fiyata geri çekme hızı (dakikada %)</label>
                    <input type="number" id="setLinkPull" step="1" min="0" max="50" value="${toPct(engine.link_pull_rate)}">
                    <small class="field-hint">Oyun fiyatı, büyük bir alım-satım ya da rastgele oynama yüzünden gerçek hissenin izinden uzaklaşırsa, aradaki fark her dakika bu oranda kapanır. %3 ile fark yaklaşık 25 dakikada yarıya iner. 0 yazarsan geri çekme olmaz, fark birikir.</small>
                </div>`}
                <div id="stockLinksList" class="mailing-list"><p class="field-hint">Eşleşmeler yükleniyor…</p></div>`}

                <div class="panel-sub">📝 Sınav Süresi ve Bonusları</div>
                ${engine.quiz_minutes == null ? "" : `
                <div class="form-group">
                    <label for="setQuizMinutes">Sınav süresi (dakika)</label>
                    <input type="number" id="setQuizMinutes" step="1" min="1" max="120" value="${Number(engine.quiz_minutes)}">
                </div>`}
                <div id="setTiers">${tierRows}</div>
                ${engine.daily_quiz_reward == null ? "" : `
                <div class="form-group">
                    <label for="setDailyReward">Günün soruları: doğru cevap başına ödül (₺)</label>
                    <input type="number" id="setDailyReward" step="10" min="0" max="10000" value="${Number(engine.daily_quiz_reward)}">
                    <small class="field-hint">Günde ${Number(engine.daily_quiz_size || 10)} soru sorulur. 0 yazarsan ödül verilmez, sorular yalnızca öğrenmek için çözülür.</small>
                </div>`}

                <button type="button" id="saveSettingsBtn" class="submit-btn" style="width:100%;">💾 Ayarları Kaydet</button>

                <div class="panel-sub">📝 Sınav Soruları</div>
                ${questions || '<p class="field-hint">Soru yok.</p>'}

                <div class="panel-sub">🧨 Oyunu Sıfırla</div>
                <p class="field-hint">Herkesin bakiyesi 100.000 ₺ olur; portföyler, altın/döviz, işlem geçmişi, sınav sonuçları, haberler, tüyolar ve grafik geçmişi silinir. Hisseler ve güncel fiyatları korunur. Geri alınamaz.</p>
                <button type="button" id="resetGameBtn" class="reset-btn" style="width:100%; margin:0;">🧨 Oyunu Sıfırla</button>
            `;

            $("saveSettingsBtn").addEventListener("click", () => this.save());
            this.loadStockLinks();
            $("resetGameBtn").addEventListener("click", () => this.resetGame());
            root.querySelectorAll('[data-q="save"]').forEach(btn => {
                btn.addEventListener("click", () => this.saveQuestion(btn.closest(".settings-question")));
            });
        },

        // Gizli eşleşme listesi (yalnızca yönetici görür) ve son veri okuma durumu.
        async loadStockLinks() {
            const box = $("stockLinksList");
            if (!box) return;
            const { data, error } = await window.sb.rpc("admin_list_stock_links");
            if (error || !data) {
                box.innerHTML = `<p class="field-hint">Eşleşmeler yüklenemedi: ${esc(error ? error.message : "boş cevap")}</p>`;
                return;
            }
            const st = data.status || {};
            const when = st.checked_at ? new Date(st.checked_at).toLocaleString("tr-TR") : "henüz okunmadı";
            box.innerHTML = `<p class="field-hint">🤫 Bu liste gizlidir; oyun bitince açıklanacak. Son okuma: ${esc(when)} — ${st.ok === false ? "⚠ " : ""}${esc(st.message || "")}</p>`
                + (Array.isArray(data.links) ? data.links : []).map(l => `
                <div class="column-admin-row">
                    <div class="column-admin-text">
                        <strong>${esc(l.symbol)} → ${esc(String(l.real || "").replace(/\.IS$/, ""))}</strong>
                        <span>${esc(l.sector)}${l.last_price ? " · gerçek fiyat " + Number(l.last_price).toLocaleString("tr-TR") + " ₺" : ""}</span>
                    </div>
                </div>`).join("");
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
                if ($("setDailyLimit")) {
                    const { error: limitError } = await window.sb.rpc("admin_set_daily_limit", {
                        p_limit: fromPct($("setDailyLimit").value),
                    });
                    if (limitError) throw limitError;
                }
                if ($("setCommission")) {
                    const { error: feeError } = await window.sb.rpc("admin_set_commission", {
                        p_rate: fromPct($("setCommission").value),
                    });
                    if (feeError) throw feeError;
                }
                if ($("setStockLinks")) {
                    const { error: linkError } = await window.sb.rpc("admin_set_stock_links", {
                        p_enabled: $("setStockLinks").checked,
                        p_quiet: fromPct($("setQuietVol").value),
                        ...($("setLinkPull") ? { p_pull: fromPct($("setLinkPull").value) } : {}),
                    });
                    if (linkError) throw linkError;
                }
                if ($("setRealMarket")) {
                    const { error: realError } = await window.sb.rpc("admin_set_real_market", {
                        p_enabled: $("setRealMarket").checked,
                        p_scale: num($("setRealMarketScale")),
                    });
                    if (realError) throw realError;
                }
                if ($("setDailyReward")) {
                    const { error: dailyError } = await window.sb.rpc("admin_set_daily_quiz_reward", {
                        p_reward: num($("setDailyReward")),
                    });
                    if (dailyError) throw dailyError;
                }
                if ($("setQuizMinutes")) {
                    const { error: minutesError } = await window.sb.rpc("admin_set_quiz_minutes", {
                        p_minutes: Math.round(num($("setQuizMinutes"))),
                    });
                    if (minutesError) throw minutesError;
                }
                if ($("setMaxPosition")) {
                    const { error: rulesError } = await window.sb.rpc("admin_save_market_rules", {
                        p_rules: {
                            max_position_pct: fromPct($("setMaxPosition").value),
                            impact_revert_share: fromPct($("setRevertShare").value),
                            market_breaker_levels: [...root.querySelectorAll(".settings-level")].map(row => ({
                                drop: fromPct(row.querySelector('[data-level="drop"]').value),
                                minutes: Math.round(num(row.querySelector('[data-level="minutes"]'))),
                            })),
                        },
                    });
                    if (rulesError) throw rulesError;
                }
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
                    p_explanation: (box.querySelector('[data-q="explanation"]') || {}).value || null,
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
