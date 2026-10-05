"use client";

import { useState } from "react";
import Link from "next/link";
import { useMarket } from "@/context/MarketContext";

const QUICK_IMPACTS = [
  { label: "Çok Kötü -25%", value: -25, color: "#ff3b5c" },
  { label: "Kötü -15%", value: -15, color: "#ff6b8a" },
  { label: "Hafif Kötü -5%", value: -5, color: "#f59e0b" },
  { label: "Hafif İyi +5%", value: 5, color: "#84cc16" },
  { label: "İyi +15%", value: 15, color: "#22c55e" },
  { label: "Çok İyi +25%", value: 25, color: "#00ff88" },
];

const TITLE_TEMPLATES_POSITIVE = [
  "{name} büyük bir proje kazandı!",
  "{name} rekor kâr açıkladı",
  "{name} stratejik ortaklık duyurdu",
  "{name} yeni ürün lansmanı başarılı",
  "{name}CEO'su konuşmacı olarak ödül aldı",
];

const TITLE_TEMPLATES_NEGATIVE = [
  "{name} sınavdan FF aldı 😱",
  "{name} toplantıya geç kaldı",
  "{name} bütçe açıkları verdi",
  "{name} önemli müşterisini kaybetti",
  "{name} performansı düşüşte",
];

export default function AdminPage() {
  const { stocks, addNews, news } = useMarket();
  const [title, setTitle] = useState("");
  const [targetStockId, setTargetStockId] = useState(stocks[0]?.id ?? "");
  const [impactPercent, setImpactPercent] = useState<number>(5);
  const [author, setAuthor] = useState("Admin");
  const [submitted, setSubmitted] = useState(false);
  const [lastNews, setLastNews] = useState<string | null>(null);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!title.trim() || !targetStockId) return;

    const stock = stocks.find((s) => s.id === targetStockId);
    addNews({
      title: title.trim(),
      targetStockId,
      impactPercent,
      author: author.trim() || undefined,
    });

    setLastNews(`${stock?.name}: ${impactPercent >= 0 ? "+" : ""}${impactPercent}%`);
    setTitle("");
    setSubmitted(true);
    setTimeout(() => setSubmitted(false), 2500);
  }

  function pickTemplate(positive: boolean) {
    const stock = stocks.find((s) => s.id === targetStockId);
    if (!stock) return;
    const templates = positive ? TITLE_TEMPLATES_POSITIVE : TITLE_TEMPLATES_NEGATIVE;
    const t = templates[Math.floor(Math.random() * templates.length)];
    setTitle(t.replace("{name}", stock.name));
  }

  return (
    <main className="min-h-screen flex flex-col">
      <div className="bg-wallstreet-panel/70 backdrop-blur-md border-b border-wallstreet-border sticky top-0 z-40">
        <div className="px-4 sm:px-6 lg:px-8 py-3 sm:py-4 max-w-[1400px] mx-auto w-full flex items-center justify-between gap-4">
          <Link
            href="/"
            className="inline-flex items-center gap-2 text-sm text-gray-300 hover:text-gray-100 transition-colors"
          >
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="m15 18-6-6 6-6" />
            </svg>
            Piyasaya Dön
          </Link>
          <div className="flex items-center gap-2">
            <div className="w-2.5 h-2.5 rounded-full bg-neon-purple animate-pulse" />
            <h1 className="text-lg sm:text-xl font-black text-gray-100 tracking-tight">
              ADMİN PANELİ
            </h1>
            <span className="text-[10px] font-mono px-2 py-0.5 rounded bg-neon-purple/10 text-neon-purple border border-neon-purple/30">
              ROOT
            </span>
          </div>
          <div className="w-[100px]" />
        </div>
      </div>

      <div className="flex-1 px-4 sm:px-6 lg:px-8 py-6 sm:py-8 max-w-[1400px] mx-auto w-full grid grid-cols-1 lg:grid-cols-[1fr_420px] gap-6">
        <section>
          <form
            onSubmit={handleSubmit}
            className="bg-wallstreet-panel/60 backdrop-blur-sm border border-wallstreet-border rounded-2xl p-5 sm:p-6 shadow-panel space-y-5"
          >
            <div className="flex items-center gap-2 pb-4 border-b border-wallstreet-border">
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="#ffd700" strokeWidth="2">
                <path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" />
                <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0" />
              </svg>
              <h2 className="text-base sm:text-lg font-bold text-gray-100">
                Son Dakika Haberi Oluştur
              </h2>
              {submitted && (
                <span className="ml-auto text-xs font-mono text-neon-green animate-pulse-green inline-flex items-center gap-1">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3">
                    <polyline points="20 6 9 17 4 12" />
                  </svg>
                  GÖNDERİLDİ
                </span>
              )}
            </div>

            <div className="space-y-1.5">
              <label className="text-xs uppercase tracking-wider text-gray-400 font-semibold flex items-center gap-2">
                <span className="text-neon-red">●</span> Haber Başlığı
              </label>
              <textarea
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                required
                rows={3}
                placeholder="Örn: Deniz makroekonomiden FF aldı!"
                className="w-full bg-wallstreet-bg/70 border border-wallstreet-border focus:border-neon-blue/60 focus:ring-2 focus:ring-neon-blue/20 outline-none rounded-lg px-3.5 py-2.5 text-sm text-gray-100 placeholder-gray-600 resize-none transition-all"
              />
              <div className="flex items-center gap-2 flex-wrap">
                <button
                  type="button"
                  onClick={() => pickTemplate(true)}
                  className="text-[10px] sm:text-xs px-2.5 py-1 rounded-md bg-neon-green/10 text-neon-green/90 border border-neon-green/20 hover:bg-neon-green/20 transition-colors"
                >
                  + Pozitif Şablon
                </button>
                <button
                  type="button"
                  onClick={() => pickTemplate(false)}
                  className="text-[10px] sm:text-xs px-2.5 py-1 rounded-md bg-neon-red/10 text-neon-red/90 border border-neon-red/20 hover:bg-neon-red/20 transition-colors"
                >
                  − Negatif Şablon
                </button>
              </div>
            </div>

            <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
              <div className="space-y-1.5">
                <label className="text-xs uppercase tracking-wider text-gray-400 font-semibold">
                  Hedef Hisse
                </label>
                <select
                  value={targetStockId}
                  onChange={(e) => setTargetStockId(e.target.value)}
                  required
                  className="w-full bg-wallstreet-bg/70 border border-wallstreet-border focus:border-neon-blue/60 focus:ring-2 focus:ring-neon-blue/20 outline-none rounded-lg px-3.5 py-2.5 text-sm text-gray-100 transition-all appearance-none cursor-pointer"
                >
                  {stocks.map((s) => (
                    <option key={s.id} value={s.id}>
                      {s.symbol} — {s.name}
                    </option>
                  ))}
                </select>
              </div>

              <div className="space-y-1.5">
                <label className="text-xs uppercase tracking-wider text-gray-400 font-semibold">
                  Yazar (Opsiyonel)
                </label>
                <input
                  value={author}
                  onChange={(e) => setAuthor(e.target.value)}
                  placeholder="Admin"
                  className="w-full bg-wallstreet-bg/70 border border-wallstreet-border focus:border-neon-blue/60 focus:ring-2 focus:ring-neon-blue/20 outline-none rounded-lg px-3.5 py-2.5 text-sm text-gray-100 placeholder-gray-600 transition-all"
                />
              </div>
            </div>

            <div className="space-y-2">
              <div className="flex items-center justify-between">
                <label className="text-xs uppercase tracking-wider text-gray-400 font-semibold">
                  Etki Yüzdesi
                </label>
                <span
                  className={`font-mono text-sm font-black ${
                    impactPercent >= 0 ? "text-neon-green" : "text-neon-red"
                  }`}
                >
                  {impactPercent >= 0 ? "+" : ""}
                  {impactPercent}%
                </span>
              </div>
              <input
                type="range"
                min={-50}
                max={50}
                step={1}
                value={impactPercent}
                onChange={(e) => setImpactPercent(Number(e.target.value))}
                className="w-full accent-neon-blue h-2 bg-wallstreet-bg rounded-lg appearance-none cursor-pointer"
                style={{
                  background: `linear-gradient(to right, #ff3b5c ${50 - Math.abs(impactPercent)}%, ${
                    impactPercent >= 0 ? "#00ff88" : "#ff3b5c"
                  } ${50 + Math.abs(impactPercent) / 2}%, #374151 ${50 + Math.abs(impactPercent) / 2}%)`,
                }}
              />
              <div className="flex flex-wrap gap-1.5 pt-1">
                {QUICK_IMPACTS.map((imp) => (
                  <button
                    type="button"
                    key={imp.value}
                    onClick={() => setImpactPercent(imp.value)}
                    className={`text-[10px] sm:text-xs font-mono font-bold px-2 py-1 rounded-md border transition-all ${
                      impactPercent === imp.value
                        ? "scale-105"
                        : "opacity-70 hover:opacity-100"
                    }`}
                    style={{
                      background: `${imp.color}15`,
                      color: imp.color,
                      borderColor: `${imp.color}55`,
                      boxShadow:
                        impactPercent === imp.value ? `0 0 12px ${imp.color}33` : "none",
                    }}
                  >
                    {imp.label}
                  </button>
                ))}
              </div>
            </div>

            <button
              type="submit"
              className="w-full group relative overflow-hidden inline-flex items-center justify-center gap-2 px-6 py-3 rounded-xl bg-gradient-to-r from-neon-purple/80 via-neon-blue/80 to-neon-green/80 hover:from-neon-purple hover:via-neon-blue hover:to-neon-green text-white font-bold text-sm sm:text-base shadow-lg hover:shadow-neon-blue/30 transition-all active:scale-[0.98]"
            >
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                <path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9" />
                <path d="M10.3 21a1.94 1.94 0 0 0 3.4 0" />
              </svg>
              Haberi Yayınla & Fiyatı Güncelle
            </button>

            {lastNews && (
              <div className="text-center text-[11px] font-mono text-gray-500 pt-1 border-t border-wallstreet-border">
                Son: <span className="text-gray-300">{lastNews}</span>
              </div>
            )}
          </form>
        </section>

        <aside className="lg:sticky lg:top-[110px] lg:self-start space-y-5">
          <div className="bg-wallstreet-panel/60 backdrop-blur-sm border border-wallstreet-border rounded-2xl p-4 sm:p-5">
            <h3 className="text-sm font-bold text-gray-100 mb-3 flex items-center gap-2">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#00d4ff" strokeWidth="2">
                <circle cx="12" cy="12" r="10" />
                <line x1="12" y1="16" x2="12" y2="12" />
                <line x1="12" y1="8" x2="12.01" y2="8" />
              </svg>
              Nasıl Çalışır?
            </h3>
            <ol className="space-y-2.5 text-xs text-gray-400">
              <li className="flex gap-2">
                <span className="w-5 h-5 shrink-0 rounded-full bg-neon-blue/15 border border-neon-blue/30 text-neon-blue text-[10px] font-bold flex items-center justify-center">1</span>
                <span>Bir başlık yazın veya hazır şablonlardan seçin</span>
              </li>
              <li className="flex gap-2">
                <span className="w-5 h-5 shrink-0 rounded-full bg-neon-blue/15 border border-neon-blue/30 text-neon-blue text-[10px] font-bold flex items-center justify-center">2</span>
                <span>Etkilenecek hisseyi seçin</span>
              </li>
              <li className="flex gap-2">
                <span className="w-5 h-5 shrink-0 rounded-full bg-neon-blue/15 border border-neon-blue/30 text-neon-blue text-[10px] font-bold flex items-center justify-center">3</span>
                <span>Etki yüzdesini belirleyin (+/−)</span>
              </li>
              <li className="flex gap-2">
                <span className="w-5 h-5 shrink-0 rounded-full bg-neon-green/15 border border-neon-green/30 text-neon-green text-[10px] font-bold flex items-center justify-center">✓</span>
                <span>Haber canlı akışa düşer, hisse fiyatı otomatik güncellenir</span>
              </li>
            </ol>
          </div>

          <div className="bg-wallstreet-panel/60 backdrop-blur-sm border border-wallstreet-border rounded-2xl overflow-hidden">
            <div className="px-4 py-3 border-b border-wallstreet-border flex items-center justify-between">
              <h3 className="text-sm font-bold text-gray-100">Son Haberler</h3>
              <span className="text-[10px] font-mono text-gray-500">{news.length} adet</span>
            </div>
            <ul className="max-h-[400px] overflow-y-auto scrollbar-thin divide-y divide-wallstreet-border/60">
              {news.slice(0, 15).map((n) => {
                const stock = stocks.find((s) => s.id === n.targetStockId);
                const pos = n.impactPercent >= 0;
                return (
                  <li key={n.id} className="p-3 hover:bg-wallstreet-bg/40 transition-colors">
                    <p className="text-xs text-gray-300 leading-snug mb-1.5 line-clamp-2">{n.title}</p>
                    <div className="flex items-center justify-between gap-2 text-[10px]">
                      <span
                        className="font-mono font-bold px-1.5 py-0.5 rounded"
                        style={stock ? { background: `${stock.avatarColor}22`, color: stock.avatarColor } : undefined}
                      >
                        {stock?.symbol}
                      </span>
                      <span
                        className={`font-mono font-bold px-1.5 py-0.5 rounded ${
                          pos ? "bg-neon-green/10 text-neon-green" : "bg-neon-red/10 text-neon-red"
                        }`}
                      >
                        {pos ? "+" : ""}{n.impactPercent}%
                      </span>
                    </div>
                  </li>
                );
              })}
              {news.length === 0 && (
                <li className="p-6 text-center text-xs text-gray-500">Henüz haber yok</li>
              )}
            </ul>
          </div>
        </aside>
      </div>
    </main>
  );
}
