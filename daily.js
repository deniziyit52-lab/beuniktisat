/* Günün soruları: isteğe bağlı, günde bir kez. Sorular ve puanlama sunucuda
 * (get_daily_quiz / start_daily_quiz / answer_daily_question RPC'leri). */
(function () {
    const fmt = (n) => BorsaFirebase.formatTL(n);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML;
    };

    const BorsaDaily = {
        _uid: null,
        _state: null,       // get_daily_quiz cevabı
        _modal: null,
        _answering: false,

        _banner() { return document.getElementById("dailyBanner"); },

        // Giriş yapan kullanıcı için günün durumunu sorar ve kutuyu günceller.
        async refresh() {
            const banner = this._banner();
            const user = BorsaFirebase.currentUser ? BorsaFirebase.currentUser() : null;
            if (!user || !window.sb || !window.sb.rpc) {
                this._state = null;
                if (banner) banner.style.display = "none";
                return;
            }
            const { data, error } = await window.sb.rpc("get_daily_quiz");
            if (error || !data) {
                // Özellik veritabanında henüz yoksa kutu hiç gösterilmez.
                if (banner) banner.style.display = "none";
                return;
            }
            this._state = data;
            this.renderBanner();
        },

        _streakText() {
            const streak = Number(this._state && this._state.streak || 0);
            return streak > 0 ? ` · 🔥 ${streak} günlük seri` : "";
        },

        renderBanner() {
            const banner = this._banner();
            const s = this._state;
            if (!banner || !s) return;
            const title = banner.querySelector("[data-daily='title']");
            const text = banner.querySelector("[data-daily='text']");
            const button = banner.querySelector("[data-daily='open']");
            const size = Number(s.size || 10);
            const reward = Number(s.reward_per_correct || 0);
            const answered = (s.questions || []).filter(q => q.chosen !== undefined).length;
            banner.classList.toggle("is-done", s.status === "done");
            if (s.status === "done") {
                title.textContent = `✅ Bugünün sorularını çözdün: ${Number(s.correct_count)} / ${size}`;
                text.textContent = `${Number(s.reward) > 0 ? `+${fmt(Number(s.reward))} kazandın` : "Bugün ödül çıkmadı"}${this._streakText()} · Yarın yeni sorular gelir.`;
                button.textContent = "Cevaplara Bak";
            } else if (s.status === "started") {
                title.textContent = `🧠 Günün soruları yarım kaldı (${answered} / ${size})`;
                text.textContent = `Kaldığın yerden devam et${this._streakText()}.`;
                button.textContent = "Devam Et";
            } else {
                title.textContent = `🧠 Günün ${size} sorusu hazır`;
                text.textContent = `${reward > 0 ? `Her doğru cevap +${fmt(reward)} kazandırır. ` : ""}İstersen çöz, her sorunun açıklamasını anında gör${this._streakText()}.`;
                button.textContent = "Soruları Çöz";
            }
            banner.style.display = "flex";
        },

        async open() {
            if (!this._state) return;
            if (this._state.status === "new") {
                const { data, error } = await window.sb.rpc("start_daily_quiz");
                if (error || !data) {
                    alert((error && error.message) || "Sorular açılamadı. Tekrar dene.");
                    return;
                }
                this._state = data;
                this.renderBanner();
            }
            this.renderModal();
        },

        _questionMarkup(q, index) {
            const answered = q.chosen !== undefined;
            const options = (q.options || []).map((opt, j) => {
                let cls = "quiz-option";
                let mark = "";
                if (answered) {
                    if (j === Number(q.correct_index)) { cls += " is-correct"; mark = "✅"; }
                    else if (j === Number(q.chosen)) { cls += " is-wrong"; mark = "❌"; }
                    else cls += " is-dim";
                }
                return `<button type="button" class="${cls}" data-qid="${q.id}" data-choice="${j}" ${answered ? "disabled" : ""}>
                            <span>${esc(opt)}</span>${mark ? `<span class="quiz-option-mark" aria-hidden="true">${mark}</span>` : ""}
                        </button>`;
            }).join("");
            let feedback = "";
            if (answered) {
                const ok = Number(q.chosen) === Number(q.correct_index);
                feedback = `<div class="quiz-feedback ${ok ? "is-correct" : "is-wrong"}" role="status">
                        <strong>${ok ? "✅ Doğru!" : "❌ Yanlış."}</strong>
                        ${ok ? "" : `<span>Doğru cevap: <b>${esc((q.options || [])[Number(q.correct_index)])}</b></span>`}
                        ${q.explanation ? `<p>💡 ${esc(q.explanation)}</p>` : ""}
                    </div>`;
            }
            return `<div class="quiz-question ${answered ? "is-answered" : ""}" data-question="${q.id}">
                        <div class="quiz-question-title">${index + 1}. ${esc(q.question)}</div>
                        <div class="quiz-options">${options}</div>
                        ${feedback}
                    </div>`;
        },

        _progressText() {
            const s = this._state;
            const questions = s.questions || [];
            const answered = questions.filter(q => q.chosen !== undefined).length;
            const correct = questions.filter(q => q.chosen !== undefined && Number(q.chosen) === Number(q.correct_index)).length;
            const reward = Number(s.reward || 0);
            return `Doğru: ${correct} · Yanlış: ${answered - correct} · Kalan: ${questions.length - answered}${reward > 0 ? ` · Kazanılan: ${fmt(reward)}` : ""}`;
        },

        renderModal() {
            this.close();
            const s = this._state;
            const questions = s.questions || [];
            const modal = document.createElement("div");
            modal.className = "modal-backdrop quiz-backdrop";
            modal.style.display = "flex";
            modal.innerHTML = `<div class="modal-card quiz-modal" role="dialog" aria-modal="true" aria-labelledby="dailyTitle">
                <button type="button" class="modal-close" data-daily="close" aria-label="Kapat">×</button>
                <h2 id="dailyTitle" class="quiz-title">🧠 Günün Soruları</h2>
                <div class="quiz-progress" aria-live="polite">${this._progressText()}</div>
                <div class="daily-summary" ${s.status === "done" ? "" : 'style="display:none;"'}></div>
                <div class="quiz-body">${questions.map((q, i) => this._questionMarkup(q, i)).join("")}</div>
                <div class="quiz-error" role="alert"></div>
                <div class="quiz-actions">
                    <button type="button" class="submit-btn" data-daily="close">Kapat</button>
                </div>
            </div>`;
            document.body.appendChild(modal);
            this._modal = modal;
            this._renderSummary();
            modal.querySelectorAll("[data-daily='close']").forEach(b => b.addEventListener("click", () => this.close()));
            modal.addEventListener("click", (e) => { if (e.target === modal) this.close(); });
            modal.querySelector(".quiz-body").addEventListener("click", (e) => {
                const button = e.target.closest("[data-choice]");
                if (button && !button.disabled) this.answer(Number(button.dataset.qid), Number(button.dataset.choice));
            });
        },

        _renderSummary() {
            const el = this._modal && this._modal.querySelector(".daily-summary");
            const s = this._state;
            if (!el || !s || s.status !== "done") return;
            const size = (s.questions || []).length;
            el.style.display = "block";
            el.innerHTML = `<strong>Bugünlük bu kadar: ${Number(s.correct_count)} / ${size} doğru.</strong>
                <span>${Number(s.reward) > 0 ? `Bakiyene ${fmt(Number(s.reward))} eklendi. ` : ""}${Number(s.streak) > 0 ? `🔥 ${Number(s.streak)} gündür üst üste çözüyorsun. ` : ""}Yarın yeni sorularla görüşürüz.</span>`;
        },

        close() {
            if (this._modal) { this._modal.remove(); this._modal = null; }
        },

        async answer(qid, choice) {
            if (this._answering || !this._modal) return;
            const s = this._state;
            const index = (s.questions || []).findIndex(q => Number(q.id) === qid);
            if (index < 0 || s.questions[index].chosen !== undefined) return;
            const modal = this._modal;
            const errorEl = modal.querySelector(".quiz-error");
            errorEl.textContent = "";
            this._answering = true;
            try {
                const { data, error } = await window.sb.rpc("answer_daily_question", {
                    p_question_id: qid,
                    p_choice: choice,
                });
                if (error) throw error;
                const q = s.questions[index];
                q.chosen = Number(data.chosen);
                q.correct_index = Number(data.correct_index);
                q.explanation = data.explanation || "";
                s.correct_count = Number(data.correct_count);
                s.reward = Number(data.reward);
                if (data.done) {
                    s.status = "done";
                    // Seri sayısı sunucudan yeniden okunur.
                    this.refresh().then(() => this._renderSummary());
                } else {
                    s.status = "started";
                }
                // Ödül bakiyeye anında yansır.
                const doc = BorsaFirebase.currentUserData ? BorsaFirebase.currentUserData() : null;
                if (doc && data.balance != null) {
                    doc.balance = Number(data.balance);
                    if (typeof BorsaFirebase._emit === "function") BorsaFirebase._emit();
                }
                if (this._modal === modal) {
                    const node = modal.querySelector(`[data-question="${qid}"]`);
                    if (node) node.outerHTML = this._questionMarkup(q, index);
                    modal.querySelector(".quiz-progress").textContent = this._progressText();
                    this._renderSummary();
                }
                this.renderBanner();
            } catch (err) {
                errorEl.textContent = (err && err.message) || "Cevap kaydedilemedi. Tekrar dene.";
            } finally {
                this._answering = false;
            }
        },

        wire() {
            const banner = this._banner();
            if (!banner) return;
            banner.querySelector("[data-daily='open']").addEventListener("click", () => this.open());
            BorsaFirebase.onChange((user) => {
                const uid = user ? user.id : null;
                if (uid === this._uid) return;
                this._uid = uid;
                this.refresh();
            });
            // Sekme gece yarısından sonra açık kaldıysa yeni günün soruları için durum yenilenir.
            document.addEventListener("visibilitychange", () => {
                if (!document.hidden && this._uid && !this._modal) this.refresh();
            });
        },
    };

    window.BorsaDaily = BorsaDaily;
    document.addEventListener("DOMContentLoaded", () => BorsaDaily.wire());
})();
