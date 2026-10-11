-- Gunun sorulari: 100 soruluk havuzdan her oyuncuya gunde 10 soru (istege bagli).
-- Her soru isaretlendigi an dogru/yanlis ve aciklamasi gosterilir; her dogru cevap kucuk bir odul kazandirir.
-- Gun, Turkiye saatine gore degisir. Oyuncu daha once gormedigi sorulara oncelik verilerek secim yapilir.

CREATE TABLE IF NOT EXISTS public.daily_questions (
    id            SERIAL PRIMARY KEY,
    category      TEXT NOT NULL,
    question      TEXT NOT NULL UNIQUE,
    options       JSONB NOT NULL CHECK (jsonb_typeof(options) = 'array'),
    correct_index SMALLINT NOT NULL CHECK (correct_index >= 0),
    explanation   TEXT,
    is_active     BOOLEAN NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.daily_quiz_attempts (
    user_id       UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    quiz_date     DATE NOT NULL,
    question_ids  INTEGER[] NOT NULL,
    answers       JSONB NOT NULL DEFAULT '{}'::jsonb,
    correct_count INTEGER NOT NULL DEFAULT 0,
    reward        NUMERIC NOT NULL DEFAULT 0,
    completed_at  TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, quiz_date)
);

ALTER TABLE public.daily_questions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_quiz_attempts ENABLE ROW LEVEL SECURITY;

-- Sorulara ve cevaplara siteden dogrudan erisim yok; yalnizca fonksiyonlar okur ve yazar.
REVOKE ALL ON public.daily_questions, public.daily_quiz_attempts FROM anon, authenticated;

ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS daily_quiz_reward NUMERIC NOT NULL DEFAULT 100 CHECK (daily_quiz_reward >= 0);
ALTER TABLE public.engine_settings
    ADD COLUMN IF NOT EXISTS daily_quiz_size INTEGER NOT NULL DEFAULT 10 CHECK (daily_quiz_size BETWEEN 1 AND 30);

