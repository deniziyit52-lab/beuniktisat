"use client";

import { useMarket } from "@/context/MarketContext";
import Link from "next/link";

export function Header() {
  const { stocks, resetMarket } = useMarket();

  const gainers = [...stocks]
    .sort((a, b) => {
      const pa = ((a.currentPrice - a.previousClose) / a.previousClose) * 100;
      const pb = ((b.currentPrice - b.previousClose) / b.previousClose) * 100;
      return pb - pa;
    })
    .slice(0, 3);

  const topGainer = gainers[0];
  const topLoser = [...stocks].sort((a, b) => {
    const pa = ((a.currentPrice - a.previousClose) / a.previousClose) * 100;
    const pb = ((b.currentPrice - b.previousClose) / b.previousClose) * 100;
    return pa - pb;
  })[0];

  const totalCap = stocks.reduce((acc, s) => acc + s.marketCap, 0);
  const avgChange =
    stocks.reduce(
      (acc, s) => acc + ((s.currentPrice - s.previousClose) / s.previousClose) * 100,
      0
    ) / stocks.length;

  const clock = new Date().toLocaleTimeString("tr-TR", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });

  return (
    <header className="bg-wallstreet-panel/70 backdrop-blur-md border-b border-wallstreet-border sticky top-0 z-40">
      <div className="px-4 sm:px-6 lg:px-8">
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-3 py-3 sm:py-4">
          <div className="flex items-center justify-between lg:justify-start gap-4">
            <div className="flex items-center gap-3">
              <div className="relative w-10 h-10 sm:w-11 sm:h-11 rounded-xl flex items-center justify-center bg-gradient-to-br from-neon-green/20 to-neon-blue/20 border border-neon-green/30">
                <svg
                  width="22"
                  height="22"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="#00ff88"
                  strokeWidth="2.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                >
                  <polyline points="22 7 13.5 15.5 8.5 10.5 2 17" />
                  <polyline points="16 7 22 7 22 13" />
                </svg>
                <div className="absolute inset-0 rounded-xl animate-pulse-green opacity-30 bg-neon-green/20" />
              </div>
              <div>
                <h1 className="text-lg sm:text-xl font-black tracking-tight bg-gradient-to-r from-gray-50 via-neon-green/80 to-neon-blue/80 bg-clip-text text-transparent">
                  EKONOMİ KULÜBÜ BORSA
                </h1>
                <p className="text-[10px] sm:text-xs text-gray-500 font-mono tracking-wider">
                  SIMULATION EXCHANGE · v1.0
                </p>
              </div>
            </div>

            <div className="hidden sm:flex items-center gap-2 px-3 py-1.5 bg-wallstreet-bg/60 rounded-lg border border-wallstreet-border">
              <div className="w-2 h-2 rounded-full bg-neon-green animate-pulse-green" />
              <span className="font-mono text-xs text-gray-400">
                Piyasa Açık · <span className="text-gray-200">{clock}</span>
              </span>
            </div>
          </div>

          <div className="flex items-center gap-2 sm:gap-3 overflow-x-auto scrollbar-thin pb-1 lg:pb-0 -mx-1 px-1">
            <div className="shrink-0 px-3 py-2 bg-wallstreet-bg/60 rounded-lg border border-wallstreet-border">
              <div className="text-[9px] sm:text-[10px] uppercase tracking-wider text-gray-500 mb-0.5">
                Toplam Piyasa
              </div>
              <div className="font-mono text-sm sm:text-base font-bold text-gray-200">
                {new Intl.NumberFormat("tr-TR", {
                  style: "currency",
                  currency: "TRY",
                  minimumFractionDigits: 2,
                  maximumFractionDigits: 2,
                }).format(totalCap / 1_000_000)}M
              </div>
            </div>

            <div className="shrink-0 px-3 py-2 bg-wallstreet-bg/60 rounded-lg border border-wallstreet-border">
              <div className="text-[9px] sm:text-[10px] uppercase tracking-wider text-gray-500 mb-0.5">
                Genel Ort.
              </div>
              <div
                className={`font-mono text-sm sm:text-base font-bold ${
                  avgChange >= 0 ? "text-neon-green" : "text-neon-red"
                }`}
              >
                {avgChange >= 0 ? "+" : ""}
                {avgChange.toFixed(2)}%
              </div>
            </div>

            {topGainer && (
              <div
                className="shrink-0 px-3 py-2 bg-neon-green/5 rounded-lg border border-neon-green/20"
                style={{ boxShadow: "inset 0 0 20px rgba(0,255,136,0.05)" }}
              >
                <div className="text-[9px] sm:text-[10px] uppercase tracking-wider text-neon-green/70 mb-0.5">
                  En Çok Kazandıran
                </div>
                <div className="flex items-center gap-1.5">
                  <span
                    className="font-mono text-xs font-bold"
                    style={{ color: topGainer.avatarColor }}
                  >
                    {topGainer.symbol}
                  </span>
                  <span className="font-mono text-xs sm:text-sm font-bold text-neon-green">
                    +
                    {(
                      ((topGainer.currentPrice - topGainer.previousClose) /
                        topGainer.previousClose) *
                      100
                    ).toFixed(2)}
                    %
                  </span>
                </div>
              </div>
            )}

            {topLoser && (
              <div
                className="shrink-0 px-3 py-2 bg-neon-red/5 rounded-lg border border-neon-red/20"
                style={{ boxShadow: "inset 0 0 20px rgba(255,59,92,0.05)" }}
              >
                <div className="text-[9px] sm:text-[10px] uppercase tracking-wider text-neon-red/70 mb-0.5">
                  En Çok Kaybeden
                </div>
                <div className="flex items-center gap-1.5">
                  <span
                    className="font-mono text-xs font-bold"
                    style={{ color: topLoser.avatarColor }}
                  >
                    {topLoser.symbol}
                  </span>
                  <span className="font-mono text-xs sm:text-sm font-bold text-neon-red">
                    {(
                      ((topLoser.currentPrice - topLoser.previousClose) /
                        topLoser.previousClose) *
                      100
                    ).toFixed(2)}
                    %
                  </span>
                </div>
              </div>
            )}

            <Link
              href="/admin"
              className="shrink-0 inline-flex items-center gap-1.5 px-3 py-2 bg-wallstreet-bg/60 hover:bg-wallstreet-border/40 rounded-lg border border-wallstreet-border text-xs text-gray-300 hover:text-gray-100 transition-colors"
            >
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M12 20h9" />
                <path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4Z" />
              </svg>
              <span className="hidden sm:inline">Admin</span>
            </Link>

            <button
              onClick={resetMarket}
              className="shrink-0 inline-flex items-center gap-1.5 px-3 py-2 bg-wallstreet-bg/60 hover:bg-neon-red/10 rounded-lg border border-wallstreet-border hover:border-neon-red/30 text-xs text-gray-400 hover:text-neon-red transition-colors"
              title="Piyasayı sıfırla"
            >
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" />
                <path d="M3 3v5h5" />
              </svg>
            </button>
          </div>
        </div>
      </div>
    </header>
  );
}
