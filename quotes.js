/* Gazetedeki "Günün Sözü": hayatta olmayan iktisatçı ve yatırımcıların kaynağı bilinen sözleri.
   Çeviriler özgün metinden Türkçeye aktarılmıştır. Yaşayan kişilerden söz eklenmez; kaynağı
   gösterilemeyen "internet sözleri" listeye alınmaz. Her gün bir söz gösterilir. */
(function () {
    const QUOTES = [
        { a: "Adam Smith", y: "1723–1790", q: "Akşam yemeğimizi kasabın, biracının ya da fırıncının iyilikseverliğinden değil, kendi çıkarlarını gözetmelerinden bekleriz.", s: "Milletlerin Zenginliği, 1776" },
        { a: "Adam Smith", y: "1723–1790", q: "Tüketim, bütün üretimin tek amacı ve hedefidir.", s: "Milletlerin Zenginliği, 1776" },
        { a: "İbn Haldun", y: "1332–1406", q: "Devletin başlangıcında düşük oranlı vergiler büyük gelir getirir; sonunda yüksek oranlı vergiler küçük gelir getirir.", s: "Mukaddime, 1377" },
        { a: "Frédéric Bastiat", y: "1801–1850", q: "Kötü iktisatçı yalnızca görünen etkiye bakar; iyi iktisatçı hem görüneni hem de öngörülmesi gerekeni hesaba katar.", s: "Görünen ve Görünmeyen, 1850" },
        { a: "Alfred Marshall", y: "1842–1924", q: "İktisat, insanı hayatın olağan işleri içinde inceleyen bilimdir.", s: "İktisadın İlkeleri, 1890" },
        { a: "John Maynard Keynes", y: "1883–1946", q: "Uzun vadede hepimiz ölüyüz.", s: "Para Reformu Üzerine, 1923" },
        { a: "John Maynard Keynes", y: "1883–1946", q: "Spekülatörler, düzenli akan bir girişim ırmağının üstündeki köpükler olarak zarar vermeyebilir. Ama girişim, bir spekülasyon girdabının üstündeki köpüğe dönüştüğünde durum ciddidir.", s: "Genel Teori, 1936" },
        { a: "John Maynard Keynes", y: "1883–1946", q: "Dünya bilgeliği şunu öğretir: itibar için, alışılmış yoldan başarısız olmak, alışılmadık yoldan başarılı olmaktan iyidir.", s: "Genel Teori, 1936" },
        { a: "Irving Fisher", y: "1867–1947", q: "Hisse fiyatları kalıcı görünen yüksek bir platoya ulaştı.", s: "Ekim 1929", n: "Büyük çöküşten günler önce söyledi." },
        { a: "Joseph Schumpeter", y: "1883–1950", q: "Yaratıcı yıkım süreci, kapitalizmin temel gerçeğidir.", s: "Kapitalizm, Sosyalizm ve Demokrasi, 1942" },
        { a: "Benjamin Graham", y: "1894–1976", q: "Yatırımcının asıl sorunu, hatta en büyük düşmanı, büyük olasılıkla kendisidir.", s: "Akıllı Yatırımcı, 1949" },
        { a: "Benjamin Graham", y: "1894–1976", q: "Sağlam yatırımın sırrını üç kelimeye indirmemiz gerekse, şunu söylerdik: güvenlik payı.", s: "Akıllı Yatırımcı, 1949" },
        { a: "Joan Robinson", y: "1903–1983", q: "İktisat okumanın amacı hazır cevaplar edinmek değil, iktisatçılara aldanmamayı öğrenmektir.", s: "" },
        { a: "Milton Friedman", y: "1912–2006", q: "Enflasyon her zaman ve her yerde parasal bir olgudur.", s: "1963" },
        { a: "Paul Samuelson", y: "1915–2009", q: "Borsa, son beş durgunluğun dokuzunu önceden haber verdi.", s: "Newsweek, 1966" },
        { a: "Friedrich Hayek", y: "1899–1992", q: "İktisadın ilginç görevi, insanlara tasarlayabileceklerini sandıkları şey hakkında aslında ne kadar az bildiklerini göstermektir.", s: "Ölümcül Kibir, 1988" },
        { a: "John Kenneth Galbraith", y: "1908–2006", q: "Finansal hafıza son derece kısadır.", s: "Finansal Coşkunun Kısa Tarihi, 1990" },
        { a: "John Bogle", y: "1929–2019", q: "Samanlıkta iğne arama. Samanlığın tamamını al.", s: "2007" },
        { a: "Daniel Kahneman ve Amos Tversky", y: "", q: "Kayıplar, kazançlardan daha ağır basar.", s: "Beklenti Teorisi, 1979" },
        { a: "Mustafa Kemal Atatürk", y: "1881–1938", q: "Siyasi ve askerî zaferler ne kadar büyük olursa olsun, iktisadi zaferlerle taçlandırılmazsa kalıcı olmaz, az zamanda söner.", s: "İzmir İktisat Kongresi, 1923" },
        { a: "Benjamin Franklin", y: "1706–1790", q: "Unutma, vakit nakittir.", s: "Genç Bir Tüccara Öğütler, 1748" },
        { a: "Adam Smith", y: "1723–1790", q: "Her şeyin gerçek fiyatı, onu elde etmenin zahmeti ve sıkıntısıdır.", s: "Milletlerin Zenginliği, 1776" },
        { a: "Adam Smith", y: "1723–1790", q: "Kişi yalnızca kendi kazancını düşünür; ama görünmez bir el onu, niyetinde hiç olmayan bir amaca hizmet etmeye yöneltir.", s: "Milletlerin Zenginliği, 1776" },
        { a: "Adam Smith", y: "1723–1790", q: "Aynı işi yapanlar eğlenmek için bile bir araya gelseler, sohbet çoğu zaman fiyatları yükseltmenin bir yolunu bulmakla biter.", s: "Milletlerin Zenginliği, 1776" },
        { a: "Thomas Malthus", y: "1766–1834", q: "Nüfus, engellenmezse geometrik oranla artar; geçim araçları ise ancak aritmetik oranla.", s: "Nüfus Üzerine Deneme, 1798" },
        { a: "Walter Bagehot", y: "1826–1877", q: "Para kendi kendini yönetmez.", s: "Lombard Street, 1873" },
        { a: "Alfred Marshall", y: "1842–1924", q: "Değeri fayda mı belirler maliyet mi diye tartışmak, kâğıdı makasın üst ağzı mı keser alt ağzı mı diye tartışmaya benzer.", s: "İktisadın İlkeleri, 1890" },
        { a: "Thorstein Veblen", y: "1857–1929", q: "Değerli malların gösterişçi tüketimi, aylak sınıf için saygınlık kazanmanın bir yoludur.", s: "Aylak Sınıfın Teorisi, 1899" },
        { a: "Edwin Lefèvre", y: "1871–1943", q: "Borsada yeni hiçbir şey yoktur. Bugün olan her şey daha önce de olmuştur ve yine olacaktır.", s: "Bir Borsa Spekülatörünün Anıları, 1923" },
        { a: "Lionel Robbins", y: "1898–1984", q: "İktisat, insan davranışını, amaçlar ile alternatif kullanımı olan kıt araçlar arasındaki ilişki olarak inceleyen bilimdir.", s: "1932" },
        { a: "John Maynard Keynes", y: "1883–1946", q: "Zorluk yeni fikirlerde değil, eskilerinden kurtulmaktadır.", s: "Genel Teori, 1936" },
        { a: "John Maynard Keynes", y: "1883–1946", q: "Kendini her türlü düşünsel etkiden uzak sanan iş adamları, çoğu zaman ölmüş bir iktisatçının kölesidir.", s: "Genel Teori, 1936" },
        { a: "John Maynard Keynes", y: "1883–1946", q: "Olumlu bir şey yapma kararlarımızın çoğu, hesabın değil, içimizdeki harekete geçme dürtüsünün sonucudur.", s: "Genel Teori, 1936" },
        { a: "Benjamin Graham", y: "1894–1976", q: "Fiyat dalgalanmalarının gerçek yatırımcı için tek anlamı vardır: fiyat sert düştüğünde akıllıca almak, çok yükseldiğinde akıllıca satmak için fırsat.", s: "Akıllı Yatırımcı, 1949" },
        { a: "Harry Markowitz", y: "1927–2023", q: "İyi bir portföy, iyi hisselerin uzun bir listesinden fazlasıdır; dengeli bir bütündür.", s: "Portföy Seçimi, 1959" },
        { a: "Herbert Simon", y: "1916–2001", q: "Bilgi bolluğu, dikkat yoksulluğu yaratır.", s: "1971" },
        { a: "Milton Friedman", y: "1912–2006", q: "Politikaları sonuçlarına göre değil niyetlerine göre yargılamak büyük hatalardan biridir.", s: "1975" },
        { a: "Charles Kindleberger", y: "1910–2003", q: "İnsanın huzurunu ve sağduyusunu, bir arkadaşının zenginleştiğini görmek kadar bozan bir şey yoktur.", s: "Cinnet, Panik ve Çöküş, 1978" },
        { a: "James Tobin", y: "1918–2002", q: "Yumurtalarını tek sepete koyma.", s: "1981" },
        { a: "John Kenneth Galbraith", y: "1908–2006", q: "Finans dünyası tekerleği tekrar tekrar icat eder, çoğu zaman biraz daha dengesiz bir sürümüyle.", s: "Finansal Coşkunun Kısa Tarihi, 1990" },
        { a: "Daniel Kahneman", y: "1934–2024", q: "Hayatta hiçbir şey, üzerine düşünürken sandığın kadar önemli değildir.", s: "Hızlı ve Yavaş Düşünme, 2011" },
    ];

    const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

    window.BorsaQuotes = {
        list: QUOTES,
        _offset: 0,

        // Günün sözü: Türkiye saatine göre her gün bir sonraki söz.
        _todayIndex() {
            const day = Math.floor((Date.now() + 3 * 3600 * 1000) / 86400000);
            return ((day % QUOTES.length) + QUOTES.length) % QUOTES.length;
        },

        _initials(name) {
            const parts = String(name).split(/\s+/).filter((p) => p && p !== "ve");
            return ((parts[0] || "").charAt(0) + (parts.length > 1 ? parts[parts.length - 1].charAt(0) : "")).toLocaleUpperCase("tr-TR");
        },

        markup() {
            if (!QUOTES.length) return "";
            const item = QUOTES[(this._todayIndex() + this._offset) % QUOTES.length];
            const meta = [item.y, item.s].filter(Boolean).join(" · ");
            return `
            <section class="news-paper-quote" data-quote-root>
                <p class="news-paper-section-label">🖋️ ${this._offset ? "TARİHTEN BİR SÖZ" : "GÜNÜN SÖZÜ"}</p>
                <figure class="quote-figure">
                    <blockquote class="quote-text">${esc(item.q)}</blockquote>
                    <figcaption class="quote-author">
                        <span class="quote-monogram" aria-hidden="true">${esc(this._initials(item.a))}</span>
                        <span class="quote-who">
                            <strong>${esc(item.a)}</strong>
                            ${meta ? `<span>${esc(meta)}</span>` : ""}
                        </span>
                    </figcaption>
                    ${item.n ? `<p class="quote-note">${esc(item.n)}</p>` : ""}
                </figure>
                <button type="button" class="quote-next" data-quote-next>Başka bir söz →</button>
            </section>`;
        },

        bind(root) {
            const section = root && root.querySelector("[data-quote-root]");
            const button = section && section.querySelector("[data-quote-next]");
            if (!button) return;
            button.addEventListener("click", () => {
                this._offset = (this._offset + 1) % QUOTES.length;
                const holder = document.createElement("div");
                holder.innerHTML = this.markup();
                const fresh = holder.firstElementChild;
                section.replaceWith(fresh);
                this.bind(fresh.parentElement);
                const next = fresh.querySelector("[data-quote-next]");
                if (next) next.focus();
            });
        },
    };
})();