INSERT INTO public.daily_questions (category, question, options, correct_index, explanation)
SELECT v.category, v.question, v.options::jsonb, v.correct_index, v.explanation
FROM (VALUES
    ('mikro', 'İktisatta "kıtlık" neyi ifade eder?', '["İhtiyaçların sınırsız, kaynakların sınırlı olmasını","Bir malın piyasada hiç bulunmamasını","Fiyatların sürekli yükselmesini","İşsizliğin artmasını"]', 0, 'Kıtlık, iktisadın çıkış noktasıdır: kaynaklar herkesin her isteğini karşılamaya yetmediği için seçim yapmak gerekir.'),
    ('mikro', 'Bir malın fiyatı düştüğünde talep edilen miktarın artmasını hangisi açıklar?', '["Arz kanunu","Talep kanunu","Azalan verimler kanunu","Gresham kanunu"]', 1, 'Talep kanununa göre, diğer koşullar sabitken fiyat ile talep edilen miktar ters yönde hareket eder.'),
    ('mikro', 'Aşağıdakilerden hangisi tamamlayıcı mallara örnektir?', '["Çay ve kahve","Tereyağı ve margarin","Otomobil ve benzin","Otobüs ve metro"]', 2, 'Tamamlayıcı mallar birlikte kullanılır. Benzin pahalanırsa otomobil talebi de olumsuz etkilenir.'),
    ('mikro', 'Aşağıdakilerden hangisi ikame (birbirinin yerine geçen) mallara örnektir?', '["Çay ve kahve","Yazıcı ve kartuş","Telefon ve şarj aleti","Ayakkabı ve bağcık"]', 0, 'İkame mallar aynı ihtiyacı karşılar. Kahve pahalanırsa bazı tüketiciler çaya yönelir.'),
    ('mikro', 'Talebi esnek olan bir malın fiyatı %10 artarsa talep edilen miktar nasıl değişir?', '["Hiç değişmez","%10''dan az azalır","Tam %10 azalır","%10''dan fazla azalır"]', 3, 'Esnek talepte tüketici fiyata duyarlıdır; miktardaki yüzde değişim fiyattaki yüzde değişimden büyük olur.'),
    ('mikro', 'Arz kanununa göre bir malın fiyatı yükseldiğinde üreticiler genellikle ne yapar?', '["Üretimi durdurur","Daha fazla mal arz eder","Arzı azaltır","Fiyatı sabitler"]', 1, 'Yüksek fiyat üretimi daha kârlı kılar; bu yüzden fiyat ile arz edilen miktar aynı yönde hareket eder.'),
    ('mikro', 'Piyasa dengesi hangi durumda oluşur?', '["Fiyat sıfır olduğunda","Üreticiler zarar ettiğinde","Arz edilen miktar talep edilen miktara eşit olduğunda","Devlet fiyatı belirlediğinde"]', 2, 'Denge fiyatında alıcıların almak istediği miktar ile satıcıların satmak istediği miktar birbirine eşittir.'),
    ('mikro', 'Bir malın fiyatı denge fiyatının üzerindeyse piyasada ne oluşur?', '["Arz fazlası","Talep fazlası","Kıtlık","Karaborsa"]', 0, 'Fiyat yüksekken satıcılar çok satmak ister ama alıcılar az alır; elde mal kalır. Fiyat düştükçe denge kurulur.'),
    ('mikro', 'Devlet bir mala denge fiyatının altında tavan fiyat koyarsa genellikle ne olur?', '["Arz fazlası oluşur","Hiçbir şey değişmez","Üretim artar","Malda kıtlık oluşur"]', 3, 'Düşük fiyatta talep artar, arz azalır. Talep edilen miktar arz edileni aştığı için mal bulmak zorlaşır.'),
    ('mikro', 'Marjinal fayda nedir?', '["Toplam tüketimden elde edilen fayda","Bir birim daha tüketmenin sağladığı ek fayda","Bir malın üretim maliyeti","Satıcının elde ettiği kâr"]', 1, 'Marjinal, "ek" demektir. Kararlar çoğu zaman toplam faydaya değil, bir birim daha almanın getirdiği ek faydaya göre verilir.'),
    ('mikro', 'Azalan marjinal fayda ilkesi neyi söyler?', '["Fiyat arttıkça fayda artar","Üretim arttıkça maliyet düşer","Bir maldan tüketilen her ek birimin sağladığı fayda giderek azalır","Gelir arttıkça tasarruf azalır"]', 2, 'Çok susamışken içilen ilk bardak su çok değerlidir; beşinci bardak aynı faydayı sağlamaz.'),
    ('mikro', 'Aşağıdakilerden hangisi tam rekabet piyasasının özelliğidir?', '["Çok sayıda alıcı ve satıcı, birbirinin aynısı ürünler","Tek bir satıcı","Piyasaya girişin yasak olması","Fiyatı tek bir firmanın belirlemesi"]', 0, 'Tam rekabette hiçbir alıcı ya da satıcı fiyatı tek başına etkileyemez; herkes piyasa fiyatını kabul eder.'),
    ('mikro', 'Bir malın tek bir satıcısının olduğu piyasa türüne ne denir?', '["Oligopol","Tam rekabet","Monopson","Monopol"]', 3, 'Monopolde (tekel) satıcının rakibi yoktur; bu yüzden fiyat üzerinde büyük gücü olur.'),
    ('mikro', 'Az sayıda büyük firmanın hâkim olduğu piyasa türüne ne denir?', '["Monopol","Oligopol","Tam rekabet","Monopolcü rekabet"]', 1, 'Oligopolde firmalar birbirinin kararlarını yakından izler. Cep telefonu operatörleri tipik bir örnektir.'),
    ('mikro', 'Aşağıdakilerden hangisi bir işletme için sabit maliyettir?', '["Ham madde gideri","Parça başı işçilik","İş yeri kirası","Ürün başına kargo ücreti"]', 2, 'Sabit maliyet üretim miktarına göre değişmez. Hiç üretim yapılmasa da kira ödenir.'),
    ('mikro', 'Üretim miktarı arttıkça birim maliyetin düşmesine ne denir?', '["Ölçek ekonomisi","Enflasyon","Azalan verimler","Fırsat maliyeti"]', 0, 'Büyük ölçekte üretim, sabit maliyetleri daha çok ürüne yayar; her ürünün payına düşen maliyet azalır.'),
    ('mikro', 'Tüketicinin geliri arttığında talebi artan mallara ne ad verilir?', '["Düşük mal","Kamusal mal","Serbest mal","Normal mal"]', 3, 'Malların çoğu normal maldır: gelir artınca daha fazla talep edilir.'),
    ('mikro', 'Tüketicinin geliri arttığında talebi azalan mallara ne ad verilir?', '["Lüks mal","Düşük (inferior) mal","Normal mal","Tamamlayıcı mal"]', 1, 'Gelir artınca tüketici daha kaliteli alternatife geçer; ucuz ikame ürünlerin talebi düşer.'),
    ('mikro', 'Aşağıdakilerden hangisi negatif dışsallığa örnektir?', '["Bir arıcının komşu bahçedeki meyve verimini artırması","Bir öğrencinin burs kazanması","Bir fabrikanın nehri kirletmesi","Bir mağazanın indirim yapması"]', 2, 'Dışsallık, bir faaliyetin üçüncü kişilere bedeli ödenmeyen etkisidir. Kirliliğin maliyetine fabrika değil çevredekiler katlanır.'),
    ('mikro', 'Aşağıdakilerden hangisi kamusal mala örnektir?', '["Sokak aydınlatması","Sinema bileti","Cep telefonu","Restoran yemeği"]', 0, 'Kamusal maldan kimse dışlanamaz ve bir kişinin kullanması diğerinin kullanımını azaltmaz; bu yüzden genellikle devlet sağlar.'),
    ('makro', 'İşsizlik oranı nasıl hesaplanır?', '["İşsiz sayısı / toplam nüfus","İşsiz sayısı / işgücü","Çalışan sayısı / toplam nüfus","İşsiz sayısı / çalışan sayısı"]', 1, 'İşgücü, çalışanlar ile iş arayan işsizlerin toplamıdır. Çalışmayan ve iş aramayanlar (öğrenci, emekli) hesaba girmez.'),
    ('makro', 'Yaygın tanımıyla "resesyon" nedir?', '["Fiyatların hızla artması","Borsanın bir günde düşmesi","İhracatın ithalatı geçmesi","Ekonominin art arda iki çeyrek küçülmesi"]', 3, 'Resesyon ekonomik durgunluktur; pratikte reel GSYH''nin art arda iki çeyrek daralması olarak tanımlanır.'),
    ('makro', 'Deflasyon nedir?', '["Fiyatlar genel düzeyinin sürekli düşmesi","Fiyatlar genel düzeyinin sürekli artması","İşsizliğin azalması","Paranın değer kaybetmesi"]', 0, 'Deflasyon iyi gibi görünse de tüketiciler "nasılsa ucuzlayacak" diye harcamayı erteler; bu da üretimi ve istihdamı düşürebilir.'),
    ('makro', 'Stagflasyon nedir?', '["Hızlı büyüme ile düşük enflasyon","Düşük işsizlik ile düşük enflasyon","Durgunluk ile yüksek enflasyonun aynı anda yaşanması","Faizlerin sıfıra inmesi"]', 2, 'Stagflasyon iki sorunu birleştirir: ekonomi büyümez, işsizlik artar ama fiyatlar yükselmeye devam eder.'),
    ('makro', 'Tüketici Fiyat Endeksi (TÜFE) neyi ölçer?', '["Şirketlerin kârlarını","Tüketicilerin satın aldığı mal ve hizmet sepetinin fiyat değişimini","Hisse senedi fiyatlarını","Döviz kurundaki değişimi"]', 1, 'TÜFE, tipik bir hanenin harcama sepetinin fiyatını izler; enflasyon çoğunlukla bu endeksle ölçülür.'),
    ('makro', 'Reel GSYH''nin nominal GSYH''den farkı nedir?', '["Yalnızca ihracatı kapsar","Yalnızca kamu harcamalarını kapsar","Dolar cinsinden hesaplanır","Fiyat artışlarının etkisinden arındırılmıştır"]', 3, 'Nominal GSYH fiyatlar arttığı için de büyüyebilir. Reel GSYH gerçek üretim artışını gösterir.'),
    ('makro', 'Kişi başına GSYH nasıl bulunur?', '["GSYH nüfusa bölünerek","GSYH çalışan sayısıyla çarpılarak","İhracat nüfusa bölünerek","Vergi gelirleri nüfusa bölünerek"]', 0, 'Kişi başına GSYH, ülkelerin ortalama refah düzeyini karşılaştırmak için kullanılır; gelirin nasıl dağıldığını göstermez.'),
    ('makro', 'Maliye politikasının temel araçları hangileridir?', '["Faiz ve döviz kuru","Zorunlu karşılıklar","Vergiler ve kamu harcamaları","Hisse senedi ve tahvil"]', 2, 'Maliye politikasını hükümet yürütür: ne kadar vergi toplayacağına ve ne kadar harcayacağına karar verir.'),
    ('makro', 'Para politikasını hangi kurum yürütür?', '["Maliye Bakanlığı","Merkez bankası","Borsa","Ticari bankalar"]', 1, 'Merkez bankası faiz ve para miktarı üzerinden fiyat istikrarını sağlamaya çalışır.'),
    ('makro', 'Bütçe açığı ne demektir?', '["İhracatın ithalattan az olması","Şirketlerin zarar etmesi","Enflasyonun hedefi aşması","Devlet harcamalarının gelirlerini aşması"]', 3, 'Devlet topladığından fazlasını harcarsa aradaki farkı borçlanarak kapatır.'),
    ('makro', 'Aşağıdakilerden hangisi genişletici maliye politikasıdır?', '["Kamu harcamalarını artırmak","Vergileri artırmak","Kamu harcamalarını kısmak","Faizleri yükseltmek"]', 0, 'Genişletici politika ekonomiyi canlandırmayı amaçlar: devlet daha çok harcar ya da vergileri indirir.'),
    ('makro', 'Aşağıdakilerden hangisi dolaysız (doğrudan) vergidir?', '["KDV","ÖTV","Gelir vergisi","Gümrük vergisi"]', 2, 'Dolaysız vergi doğrudan gelir ya da servet üzerinden alınır ve başkasına yansıtılamaz.'),
    ('makro', 'Aşağıdakilerden hangisi dolaylı vergidir?', '["Kurumlar vergisi","KDV","Gelir vergisi","Emlak vergisi"]', 1, 'Dolaylı vergi harcama üzerinden alınır ve fiyatın içinde ödenir; geliri ne olursa olsun herkes aynı oranı öder.'),
    ('makro', 'İş değiştirme ya da ilk kez iş arama sürecindeki geçici işsizliğe ne denir?', '["Yapısal işsizlik","Konjonktürel işsizlik","Gizli işsizlik","Friksiyonel işsizlik"]', 3, 'Friksiyonel (geçici) işsizlik en sağlıklı ekonomide bile vardır; çünkü iş aramak ve bulmak zaman alır.'),
    ('makro', 'İşsizlerin becerileri ile açık işlerin gerektirdiği becerilerin uyuşmamasından doğan işsizliğe ne denir?', '["Yapısal işsizlik","Friksiyonel işsizlik","Mevsimlik işsizlik","Gönüllü işsizlik"]', 0, 'Teknoloji değiştikçe bazı meslekler ortadan kalkar; yeni işler farklı beceriler ister.'),
    ('makro', 'Enflasyon yükselirken geliri sabit kalan bir kişinin satın alma gücü ne olur?', '["Artar","Değişmez","Düşer","Önce artar sonra sabitlenir"]', 2, 'Aynı parayla daha az mal alınabilir. Enflasyon bu yüzden sabit gelirlileri en çok etkiler.'),
    ('makro', 'Reel faiz yaklaşık olarak nasıl hesaplanır?', '["Nominal faiz + enflasyon","Nominal faiz − enflasyon","Nominal faiz × enflasyon","Enflasyon − büyüme"]', 1, 'Faiz %40, enflasyon %30 ise paranın satın alma gücü gerçekte yaklaşık %10 artmıştır.'),
    ('makro', 'Ekonomik büyüme nasıl ölçülür?', '["Borsa endeksindeki artışla","Döviz kurundaki artışla","Nüfus artışıyla","Reel GSYH''deki artışla"]', 3, 'Büyüme, bir ülkenin ürettiği mal ve hizmet miktarının gerçek anlamda artmasıdır.'),
    ('makro', 'Cari açık ne demektir?', '["Ülkenin dış dünyadan kazandığından fazlasını dış dünyaya ödemesi","Devletin vergi toplayamaması","Bankaların kredi verememesi","Şirketlerin borsadan çıkması"]', 0, 'Cari açık veren ülke, aradaki farkı yabancı sermaye girişi ya da borçla finanse eder.'),
    ('makro', 'Hiperenflasyon nedir?', '["Enflasyonun sıfıra inmesi","Fiyatların düşmesi","Fiyatların çok yüksek hızla ve kontrolsüz biçimde artması","Faizlerin enflasyonu aşması"]', 2, 'Hiperenflasyonda para değerini o kadar hızlı kaybeder ki insanlar parayı elde tutmaktan kaçınır.'),
    ('para', 'Aşağıdakilerden hangisi paranın işlevlerinden biri DEĞİLDİR?', '["Değişim aracı olmak","Hesap birimi olmak","Değer saklama aracı olmak","Riski tamamen ortadan kaldırmak"]', 3, 'Paranın üç temel işlevi vardır: değişim aracı, hesap birimi ve değer saklama aracı. Para riski ortadan kaldırmaz; enflasyonda değer kaybeder.'),
    ('para', 'Türkiye''de para politikasından sorumlu kurum hangisidir?', '["Türkiye Cumhuriyet Merkez Bankası (TCMB)","Sermaye Piyasası Kurulu (SPK)","Borsa İstanbul","Bankacılık Düzenleme ve Denetleme Kurumu (BDDK)"]', 0, 'TCMB''nin temel amacı fiyat istikrarını sağlamaktır; politika faizini o belirler.'),
    ('para', 'Merkez bankası faiz indirdiğinde genellikle hangisi beklenir?', '["Krediler pahalılaşır","Tasarruf artar, harcama azalır","Krediler ucuzlar, harcamalar artar","Enflasyon hemen düşer"]', 2, 'Düşük faiz borçlanmayı ucuzlatır; tüketim ve yatırım canlanır. Aşırıya kaçarsa enflasyonu artırabilir.'),
    ('para', 'Zorunlu karşılık oranı artırılırsa bankaların verebileceği kredi miktarı ne olur?', '["Artar","Azalır","Değişmez","İki katına çıkar"]', 1, 'Bankalar mevduatın daha büyük kısmını merkez bankasında tutmak zorunda kalır; krediye ayırabilecekleri para azalır.'),
    ('para', 'Likidite ne demektir?', '["Bir şirketin kârlılığı","Bir ülkenin altın rezervi","Bir bankanın şube sayısı","Bir varlığın hızla ve değer kaybetmeden nakde çevrilebilmesi"]', 3, 'Kolay alınıp satılan varlık likittir. Bir ev, hisse senedine göre çok daha az likittir.'),
    ('para', 'Aşağıdakilerden hangisi en likit varlıktır?', '["Nakit para","Gayrimenkul","Otomobil","Tablo ve antika"]', 0, 'Nakit zaten paradır; başka bir şeye çevrilmesi gerekmez.'),
    ('para', 'Bileşik faiz ne demektir?', '["Faizin yalnızca anapara üzerinden hesaplanması","Faizin peşin ödenmesi","Kazanılan faizin anaparaya eklenip onun da faiz kazanması","Faizin enflasyona eşit olması"]', 2, 'Bileşik faizde "faizin faizi" işler; para zamanla katlanarak büyür.'),
    ('para', '1.000 ₺, yıllık %50 basit faizle bir yıl sonunda kaç lira olur?', '["1.050 ₺","1.500 ₺","2.000 ₺","1.250 ₺"]', 1, '1.000 ₺''nin %50''si 500 ₺ eder; anaparayla birlikte 1.500 ₺ olur.'),
    ('para', 'Mevduat faizi nedir?', '["Bankanın kredi kullanandan aldığı faiz","Merkez bankasının bankalara uyguladığı faiz","Devletin tahvile ödediği faiz","Bankanın, parasını yatırana ödediği faiz"]', 3, 'Banka mevduata düşük, krediye yüksek faiz uygular; aradaki fark bankanın temel gelir kaynağıdır.'),
    ('para', 'Bankalar kredi notu düşük olan birine genellikle nasıl davranır?', '["Daha yüksek faiz ister ya da kredi vermez","Daha düşük faiz uygular","Hiç faiz almaz","Daha uzun vade tanır"]', 0, 'Geri ödememe riski arttıkça banka bu riskin karşılığını ister. Risk ile getiri burada da birlikte hareket eder.'),
    ('para', 'Emisyon ne demektir?', '["Bankaların iflas etmesi","Dövizin ülke dışına çıkması","Paranın basılıp dolaşıma sürülmesi","Verginin artırılması"]', 2, 'Emisyon yetkisi merkez bankasındadır. Karşılıksız para basmak enflasyona yol açar.'),
    ('para', 'Açık piyasa işlemleri nedir?', '["Borsada hisse alıp satmak","Merkez bankasının menkul kıymet alıp satarak piyasadaki para miktarını ayarlaması","Bankaların gece açık kalması","Dövizin serbestçe alınıp satılması"]', 1, 'Merkez bankası tahvil alırsa piyasaya para verir, satarsa piyasadan para çeker.'),
    ('para', 'Enflasyon hedeflemesi nedir?', '["Devletin fiyatları tek tek belirlemesi","Bankaların faizleri sabitlemesi","Döviz kurunun sabit tutulması","Merkez bankasının bir enflasyon hedefi açıklayıp politikasını buna göre yürütmesi"]', 3, 'Hedefin açıklanması beklentileri yönlendirir: insanlar hedefe inanırsa fiyat ve ücret kararlarını ona göre verir.'),
    ('para', 'Mevduat faizi %40, enflasyon %50 ise paranın reel getirisi nasıldır?', '["Negatiftir","Pozitiftir","Sıfırdır","Hesaplanamaz"]', 0, 'Para faizle büyümüş görünse de fiyatlar daha hızlı arttığı için satın alma gücü azalmıştır.'),
    ('para', 'Dolarizasyon ne demektir?', '["Doların değer kaybetmesi","İhracatın dolarla yapılması","İnsanların yerli para yerine yabancı parayı tercih etmesi","Merkez bankasının dolar basması"]', 2, 'Yerli paraya güven azaldığında insanlar birikimlerini dövizde tutar, hatta fiyatları dövizle belirler.'),
    ('finans', 'Borsa İstanbul''un en bilinen ana endeksi hangisidir?', '["Dow Jones","BIST 100","NASDAQ","DAX"]', 1, 'BIST 100, Borsa İstanbul''da işlem gören en büyük 100 şirketin performansını gösterir.'),
    ('finans', 'Temettü nedir?', '["Hisse senedinin alış fiyatı","Aracı kurum komisyonu","Şirketin bankaya ödediği faiz","Şirket kârının ortaklara dağıtılan kısmı"]', 3, 'Şirket kâr ederse bir kısmını hissedarlarına nakit ya da hisse olarak dağıtabilir.'),
    ('finans', 'Tahvil satın alan kişi ne yapmış olur?', '["Tahvili çıkaran kuruma borç vermiş olur","Şirkete ortak olmuş olur","Döviz almış olur","Sigorta yaptırmış olur"]', 0, 'Tahvil bir borç senedidir: vade sonunda anapara ve faiz geri ödenir. Hisse ise ortaklıktır.'),
    ('finans', 'Halka arz ne demektir?', '["Şirketin iflas etmesi","Şirketin başka bir şirketi satın alması","Şirket paylarının ilk kez yatırımcılara satışa sunulması","Şirketin borsadan çıkması"]', 2, 'Halka arzla şirket büyümek için kaynak bulur, yatırımcılar da şirkete ortak olma imkânı elde eder.'),
    ('finans', '"Boğa piyasası" ne anlama gelir?', '["Fiyatların genel olarak düştüğü dönem","Fiyatların genel olarak yükseldiği dönem","Borsanın kapalı olduğu dönem","İşlem hacminin sıfır olduğu dönem"]', 1, 'Boğa boynuzlarıyla aşağıdan yukarı vurur; bu yüzden yükselen piyasanın simgesidir.'),
    ('finans', '"Ayı piyasası" ne anlama gelir?', '["Fiyatların hızla yükseldiği dönem","Yeni şirketlerin halka arz edildiği dönem","Temettü dağıtılan dönem","Fiyatların genel olarak düştüğü dönem"]', 3, 'Ayı pençesiyle yukarıdan aşağı vurur; düşen piyasanın simgesidir.'),
    ('finans', 'Volatilite (oynaklık) neyi ifade eder?', '["Bir varlığın fiyatının ne kadar dalgalandığını","Bir şirketin kaç çalışanı olduğunu","Bir hissenin kaç yıldır işlem gördüğünü","Bir bankanın faiz oranını"]', 0, 'Oynaklığı yüksek varlıkta fiyat kısa sürede çok değişir; hem kazanç hem kayıp ihtimali büyüktür.'),
    ('finans', 'Portföy nedir?', '["Bir şirketin borçları","Bir hissenin geçmiş fiyatları","Bir yatırımcının sahip olduğu varlıkların tümü","Borsadaki bütün şirketler"]', 2, 'Hisse, tahvil, altın ve döviz gibi varlıkların toplamı yatırımcının portföyünü oluşturur.'),
    ('finans', 'Borsada "devre kesici" ne işe yarar?', '["Elektrik kesintisinde sistemi korur","Sert fiyat hareketlerinde işlemleri geçici olarak durdurur","Komisyonları düşürür","Yeni hisseleri borsaya kabul eder"]', 1, 'Amaç panik ortamında yatırımcılara düşünme süresi tanımaktır. Bu oyunda da aynı mekanizma var.'),
    ('finans', 'Bir şirketin piyasa değeri nasıl hesaplanır?', '["Yıllık kâr × 10","Toplam borç + sermaye","Çalışan sayısı × ortalama maaş","Hisse fiyatı × toplam hisse sayısı"]', 3, 'Piyasa değeri, yatırımcıların şirkete biçtiği toplam değeri gösterir ve fiyatla birlikte her an değişir.'),
    ('finans', 'Açığa satış nedir?', '["Elinde olmayan bir hisseyi ödünç alıp satmak ve düşüşten kazanmayı ummak","Hisseyi zararına satmak","Borsanın açılışında satış yapmak","Hisseyi borsa dışında satmak"]', 0, 'Açığa satan kişi fiyat düşerse hisseyi ucuza geri alıp kâr eder; fiyat yükselirse zarar eder.'),
    ('finans', 'Az işlem gören (sığ) bir hissede büyük bir alım emri fiyatı nasıl etkiler?', '["Hiç etkilemez","Fiyatı düşürür","Derin bir hisseye göre daha fazla yükseltir","Derin bir hisseye göre daha az yükseltir"]', 2, 'Satıcı az olduğunda büyük alım, fiyatı yukarı iterek karşılanır. Bu oyunda riskli hisseler daha sığdır.'),
    ('finans', 'Alış-satış farkı (spread) nedir?', '["Bir günün en yüksek ve en düşük fiyatı arasındaki fark","Bir varlığın alış fiyatı ile satış fiyatı arasındaki fark","Hisse fiyatı ile temettü arasındaki fark","İki farklı borsa arasındaki fiyat farkı"]', 1, 'Döviz bürosunda dolar alırken ve satarken farklı fiyat görürsün; aradaki fark aracının kazancıdır.'),
    ('finans', 'Aracı kurum komisyonu nedir?', '["Şirketin dağıttığı kâr","Devletin aldığı gelir vergisi","Hissenin değer artışı","Alım-satım işlemi için aracı kuruma ödenen ücret"]', 3, 'Her işlemde ödenen komisyon, sık alım-satım yapanların getirisini azaltır. Bu oyunda komisyon %1''dir.'),
    ('finans', '"Bütün yumurtaları aynı sepete koyma" sözü hangi yatırım ilkesini anlatır?', '["Çeşitlendirme","Kaldıraç","Açığa satış","Temettü verimi"]', 0, 'Parayı farklı varlıklara dağıtmak, birinin kötü gitmesi durumunda toplam kaybı sınırlar.'),
    ('finans', 'Fiyat/Kazanç (F/K) oranı nasıl hesaplanır?', '["Hisse fiyatı × hisse sayısı","Net kâr / toplam borç","Hisse fiyatı / hisse başına kâr","Temettü / hisse fiyatı"]', 2, 'F/K, yatırımcının şirketin 1 liralık kârı için kaç lira ödediğini gösterir; şirketleri karşılaştırmada kullanılır.'),
    ('finans', 'Yatırım fonu nedir?', '["Devletin topladığı vergi","Birçok yatırımcının parasını bir araya getirip uzmanlarca yöneten araç","Bankanın verdiği kredi","Şirketin yedek akçesi"]', 1, 'Fon sayesinde küçük bir parayla bile çok sayıda varlığa yayılmış bir portföye ortak olunabilir.'),
    ('finans', 'Beta katsayısı 1''den büyük olan bir hisse için hangisi söylenir?', '["Piyasadan bağımsız hareket eder","Hiç risk taşımaz","Piyasa yükselirken düşer","Piyasaya göre daha oynaktır"]', 3, 'Beta, hissenin piyasa hareketlerine duyarlılığını ölçer. Bu oyunda riskli hisselerin betası 1,5''tir.'),
    ('finans', 'Sermaye Piyasası Kurulu''nun (SPK) görevi nedir?', '["Sermaye piyasalarını düzenlemek ve denetlemek","Para basmak","Vergi toplamak","Faiz oranlarını belirlemek"]', 0, 'SPK yatırımcıyı korumak için halka arzları, aracı kurumları ve piyasadaki işlemleri denetler.'),
    ('finans', 'İçeriden öğrenenlerin ticareti (insider trading) nedir?', '["Borsa içinde çalışmak","Yabancı yatırımcıların işlem yapması","Kamuya açıklanmamış özel bilgiyi kullanarak işlem yapmak","Aynı gün içinde alıp satmak"]', 2, 'Herkesin aynı bilgiye sahip olması piyasanın adil işlemesi için şarttır; bu yüzden içeriden bilgiyle işlem yapmak suçtur.'),
    ('finans', 'Zarar kes (stop-loss) emri ne işe yarar?', '["Kârı ikiye katlar","Fiyat belirlenen seviyeye düşünce satış yaparak zararı sınırlar","Komisyonu sıfırlar","Temettüyü erkene alır"]', 1, 'Yatırımcı ne kadar zarara katlanacağını önceden belirler; duygularıyla değil planıyla hareket eder.'),
    ('finans', 'Aşağıdakilerden hangisi genellikle en düşük riskli yatırım sayılır?', '["Yeni kurulmuş bir şirketin hissesi","Kripto para","Kaldıraçlı döviz işlemi","Devlet tahvili"]', 3, 'Devletin borcunu ödememe ihtimali çok düşük görülür; bu yüzden getirisi de genellikle düşüktür.'),
    ('finans', 'Bir hissenin fiyatı 50 ₺''den 55 ₺''ye çıktı. Getiri yüzde kaçtır?', '["%10","%5","%55","%1"]', 0, 'Artış 5 ₺''dir. 5 / 50 = 0,10, yani %10.'),
    ('finans', '100 ₺''lik bir hisse önce %50 düştü, sonra %50 yükseldi. Son fiyat kaç liradır?', '["100 ₺","50 ₺","75 ₺","125 ₺"]', 2, 'Önce 50 ₺''ye iner; 50 ₺''nin %50''si 25 ₺''dir, yani 75 ₺ olur. Aynı yüzdeyle düşüp çıkmak başa döndürmez.'),
    ('finans', 'Sermaye kazancı nedir?', '["Şirketin dağıttığı temettü","Bir varlığı aldığından daha yüksek fiyata satarak elde edilen kazanç","Bankadan alınan faiz","Kira geliri"]', 1, 'Hisse yatırımcısı iki yoldan kazanır: fiyat artışı (sermaye kazancı) ve temettü.'),
    ('dis', 'İhracat nedir?', '["Yurt dışından mal ve hizmet almak","Yurt içinde üretim yapmak","Döviz biriktirmek","Yurt dışına mal ve hizmet satmak"]', 3, 'İhracat ülkeye döviz kazandırır; ithalat ise döviz çıkışına yol açar.'),
    ('dis', 'Bir ülkenin ithalatı ihracatından fazlaysa bu duruma ne denir?', '["Dış ticaret açığı","Dış ticaret fazlası","Bütçe fazlası","Enflasyon"]', 0, 'Ülke dışarıya sattığından fazlasını satın alıyordur; aradaki farkın bir şekilde finanse edilmesi gerekir.'),
    ('dis', 'Gümrük vergisi (tarife) nedir?', '["İhracata verilen destek","Yurt içi satışlardan alınan vergi","İthal edilen mallardan alınan vergi","Döviz alımından alınan vergi"]', 2, 'Gümrük vergisi ithal malı pahalılaştırarak yerli üreticiyi korur; ama tüketici için fiyatları artırır.'),
    ('dis', 'Devalüasyon nedir?', '["Ulusal paranın değerinin yükseltilmesi","Ulusal paranın değerinin resmî bir kararla düşürülmesi","Faizlerin düşürülmesi","Vergilerin artırılması"]', 1, 'Devalüasyon sabit kur sistemine özgüdür. Dalgalı kurda paranın kendiliğinden değer kaybetmesine "değer kaybı" denir.'),
    ('dis', 'Türk lirası değer kaybettiğinde ihracatçılar için genellikle hangisi geçerlidir?', '["Ürünleri yurt dışında pahalılaşır","İhracat yasaklanır","Hiçbir şey değişmez","Ürünleri yurt dışında ucuzlar, rekabet güçleri artar"]', 3, 'Yabancı alıcı aynı malı daha az dövizle alabilir. Ancak ithal ham madde kullanan üreticinin maliyeti de artar.'),
    ('dis', 'Türk lirası değer kaybettiğinde ithal ürünlerin fiyatı ne olur?', '["Yükselir","Düşer","Değişmez","Sıfırlanır"]', 0, 'Aynı ithal malı almak için daha fazla lira gerekir. Kur artışı bu yolla enflasyonu da yükseltir.'),
    ('dis', 'Karşılaştırmalı üstünlük ne demektir?', '["Bir ülkenin her malı en ucuza üretmesi","Bir ülkenin en büyük nüfusa sahip olması","Bir malı diğerlerine göre daha düşük fırsat maliyetiyle üretebilmek","Bir ülkenin en çok altına sahip olması"]', 2, 'Ülkeler görece daha verimli oldukları alanda uzmanlaşıp ticaret yaparsa iki taraf da kazançlı çıkar.'),
    ('dis', 'Dalgalı kur rejiminde döviz kuru nasıl belirlenir?', '["Devlet tarafından sabitlenir","Piyasada arz ve talebe göre oluşur","Altın fiyatına bağlanır","Yılda bir kez güncellenir"]', 1, 'Dövize talep artarsa kur yükselir, arz artarsa düşer. Merkez bankası gerektiğinde müdahale edebilir.'),
    ('dis', 'IMF''nin açılımı nedir?', '["Dünya Ticaret Örgütü","Avrupa Merkez Bankası","Dünya Bankası","Uluslararası Para Fonu"]', 3, 'IMF, ödemeler dengesi sorunu yaşayan ülkelere belirli koşullarla kredi veren uluslararası bir kuruluştur.'),
    ('dis', 'Euro Bölgesi''nin para politikasını hangi kurum yürütür?', '["Avrupa Merkez Bankası","Avrupa Parlamentosu","Dünya Bankası","Her ülkenin kendi merkez bankası ayrı ayrı"]', 0, 'Euro kullanan ülkeler ortak bir para politikasını paylaşır; faiz kararını Avrupa Merkez Bankası verir.'),
    ('temel', 'Aşağıdakilerden hangisi üretim faktörlerinden biri DEĞİLDİR?', '["Emek","Sermaye","Para","Doğal kaynaklar"]', 2, 'Üretim faktörleri emek, sermaye, doğal kaynaklar ve girişimciliktir. İktisatta "sermaye" para değil, makine ve bina gibi üretim araçlarıdır.'),
    ('temel', 'Emeğin üretimden aldığı paya ne denir?', '["Faiz","Ücret","Rant","Kâr"]', 1, 'Çalışanlar emeklerinin karşılığında ücret alır.'),
    ('temel', 'Sermayenin üretimden aldığı paya ne denir?', '["Ücret","Rant","Kâr","Faiz"]', 3, 'Sermayesini kullandıran kişi karşılığında faiz geliri elde eder.'),
    ('temel', 'Girişimcinin üretimden aldığı paya ne denir?', '["Kâr","Ücret","Faiz","Rant"]', 0, 'Girişimci risk alır ve diğer faktörleri bir araya getirir; karşılığı garantisi olmayan kârdır.'),
    ('temel', 'Doğal kaynakların (toprağın) üretimden aldığı paya ne denir?', '["Kâr","Faiz","Rant","Ücret"]', 2, 'Toprak ve doğal kaynak sahibinin elde ettiği gelire rant (kira) denir.'),
    ('temel', 'Mikroiktisat neyi inceler?', '["Ekonominin bütününü","Tüketicilerin ve firmaların kararlarını, tek tek piyasaları","Yalnızca devlet bütçesini","Yalnızca dış ticareti"]', 1, 'Mikroiktisat "küçük" birimlere bakar: bir tüketicinin tercihi, bir firmanın fiyatı, bir malın piyasası.'),
    ('temel', 'Makroiktisat neyi inceler?', '["Tek bir firmanın maliyetlerini","Tek bir malın fiyatını","Bir tüketicinin tercihlerini","Enflasyon, işsizlik ve büyüme gibi ekonominin bütününe ait konuları"]', 3, 'Makroiktisat ekonomiye kuşbakışı bakar: toplam üretim, genel fiyat düzeyi, toplam istihdam.'),
    ('temel', '"Görünmez el" kavramı hangi iktisatçıya aittir?', '["Adam Smith","John Maynard Keynes","Karl Marx","Milton Friedman"]', 0, 'Smith''e göre herkes kendi çıkarını gözetirken piyasa, görünmez bir el gibi kaynakları toplumun yararına yönlendirir.'),
    ('temel', 'Tasarruf nedir?', '["Gelirin tamamının harcanması","Borç alınan para","Gelirin harcanmayan kısmı","Devlete ödenen vergi"]', 2, 'Tasarruf bugünkü tüketimden vazgeçmektir; yatırıma dönüştüğünde gelecekte daha fazla gelir sağlar.'),
    ('temel', 'Batık maliyet nedir?', '["Gelecekte yapılacak harcama","Geçmişte yapılmış ve geri alınamayan harcama","Her ay ödenen sabit gider","Üretim arttıkça artan maliyet"]', 1, 'Geri gelmeyecek para yeni kararları etkilememelidir. Zarardaki hisseyi yalnızca "çok para yatırdım" diye tutmak bu hataya örnektir.')
) AS v(category, question, options, correct_index, explanation)
ON CONFLICT (question) DO NOTHING;

