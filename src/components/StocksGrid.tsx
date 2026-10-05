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

function Avatar({ color, name }: { color: string; name: string }) {
  const initial = name.charAt(0);
  return (
    <div
      className="w-11 h-11 rounded-full flex items-center justify-center font-bold text-lg shrink-0"
      style={{
        background: `linear-gradient(135deg, ${color}22, ${color}44)`,
        color: color,
        border: `2px solid ${color}55`,
        boxShadow: `0 0 12px ${color}22`,
      }}
    >
      {initial}
    </div>
  );
}

function Sparkline({
  data,
  color,
}: {
  data: { price: number; time: string }[];
  color: string;
}) {
  if (data.length < 2) return null;
  const prices = data.map((d) => d.price);
  const min = Math.min(...prices);
  const max = Math.max(...prices);
  const range = max - min || 1;
  const w = 100;
  const h = 36;

  const points = data
    .map((d, i) => {
      const x = (i / (data.length - 1)) * w;
      const y = h - ((d.price - min) / range) * (h - 4) - 2;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(" ");

  const isUp = prices[prices.length - 1] >= prices[0];
  const strokeColor = color;

  const areaPath = `M 0,${h} L ${points
    .split(" ")
    .map((p) => p)
    .join(" L ")} L ${w},${h} Z`;

  return (
    <svg
      width={w}
      height={h}
      viewBox={`0 0 ${w} ${h}`}
      className="overflow-visible"
      preserveAspectRatio="none"
    >
      <defs>
        <linearGradient id={`grad-${color}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={strokeColor} stopOpacity="0.35" />
          <stop offset="100%" stopColor={strokeColor} stopOpacity="0" />
        </linearGradient>
      </defs>
      <path
        d={areaPath}
        fill={`url(#grad-${color})`}
        style={{ pointerEvents: "none" }}
      />
      <polyline
        points={points}
        fill="none"
        stroke={strokeColor}
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function StocksGrid() {
  const { stocks, setSelectedStockId } = useMarket();

  const sorted = [...stocks].sort((a, b) => b.marketCap - a.marketCap);

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-4">
      {sorted.map((stock) => {
        const { value, percent } = getChange(stock);
        const isUp = percent >= 0;
        const changeColor = isUp ? "#00ff88" : "#ff3b5c";

        return (
          <button
            key={stock.id}
            onClick={() => setSelectedStockId(stock.id)}
            className={`text-left group bg-wallstreet-panel/60 backdrop-blur-sm border border-wallstreet-border rounded-xl p-4 transition-all duration-300 hover:-translate-y-1 hover:border-opacity-100 ${
              isUp ? "hover:shadow-neon-green" : "hover:shadow-neon-red"
            }`}
            style={{
              borderColor: isUp ? `${changeColor}33` : `${changeColor}33`,
            }}
          >
            <div className="flex items-start gap-3 mb-3">
              <Avatar color={stock.avatarColor} name={stock.name} />
              <div className="flex-1 min-w-0">
                <div className="flex items-center gap-2 mb-0.5">
                  <h3 className="font-bold text-gray-100 truncate text-sm sm:text-base">
                    {stock.name}
                  </h3>
                </div>
                <div className="flex items-center gap-2">
                  <span
                    className="font-mono text-[10px] sm:text-xs font-bold px-1.5 py-0.5 rounded"
                    style={{
                      background: `${stock.avatarColor}22`,
                      color: stock.avatarColor,
                    }}
                  >
                    {stock.symbol}
                  </span>
                  <span className="text-[10px] sm:text-xs text-gray-500 truncate">
                    {stock.sector}
                  </span>
                </div>
              </div>
            </div>

            <div className="flex items-end justify-between gap-2 mb-3">
              <div>
                <div className="font-mono text-xl sm:text-2xl font-bold text-gray-50">
                  {formatPrice(stock.currentPrice)}
                </div>
                <div
                  className={`font-mono text-xs sm:text-sm font-semibold mt-1 ${
                    isUp ? "text-neon-green" : "text-neon-red"
                  }`}
                >
                  {isUp ? "▲" : "▼"} {isUp ? "+" : ""}
                  {value.toFixed(2)} ({isUp ? "+" : ""}
                  {percent.toFixed(2)}%)
                </div>
              </div>
              <div className="shrink-0">
                <Sparkline
                  data={stock.priceHistory.slice(-24)}
                  color={changeColor}
                />
              </div>
            </div>

            <div className="grid grid-cols-3 gap-2 pt-3 border-t border-wallstreet-border text-xs">
              <div>
                <div className="text-gray-500 text-[10px] uppercase tracking-wider mb-0.5">
                  Yüksek
                </div>
                <div className="font-mono font-semibold text-gray-300">
                  {formatPrice(stock.dayHigh)}
                </div>
              </div>
              <div>
                <div className="text-gray-500 text-[10px] uppercase tracking-wider mb-0.5">
                  Düşük
                </div>
                <div className="font-mono font-semibold text-gray-300">
                  {formatPrice(stock.dayLow)}
                </div>
              </div>
              <div>
                <div className="text-gray-500 text-[10px] uppercase tracking-wider mb-0.5">
                  Hacim
                </div>
                <div className="font-mono font-semibold text-gray-300">
                  {(stock.volume / 1_000_000).toFixed(2)}M
                </div>
              </div>
            </div>
          </button>
        );
      })}
    </div>
  );
}
