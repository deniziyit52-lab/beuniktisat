"use client";

import { useMarket } from "@/context/MarketContext";
import { Stock } from "@/types";

function formatPrice(p: number): string {
  return new Intl.NumberFormat("tr-TR", {
    style: "currency",
    currency: "TRY",
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(p);
}

function getChange(stock: Stock): { value: number; percent: number } {
  const diff = stock.currentPrice - stock.previousClose;
  const percent = (diff / stock.previousClose) * 100;
  return { value: diff, percent };
}

export function StockTicker() {
  const { stocks } = useMarket();
  const doubled = [...stocks, ...stocks];

  return (
    <div className="w-full bg-wallstreet-panel border-y border-wallstreet-border overflow-hidden py-2 relative">
      <div className="absolute left-0 top-0 bottom-0 w-20 z-10 bg-gradient-to-r from-wallstreet-panel to-transparent pointer-events-none" />
      <div className="absolute right-0 top-0 bottom-0 w-20 z-10 bg-gradient-to-l from-wallstreet-panel to-transparent pointer-events-none" />

      <div className="flex whitespace-nowrap will-change-transform animate-ticker-scroll">
        {doubled.map((stock, idx) => {
          const { percent } = getChange(stock);
          const isUp = percent >= 0;
          return (
            <div
              key={`${stock.id}-${idx}`}
              className="flex items-center gap-3 px-6 border-r border-wallstreet-border/40 shrink-0"
            >
              <span
                className="font-mono text-xs font-bold tracking-wider px-2 py-0.5 rounded"
                style={{ color: stock.avatarColor }}
              >
                {stock.symbol}
              </span>
              <span className="font-mono text-sm font-semibold text-gray-200">
                {formatPrice(stock.currentPrice)}
              </span>
              <span
                className={`font-mono text-xs font-bold flex items-center gap-0.5 ${
                  isUp ? "text-neon-green animate-pulse-green" : "text-neon-red animate-pulse-red"
                }`}
              >
                {isUp ? "▲" : "▼"}
                {isUp ? "+" : ""}
                {percent.toFixed(2)}%
              </span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