-- Bugunun (Turkiye saatiyle) tarihi.
CREATE OR REPLACE FUNCTION public.daily_quiz_today()
RETURNS DATE
LANGUAGE SQL
STABLE
AS $$
    SELECT (now() AT TIME ZONE 'Europe/Istanbul')::DATE;
$$;

-- Gunun sorularinin durumu: yeni / baslanmis / bitmis, sorular, isaretlenenlerin sonuclari ve gun serisi.
CREATE OR REPLACE FUNCTION public.get_daily_quiz()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _today DATE := public.daily_quiz_today();
    _attempt public.daily_quiz_attempts%ROWTYPE;
    _found BOOLEAN;
    _reward NUMERIC;
    _size INTEGER;
    _streak INTEGER := 0;
    _day DATE;
    _questions JSONB := '[]'::jsonb;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT daily_quiz_reward, daily_quiz_size INTO _reward, _size
    FROM public.engine_settings WHERE id = 1;
    _reward := coalesce(_reward, 100);
    _size := coalesce(_size, 10);

    SELECT * INTO _attempt
    FROM public.daily_quiz_attempts
    WHERE user_id = _uid AND quiz_date = _today;
    _found := FOUND;

    -- Seri: bugun bitirildiyse bugunden, bitirilmediyse dunden geriye dogru ust uste tamamlanan gunler.
    _day := CASE WHEN _found AND _attempt.completed_at IS NOT NULL THEN _today ELSE _today - 1 END;
    WHILE EXISTS (
        SELECT 1 FROM public.daily_quiz_attempts
        WHERE user_id = _uid AND quiz_date = _day AND completed_at IS NOT NULL
    ) LOOP
        _streak := _streak + 1;
        _day := _day - 1;
    END LOOP;

    IF _found THEN
        -- Dogru cevap ve aciklama yalnizca oyuncunun isaretledigi sorularda doner.
        SELECT coalesce(jsonb_agg(
            jsonb_build_object('id', q.id, 'question', q.question, 'options', q.options)
            || CASE WHEN _attempt.answers ? q.id::text THEN jsonb_build_object(
                   'chosen', (_attempt.answers ->> q.id::text)::INTEGER,
                   'correct_index', q.correct_index,
                   'explanation', q.explanation)
               ELSE '{}'::jsonb END
            ORDER BY ids.ord
        ), '[]'::jsonb)
        INTO _questions
        FROM unnest(_attempt.question_ids) WITH ORDINALITY AS ids(qid, ord)
        JOIN public.daily_questions AS q ON q.id = ids.qid;
    END IF;

    RETURN jsonb_build_object(
        'date', _today,
        'status', CASE WHEN NOT _found THEN 'new'
                       WHEN _attempt.completed_at IS NULL THEN 'started'
                       ELSE 'done' END,
        'size', CASE WHEN _found THEN coalesce(array_length(_attempt.question_ids, 1), 0) ELSE _size END,
        'reward_per_correct', _reward,
        'streak', _streak,
        'questions', _questions,
        'correct_count', CASE WHEN _found THEN _attempt.correct_count ELSE 0 END,
        'reward', CASE WHEN _found THEN _attempt.reward ELSE 0 END
    );
