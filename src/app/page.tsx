"use client";

import { StockTicker } from "@/components/StockTicker";
import { StocksGrid } from "@/components/StocksGrid";
import { StockDetailModal } from "@/components/StockDetailModal";
import { Header } from "@/components/Header";
import { NewsAccessButton } from "@/components/NewsAccessButton";
import { useMarket } from "@/context/MarketContext";

export default function HomePage() {
  const { stocks, news } = useMarket();

  return (
    <main className="min-h-screen flex flex-col">
      <Header />
      <NewsAccessButton />
      <StockTicker />

      <div className="flex-1 px-4 sm:px-6 lg:px-8 py-5 sm:py-8 max-w-[1600px] mx-auto w-full">
        <div className="mb-6 flex flex-col sm:flex-row sm:items-end sm:justify-between gap-3">
          <div>
            <h2 className="text-xl sm:text-2xl font-black text-gray-100 flex items-center gap-2">
              <span className="w-1 h-6 bg-neon-green rounded-full" />
              Piyasa Genel Görünümü
            </h2>
            <p className="text-sm text-gray-500 mt-1">
              {stocks.length} hisse · Arşivde {news.length} haber
            </p>
          </div>
          <div className="flex items-center gap-2 text-xs text-gray-500">
            <span className="inline-flex items-center gap-1.5 px-2.5 py-1 bg-wallstreet-panel/60 rounded-md border border-wallstreet-border font-mono">
              <span className="w-1.5 h-1.5 rounded-full bg-neon-green animate-pulse-green" />
              Canlı Veri
            </span>
            <span className="hidden sm:inline px-2.5 py-1 bg-wallstreet-panel/60 rounded-md border border-wallstreet-border font-mono">
              LocalStorage
            </span>
          </div>
        </div>

        <div>
          <StocksGrid />
        </div>
      </div>

      <footer className="border-t border-wallstreet-border bg-wallstreet-panel/50 mt-8">
        <div className="px-4 sm:px-6 lg:px-8 py-4 flex flex-col sm:flex-row items-center justify-between gap-2 max-w-[1600px] mx-auto w-full">
          <p className="text-xs text-gray-500 font-mono">
            © {new Date().getFullYear()} Ekonomi Kulübü Borsa Simülasyonu · Eğitim Amaçlıdır
          </p>
          <div className="flex items-center gap-4 text-[10px] text-gray-600 font-mono">
            <span>VERILER GERCEK DEGILDIR</span>
            <span>·</span>
            <span>Made with ♥ for Economics Club</span>
          </div>
        </div>
      </footer>

      <StockDetailModal />
    </main>
  );
}
