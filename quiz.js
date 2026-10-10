/* Açılış sınavı: tek seferlik, isteğe bağlı. Sorular get_quiz, puanlama submit_quiz RPC'si ile sunucuda yapılır. */
(function () {
    const DISMISS_KEY = "borsa_quiz_dismissed";
    const fmt = (n) => BorsaFirebase.formatTL(n);
    const esc = (s) => {
        const d = document.createElement("div");
        d.textContent = String(s == null ? "" : s);
        return d.innerHTML;
    };

    const BorsaQuiz = {
        _uid: null,
        _questions: [],
        _tiers: [],
        _modal: null,
        _busy: false,
        _minutes: 0,      // 0: süre yok (sunucu süre bildirmediyse)
        _deadline: 0,     // sınav başladıysa bitiş anı (ms)
        _timer: null,

        _button() { return document.getElementById("quizBtn"); },

        _showButton(show) {
            const banner = document.getElementById("quizBanner");
            if (banner) banner.style.display = show ? "flex" : "none";
        },

        // Giriş yapan kullanıcı için sınav durumunu bir kez sorar.
        async check(user) {
            const uid = user ? user.id : null;
            if (uid === this._uid) return;
            this._uid = uid;
            this._questions = [];
            this._showButton(false);
            if (!uid || !window.sb || !window.sb.rpc) return;
            const { data, error } = await window.sb.rpc("get_quiz");
            if (error || !data || uid !== this._uid) return;
            if (data.taken) return;
            this._questions = Array.isArray(data.questions) ? data.questions : [];
            this._tiers = (Array.isArray(data.tiers) ? data.tiers : [])
                .map(t => ({ min: Number(t.min), bonus: Number(t.bonus) }))
                .sort((a, b) => a.min - b.min);
            if (!this._questions.length) return;
            this._minutes = Number(data.minutes) || 0;
            this._deadline = 0;
            // Anında geri bildirim: sunucu destekliyorsa her soru işaretlendiği an sonucu gösterilir.
            this._instant = data.instant_feedback === true;
            this._answers = {};
            this._reveals = {};
            (Array.isArray(data.answered) ? data.answered : []).forEach(a => {
                this._answers[a.id] = Number(a.chosen);
                this._reveals[a.id] = { correct_index: Number(a.correct_index), explanation: a.explanation || "" };
            });
            this._showButton(true);
            // Süre daha önce başladıysa kaldığı yerden devam eder.
            if (data.started && this._minutes > 0) {
                this._deadline = Date.now() + Number(data.seconds_left || 0) * 1000;
                this.openQuestions();
                return;
            }
            let dismissed = false;
            try { dismissed = sessionStorage.getItem(DISMISS_KEY) === uid; } catch (_) {}
            if (!dismissed) this.openIntro();
        },

        _open(html) {
            this.close(true);
            const modal = document.createElement("div");
            modal.className = "modal-backdrop quiz-backdrop";
            modal.style.display = "flex";
            modal.innerHTML = `<div class="modal-card quiz-modal" role="dialog" aria-modal="true">${html}</div>`;
            document.body.appendChild(modal);
            this._modal = modal;
            return modal;
        },

        _stopTimer() {
            if (this._timer) { clearInterval(this._timer); this._timer = null; }
        },

        close(silent) {
            if (this._busy) return;
            this._stopTimer();
            if (this._modal) { this._modal.remove(); this._modal = null; }
            if (!silent && this._uid) {
                try { sessionStorage.setItem(DISMISS_KEY, this._uid); } catch (_) {}
            }
        },

        openIntro() {
            const modal = this._open(`
                <h2 class="quiz-title">📝 Açılış Sınavı</h2>
                <p class="quiz-text">${this._questions.length} soruluk kısa bir iktisat sınavı. Sonucuna göre başlangıç bakiyene bonus eklenir:</p>
                <ul class="quiz-tiers">
                    ${this._tiers.map((t, i) => {
                        const upTo = i + 1 < this._tiers.length ? this._tiers[i + 1].min - 1 : this._questions.length;
                        return `<li><b>${t.min}–${upTo} doğru</b> → +${fmt(t.bonus)}</li>`;
                    }).join("")}
                </ul>
                ${this._minutes > 0 ? `<p class="quiz-text">⏱ Süre: <b>${this._minutes} dakika</b>. "Şimdi Çöz"e basınca süre başlar ve durmaz; sayfayı kapatsan da işlemeye devam eder. Süre bitince işaretlediklerin kendiliğinden gönderilir.</p>` : ""}
                ${this._instant ? `<p class="quiz-text">💡 Her soruyu işaretlediğin an doğru mu yanlış mı olduğunu ve kısa açıklamasını görürsün. İşaretlediğin cevap değiştirilemez, o yüzden düşünerek seç.</p>` : ""}
                <p class="quiz-text quiz-muted">Sınav yalnızca bir kez çözülebilir. Şimdi çözmek istemezsen sayfanın üstündeki sınav kutusundan daha sonra başlayabilirsin.</p>
                <div class="quiz-actions">
                    <button type="button" class="btn btn--ghost" data-quiz="later">Sonra</button>
                    <button type="button" class="submit-btn" data-quiz="start">Şimdi Çöz</button>
                </div>`);
            modal.querySelector('[data-quiz="later"]').addEventListener("click", () => this.close());
            modal.querySelector('[data-quiz="start"]').addEventListener("click", () => this.start());
        },

        // Süreyi sunucuda başlatır, sonra soruları açar.
        async start() {
            if (this._busy) return;
            if (this._minutes > 0 && !this._deadline) {
                this._busy = true;
                const { data, error } = await window.sb.rpc("start_quiz");
                this._busy = false;
                if (error) {
                    alert(error.message || "Sınav başlatılamadı. Tekrar deneyin.");
                    return;
                }
                this._deadline = Date.now() + Number(data && data.seconds_left || 0) * 1000;
            }
            this.openQuestions();
        },

        _tick() {
            const el = this._modal && this._modal.querySelector(".quiz-timer");
            const left = Math.max(0, Math.ceil((this._deadline - Date.now()) / 1000));
            if (el) {
                el.textContent = `⏱ ${String(Math.floor(left / 60)).padStart(2, "0")}:${String(left % 60).padStart(2, "0")}`;
                el.classList.toggle("is-low", left <= 60);
            }
            if (left <= 0) {
                this._stopTimer();
                this.submit();
            }
        },

        // Tek bir sorunun gövdesi: işaretlenmişse doğru/yanlış renkleri ve açıklamasıyla çizilir.
        _questionMarkup(q, index) {
            const chosen = this._answers[q.id];
            const reveal = this._reveals[q.id];
            const answered = chosen !== undefined;
            const options = (q.options || []).map((opt, j) => {
                let cls = "quiz-option";
                let mark = "";
                if (answered && reveal) {
                    if (j === reveal.correct_index) { cls += " is-correct"; mark = "✅"; }
                    else if (j === chosen) { cls += " is-wrong"; mark = "❌"; }
                    else cls += " is-dim";
                } else if (answered && j === chosen) {
                    cls += " is-picked";
                }
                return `<button type="button" class="${cls}" data-qid="${q.id}" data-choice="${j}" ${answered ? "disabled" : ""}>
                            <span>${esc(opt)}</span>${mark ? `<span class="quiz-option-mark" aria-hidden="true">${mark}</span>` : ""}
                        </button>`;
            }).join("");
            let feedback = "";
            if (answered && reveal) {
                const ok = chosen === reveal.correct_index;
                feedback = `<div class="quiz-feedback ${ok ? "is-correct" : "is-wrong"}" role="status">
                        <strong>${ok ? "✅ Doğru!" : "❌ Yanlış."}</strong>
                        ${ok ? "" : `<span>Doğru cevap: <b>${esc((q.options || [])[reveal.correct_index])}</b></span>`}
                        ${reveal.explanation ? `<p>💡 ${esc(reveal.explanation)}</p>` : ""}
                    </div>`;
            }
            return `<div class="quiz-question ${answered ? "is-answered" : ""}" data-question="${q.id}">
                        <div class="quiz-question-title">${index + 1}. ${esc(q.question)}</div>
                        <div class="quiz-options">${options}</div>
                        ${feedback}
                    </div>`;
        },

        _progressText() {
            const total = this._questions.length;
            const answered = this._questions.filter(q => this._answers[q.id] !== undefined).length;
            if (!this._instant) return `${answered} / ${total} soru işaretlendi`;
            const correct = this._questions.filter(q =>
                this._reveals[q.id] && this._answers[q.id] === this._reveals[q.id].correct_index).length;
            return `Doğru: ${correct} · Yanlış: ${answered - correct} · Kalan: ${total - answered}`;
        },

        _refreshProgress() {
            const el = this._modal && this._modal.querySelector(".quiz-progress");
            if (el) el.textContent = this._progressText();
        },

        openQuestions() {
            const timed = this._deadline > 0;
            const body = this._questions.map((q, i) => this._questionMarkup(q, i)).join("");
            const modal = this._open(`
                <h2 class="quiz-title">📝 Açılış Sınavı${timed ? ' <span class="quiz-timer" aria-live="off"></span>' : ""}</h2>
                <div class="quiz-progress" aria-live="polite">${this._progressText()}</div>
                <div class="quiz-body">${body}</div>
                <div class="quiz-error" role="alert"></div>
                <div class="quiz-actions">
                    ${timed ? "" : '<button type="button" class="btn btn--ghost" data-quiz="later">Sonra</button>'}
                    <button type="button" class="submit-btn" data-quiz="submit">Sınavı Bitir</button>
                </div>`);
            const later = modal.querySelector('[data-quiz="later"]');
            if (later) later.addEventListener("click", () => this.close());
            modal.querySelector('[data-quiz="submit"]').addEventListener("click", () => this.submit());
            // Şıklara tıklama: tek dinleyici, soru yeniden çizilse de çalışır.
            modal.querySelector(".quiz-body").addEventListener("click", (e) => {
                const button = e.target.closest("[data-choice]");
                if (button && !button.disabled) this.answer(Number(button.dataset.qid), Number(button.dataset.choice));
            });
            if (timed) {
                this._tick();
                if (this._modal === modal && this._deadline > Date.now()) {
                    this._timer = setInterval(() => this._tick(), 1000);
                }
            }
        },

        // Bir şık işaretlendi: cevap sunucuda kilitlenir, sonucu ve açıklaması hemen gösterilir.
        async answer(qid, choice) {
            if (this._answers[qid] !== undefined || this._answering) return;
            const modal = this._modal;
            if (!modal) return;
            const errorEl = modal.querySelector(".quiz-error");
            if (errorEl) errorEl.textContent = "";
            const redraw = () => {
                const index = this._questions.findIndex(q => q.id === qid);
                const node = modal.querySelector(`[data-question="${qid}"]`);
                if (index >= 0 && node) node.outerHTML = this._questionMarkup(this._questions[index], index);
                this._refreshProgress();
            };
            if (!this._instant) {
                this._answers[qid] = choice;
                redraw();
                return;
            }
            this._answering = true;
            try {
                const { data, error } = await window.sb.rpc("answer_quiz_question", {
                    p_question_id: qid,
                    p_choice: choice,
                });
                if (error) throw error;
                this._answers[qid] = Number(data.chosen);
                this._reveals[qid] = {
                    correct_index: Number(data.correct_index),
                    explanation: data.explanation || "",
                };
                if (this._modal === modal) redraw();
            } catch (err) {
                if (errorEl) errorEl.textContent = (err && err.message) || "Cevap kaydedilemedi. Tekrar dene.";
            } finally {
                this._answering = false;
            }
        },

        async submit() {
            if (this._busy || !this._modal) return;
            const modal = this._modal;
            const errorEl = modal.querySelector(".quiz-error");
            const answers = {};
            let missing = 0;
            this._questions.forEach(q => {
                if (this._answers[q.id] !== undefined) answers[q.id] = this._answers[q.id];
                else missing++;
            });
            const expired = this._deadline > 0 && Date.now() >= this._deadline;
            if (missing > 0 && !expired) {
                errorEl.textContent = `${missing} soru boş. Bitirmeden önce hepsini işaretle; sınav tek seferlik.`;
                return;
            }
            this._busy = true;
            errorEl.textContent = "Sonuç hesaplanıyor…";
            const { data, error } = await window.sb.rpc("submit_quiz", { p_answers: answers });
            this._busy = false;
            if (!error && data) { this._stopTimer(); this._deadline = 0; }
            if (error || !data) {
                errorEl.textContent = (error && error.message) || "Sınav gönderilemedi. Tekrar deneyin.";
                return;
            }
            this._showButton(false);
            this.openResult(data, answers);
            try { if (BorsaFirebase.refreshUserDoc) await BorsaFirebase.refreshUserDoc(); } catch (_) {}
            if (typeof window.invalidateSidebarCaches === "function") window.invalidateSidebarCaches();
            if (window.BorsaBadges) window.BorsaBadges.scheduleCheck(1500);
        },

        // Sonuç ekranı: her soru için verilen cevap, doğru cevap ve açıklama.
        openResult(result, answers) {
            const byId = {};
            (result.review || []).forEach(r => { byId[r.id] = r; });
            const body = this._questions.map((q, i) => {
                const r = byId[q.id] || {};
                const correct = Number(r.correct_index);
                const chosen = (r.chosen === null || r.chosen === undefined) ? answers[q.id] : Number(r.chosen);
                const blank = chosen === undefined || chosen === null;
                const ok = !blank && chosen === correct;
                return `<div class="quiz-review ${ok ? "ok" : "wrong"}">
                    <div class="quiz-review-q">${ok ? "✅" : "❌"} ${i + 1}. ${esc(q.question)}</div>
                    ${ok ? "" : `<div class="quiz-review-a">Senin cevabın: ${blank ? "boş" : esc((q.options || [])[chosen])}</div>`}
                    <div class="quiz-review-a">Doğru cevap: <b>${esc((q.options || [])[correct])}</b></div>
                    ${r.explanation ? `<div class="quiz-review-why">💡 ${esc(r.explanation)}</div>` : ""}
                </div>`;
            }).join("");
            const bonus = Number(result.bonus || 0);
            const missingCount = this._questions.filter(q => answers[q.id] === undefined).length;
            const modal = this._open(`
                <h2 class="quiz-title">🎉 Sonuç: ${Number(result.score)} / ${Number(result.total)}</h2>
                ${missingCount > 0 ? `<p class="quiz-text">⏰ Süre doldu; ${missingCount} soru boş kaldı.</p>` : ""}
                <p class="quiz-text">${bonus > 0
                    ? `Tebrikler, <b>+${fmt(bonus)}</b> bonus kazandın. Yeni bakiyen <b>${fmt(Number(result.balance || 0))}</b>.`
                    : `Bu sefer bonus çıkmadı; ${fmt(Number(result.balance || 0))} ile oyuna devam ediyorsun.`}</p>
                <p class="quiz-text quiz-muted">Aşağıda her sorunun doğru cevabı ve kısa açıklaması var.</p>
                <div class="quiz-body">${body}</div>
                <div class="quiz-actions">
                    <button type="button" class="submit-btn" data-quiz="done">Oyuna Dön</button>
                </div>`);
            this._questions = [];
            modal.querySelector('[data-quiz="done"]').addEventListener("click", () => this.close(true));
        },

        wire() {
            const btn = this._button();
            if (btn) btn.addEventListener("click", () => { if (!this._questions.length) return;
                if (this._deadline > 0) this.openQuestions(); else this.openIntro();
            });
            BorsaFirebase.onChange((user) => { this.check(user).catch(() => {}); });
        },
    };

    window.BorsaQuiz = BorsaQuiz;
    document.addEventListener("DOMContentLoaded", () => BorsaQuiz.wire());
})();