END;
$$;

-- Gunun sorularini baslatir: oyuncunun en az gordugu sorulardan rastgele secilir.
CREATE OR REPLACE FUNCTION public.start_daily_quiz()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _today DATE := public.daily_quiz_today();
    _size INTEGER;
    _ids INTEGER[];
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.daily_quiz_attempts WHERE user_id = _uid AND quiz_date = _today
    ) THEN
        SELECT coalesce(daily_quiz_size, 10) INTO _size FROM public.engine_settings WHERE id = 1;
        _size := coalesce(_size, 10);

        SELECT array_agg(p.id) INTO _ids
        FROM (
            SELECT q.id
            FROM public.daily_questions AS q
            WHERE q.is_active
            ORDER BY (
                SELECT count(*) FROM public.daily_quiz_attempts AS a
                WHERE a.user_id = _uid AND q.id = ANY(a.question_ids)
            ), random()
            LIMIT _size
        ) AS p;

        IF _ids IS NULL OR array_length(_ids, 1) = 0 THEN
            RAISE EXCEPTION 'Soru havuzu boş.';
        END IF;

        INSERT INTO public.daily_quiz_attempts (user_id, quiz_date, question_ids)
        VALUES (_uid, _today, _ids)
        ON CONFLICT (user_id, quiz_date) DO NOTHING;
    END IF;

    RETURN public.get_daily_quiz();
END;
$$;

-- Tek bir soruyu cevaplar: cevap kilitlenir, dogruysa odul bakiyeye eklenir.
CREATE OR REPLACE FUNCTION public.answer_daily_question(p_question_id INTEGER, p_choice INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _uid UUID := auth.uid();
    _today DATE := public.daily_quiz_today();
    _attempt public.daily_quiz_attempts%ROWTYPE;
    _question public.daily_questions%ROWTYPE;
    _reward NUMERIC;
    _chosen INTEGER;
    _correct BOOLEAN;
    _added NUMERIC := 0;
    _done BOOLEAN;
    _balance NUMERIC;
BEGIN
    IF _uid IS NULL THEN
        RAISE EXCEPTION 'Giris gerekli.' USING ERRCODE = '42501';
    END IF;

    SELECT * INTO _attempt
    FROM public.daily_quiz_attempts
    WHERE user_id = _uid AND quiz_date = _today
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Bugünün soruları değişti. Pencereyi kapatıp yeniden açın.';
    END IF;
    IF NOT (p_question_id = ANY(_attempt.question_ids)) THEN
        RAISE EXCEPTION 'Bu soru bugünün soruları arasında değil.';
    END IF;

    SELECT * INTO _question FROM public.daily_questions WHERE id = p_question_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Soru bulunamadı.';
    END IF;

    IF _attempt.answers ? p_question_id::text THEN
        -- Daha once isaretlenmis: ilk cevap gecerlidir, odul tekrar verilmez.
        _chosen := (_attempt.answers ->> p_question_id::text)::INTEGER;
        _correct := _chosen = _question.correct_index;
    ELSE
        IF p_choice IS NULL OR p_choice < 0 OR p_choice >= jsonb_array_length(_question.options) THEN
            RAISE EXCEPTION 'Geçersiz şık.';
        END IF;
        _chosen := p_choice;
        _correct := _chosen = _question.correct_index;

        IF _correct THEN
            SELECT coalesce(daily_quiz_reward, 100) INTO _reward FROM public.engine_settings WHERE id = 1;
            _added := coalesce(_reward, 100);
        END IF;

        UPDATE public.daily_quiz_attempts
        SET answers = answers || jsonb_build_object(p_question_id::text, _chosen),
            correct_count = correct_count + CASE WHEN _correct THEN 1 ELSE 0 END,
            reward = reward + _added,
            completed_at = CASE
                WHEN (SELECT count(*) FROM jsonb_object_keys(answers || jsonb_build_object(p_question_id::text, _chosen)))
                     >= coalesce(array_length(question_ids, 1), 0)
                THEN now() ELSE completed_at END
        WHERE user_id = _uid AND quiz_date = _today
        RETURNING * INTO _attempt;

        IF _added > 0 THEN
            UPDATE public.users SET balance = balance + _added WHERE id = _uid;
        END IF;
    END IF;

    _done := _attempt.completed_at IS NOT NULL;
    SELECT balance INTO _balance FROM public.users WHERE id = _uid;

    RETURN jsonb_build_object(
        'id', _question.id,
        'chosen', _chosen,
        'correct', _correct,
        'correct_index', _question.correct_index,
        'explanation', _question.explanation,
        'reward_added', _added,
        'correct_count', _attempt.correct_count,
        'reward', _attempt.reward,
        'done', _done,
        'balance', _balance
    );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_daily_quiz_reward(p_reward NUMERIC)
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;
    IF p_reward IS NULL OR p_reward < 0 OR p_reward > 10000 THEN
        RAISE EXCEPTION 'Doğru başına ödül 0 ile 10.000 ₺ arasında olmalı.';
    END IF;

    UPDATE public.engine_settings SET daily_quiz_reward = p_reward WHERE id = 1;
    RETURN p_reward;
END;
$$;

REVOKE ALL ON FUNCTION public.daily_quiz_today() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.get_daily_quiz() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.start_daily_quiz() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.answer_daily_question(INTEGER, INTEGER) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_set_daily_quiz_reward(NUMERIC) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.daily_quiz_today() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_daily_quiz() TO authenticated;
GRANT EXECUTE ON FUNCTION public.start_daily_quiz() TO authenticated;
GRANT EXECUTE ON FUNCTION public.answer_daily_question(INTEGER, INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_daily_quiz_reward(NUMERIC) TO authenticated;

-- Oyunu sifirlama: gunluk soru gecmisi de silinir.
CREATE OR REPLACE FUNCTION public.admin_reset_game()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    _users INTEGER;
BEGIN
    IF NOT public.is_borsa_admin() THEN
        RAISE EXCEPTION 'Yonetici yetkisi gerekli.' USING ERRCODE = '42501';
    END IF;

    UPDATE public.users
    SET balance = 100000,
        starting_balance = 100000,
        portfolio = '{}'::jsonb,
        assets = '{}'::jsonb
    WHERE true;
    GET DIAGNOSTICS _users = ROW_COUNT;

    DELETE FROM public.transactions WHERE true;
    DELETE FROM public.asset_transactions WHERE true;
    DELETE FROM public.quiz_attempts WHERE true;
    DELETE FROM public.daily_quiz_attempts WHERE true;
    DELETE FROM public.user_badges WHERE true;
    DELETE FROM public.market_tips WHERE true;
    DELETE FROM public.news_feed WHERE true;
    DELETE FROM public.price_history WHERE true;
    DELETE FROM public.price_history_hourly WHERE true;

    UPDATE public.stocks
    SET previous_close = current_price,
        change = 0,
        change_pct = 0,
        vol_mult = 1,
        breaker_ref = current_price,
        halt_until = NULL,
        impact_pending = 0,
        updated_at = now()
    WHERE symbol IS NOT NULL;

    UPDATE public.market_settings
    SET halt_until = NULL, halt_level = 0
    WHERE id = 1;

    INSERT INTO public.price_history (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM public.stocks;

    INSERT INTO public.price_history_hourly (symbol, price, recorded_at)
    SELECT symbol, current_price, now() FROM public.stocks;

    RETURN jsonb_build_object('users', _users);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_game() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_game() TO authenticated;

NOTIFY pgrst, 'reload schema';

SELECT category AS kategori, count(*) AS soru_sayisi
FROM public.daily_questions
WHERE is_active
GROUP BY category
ORDER BY category;
