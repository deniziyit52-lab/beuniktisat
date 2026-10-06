"use client";

import { useMarket } from "@/context/MarketContext";
import { Stock } from "@/types";
import {
  ResponsiveContainer,
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  Area,
  AreaChart,
} from "recharts";
import { useEffect } from "react";

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

function formatVolume(v: number): string {
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(2)}M`;
  if (v >= 1_000) return `${(v / 1_000).toFixed(1)}K`;
  return v.toString();
}

function formatMCap(m: number): string {
  const tryFmt = (n: number, fractionDigits: number = 2) =>
    new Intl.NumberFormat("tr-TR", {
      style: "currency",
      currency: "TRY",
      minimumFractionDigits: fractionDigits,
      maximumFractionDigits: fractionDigits,
    }).format(n);
  if (m >= 1_000_000_000) return `${tryFmt(m / 1_000_000_000)}B`;
  if (m >= 1_000_000) return `${tryFmt(m / 1_000_000)}M`;
  return tryFmt(m, 0);
}

interface CustomTooltipProps {
  active?: boolean;
  payload?: Array<{ value: number; payload: { time: string } }>;
  label?: string;
  color: string;
}

function CustomTooltip({ active, payload, color }: CustomTooltipProps) {
  if (active && payload && payload.length) {
    return (
      <div className="bg-wallstreet-bg border border-wallstreet-border rounded-lg px-3 py-2 shadow-panel">
        <p className="text-xs text-gray-400 font-mono mb-1">
          {payload[0].payload.time}
        </p>
        <p className="font-mono font-bold text-sm" style={{ color }}>
          {formatPrice(payload[0].value)}
        </p>
      </div>
    );
  }
  return null;
}

export function StockDetailModal() {
  const {
    selectedStockId,
    setSelectedStockId,
    getStockById,
    news,
  } = useMarket();

  const stock = selectedStockId ? getStockById(selectedStockId) : undefined;
  const { value: diff, percent } = stock ? getChange(stock) : { value: 0, percent: 0 };
  const isUp = percent >= 0;
  const chartColor = isUp ? "#00ff88" : "#ff3b5c";

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setSelectedStockId(null);
    }
    if (selectedStockId) {
      document.addEventListener("keydown", onKey);
      document.body.style.overflow = "hidden";
    }
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = "";
    };
  }, [selectedStockId, setSelectedStockId]);

  if (!stock) return null;

  const relatedNews = news
    .filter((n) => n.targetStockId === stock.id)
    .slice(0, 5);

  const firstPrice = stock.priceHistory[0]?.price ?? stock.openPrice;
  const lastPrice = stock.currentPrice;
  const minPrice = Math.min(...stock.priceHistory.map((p) => p.price), stock.dayLow);
  const maxPrice = Math.max(...stock.priceHistory.map((p) => p.price), stock.dayHigh);
  const shortFmt = (v: number) =>
    new Intl.NumberFormat("tr-TR", {
      style: "currency",
      currency: "TRY",
      minimumFractionDigits: 0,
      maximumFractionDigits: 0,
    }).format(v);

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4 sm:p-6"
      onClick={() => setSelectedStockId(null)}
    >
      <div className="absolute inset-0 bg-black/70 backdrop-blur-sm" />

      <div
        className="relative w-full max-w-5xl max-h-[92vh] overflow-hidden rounded-2xl bg-wallstreet-panel border border-wallstreet-border shadow-2xl flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        <div
          className="absolute inset-x-0 top-0 h-1"
          style={{
            background: `linear-gradient(90deg, transparent, ${stock.avatarColor}, transparent)`,
          }}
        />

        <div className="flex flex-wrap items-start gap-3 p-4 sm:flex-nowrap sm:gap-4 sm:p-6 border-b border-wallstreet-border bg-wallstreet-bg/40">
          <div className="flex min-w-0 flex-1 basis-[calc(100%-3rem)] items-start gap-3 sm:basis-auto sm:gap-4">
            <div
              className="w-12 h-12 sm:w-16 sm:h-16 rounded-full flex items-center justify-center font-bold text-2xl sm:text-3xl shrink-0"
              style={{
                background: `linear-gradient(135deg, ${stock.avatarColor}33, ${stock.avatarColor}55)`,
                color: stock.avatarColor,
                border: `2px solid ${stock.avatarColor}77`,
                boxShadow: `0 0 24px ${stock.avatarColor}33`,
              }}
            >
              {stock.name.charAt(0)}
            </div>
            <div className="min-w-0">
              <div className="flex items-center gap-2 flex-wrap mb-1">
                <h2 className="text-lg sm:text-2xl font-bold text-gray-50 truncate">
                  {stock.name}
                </h2>
                <span
                  className="font-mono text-[10px] sm:text-xs font-bold px-2 py-0.5 rounded shrink-0"
                  style={{
                    background: `${stock.avatarColor}22`,
                    color: stock.avatarColor,
                    border: `1px solid ${stock.avatarColor}44`,
                  }}
                >
                  {stock.symbol}
                </span>
              </div>
              <p className="text-xs sm:text-sm text-gray-500 truncate">
                {stock.fullName} · {stock.sector}
              </p>
            </div>
          </div>

          <button
            onClick={() => setSelectedStockId(null)}
            className="order-2 shrink-0 w-9 h-9 rounded-lg bg-wallstreet-bg/60 hover:bg-wallstreet-bg border border-wallstreet-border text-gray-400 hover:text-gray-200 transition-colors flex items-center justify-center sm:order-3"
            aria-label="Kapat"
          >
            <svg
              width="18"
              height="18"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
            >
              <line x1="18" y1="6" x2="6" y2="18" />
              <line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>

          <div className="order-3 flex w-full min-w-0 flex-wrap items-baseline gap-x-3 gap-y-1 sm:order-2 sm:ml-auto sm:w-auto sm:flex-col sm:items-end sm:gap-0">
            <span className="break-words font-mono text-2xl sm:text-4xl font-black text-gray-50">
              {formatPrice(stock.currentPrice)}
            </span>
            <span
              className={`font-mono text-sm sm:text-base font-bold ${
                isUp ? "text-neon-green animate-glow-green" : "text-neon-red animate-glow-red"
              }`}
            >
              {isUp ? "▲" : "▼"} {isUp ? "+" : ""}
              {diff.toFixed(2)} ({isUp ? "+" : ""}
              {percent.toFixed(2)}%)
            </span>
          </div>
        </div>

        <div className="overflow-y-auto scrollbar-thin flex-1 p-5 sm:p-6 space-y-6">
          <div className="h-64 sm:h-80 rounded-xl bg-wallstreet-bg/40 border border-wallstreet-border p-2 sm:p-4">
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={stock.priceHistory} margin={{ top: 10, right: 10, left: 0, bottom: 0 }}>
                <defs>
                  <linearGradient id="colorPrice" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor={chartColor} stopOpacity={0.35} />
                    <stop offset="100%" stopColor={chartColor} stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke="#1f2937" vertical={false} />
                <XAxis
                  dataKey="time"
                  stroke="#4b5563"
                  tick={{ fill: "#6b7280", fontSize: 10, fontFamily: "monospace" }}
                  tickLine={false}
                  axisLine={{ stroke: "#1f2937" }}
                  interval="preserveStartEnd"
                  minTickGap={40}
                />
                <YAxis
                  stroke="#4b5563"
                  tick={{ fill: "#6b7280", fontSize: 10, fontFamily: "monospace" }}
                  tickLine={false}
                  axisLine={{ stroke: "#1f2937" }}
                  domain={[Math.floor(minPrice * 0.995), Math.ceil(maxPrice * 1.005)]}
                  width={60}
                  tickFormatter={(v) => shortFmt(v)}
                />
                <Tooltip
                  content={<CustomTooltip color={chartColor} />}
                  cursor={{ stroke: chartColor, strokeDasharray: "4 4", strokeWidth: 1 }}
                />
                <Area
                  type="monotone"
                  dataKey="price"
                  stroke={chartColor}
                  strokeWidth={2}
                  fill="url(#colorPrice)"
                  dot={false}
                  activeDot={{
                    r: 5,
                    fill: "#0a0e17",
                    stroke: chartColor,
                    strokeWidth: 2,
                  }}
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>

          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            {[
              { label: "Açılış", value: formatPrice(stock.openPrice) },
              { label: "Önceki Kapanış", value: formatPrice(stock.previousClose) },
              { label: "Gün Yüksek", value: formatPrice(stock.dayHigh), accent: "#00ff88" },
              { label: "Gün Düşük", value: formatPrice(stock.dayLow), accent: "#ff3b5c" },
              { label: "Hacim", value: formatVolume(stock.volume) },
              { label: "Piyasa Değeri", value: formatMCap(stock.marketCap) },
              { label: "Grafik Başlangıç", value: formatPrice(firstPrice) },
              { label: "Son Fiyat", value: formatPrice(lastPrice), accent: chartColor },
            ].map((stat) => (
              <div
                key={stat.label}
                className="rounded-lg bg-wallstreet-bg/40 border border-wallstreet-border p-3"
              >
                <div className="text-[10px] uppercase tracking-wider text-gray-500 mb-1">
                  {stat.label}
                </div>
                <div
                  className="font-mono font-bold text-gray-200 text-sm sm:text-base"
                  style={stat.accent ? { color: stat.accent } : undefined}
                >
                  {stat.value}
                </div>
              </div>
            ))}
          </div>

          {relatedNews.length > 0 && (
            <div>
              <h3 className="text-sm font-bold text-gray-200 mb-3 flex items-center gap-2">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-neon-yellow">
                  <path d="M4 22h16a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v16a2 2 0 0 1-2 2Zm0 0a2 2 0 0 1-2-2v-9c0-1.1.9-2 2-2h2" />
                  <path d="M18 14h-8" />
                  <path d="M15 18h-5" />
                  <path d="M10 6h8v4h-8V6Z" />
                </svg>
                İlgili Haberler
              </h3>
              <ul className="space-y-2">
                {relatedNews.map((n) => {
                  const pos = n.impactPercent >= 0;
                  return (
                    <li
                      key={n.id}
                      className="flex items-start gap-3 p-3 rounded-lg bg-wallstreet-bg/40 border border-wallstreet-border"
                    >
                      <span
                        className={`font-mono text-[10px] font-bold px-1.5 py-0.5 rounded shrink-0 mt-0.5 ${
                          pos
                            ? "bg-neon-green/10 text-neon-green border border-neon-green/20"
                            : "bg-neon-red/10 text-neon-red border border-neon-red/20"
                        }`}
                      >
                        {pos ? "+" : ""}
                        {n.impactPercent.toFixed(1)}%
                      </span>
                      <div className="flex-1 min-w-0">
                        <p className="text-sm text-gray-300 leading-snug">{n.title}</p>
                        <p className="text-[10px] text-gray-500 mt-1 font-mono">
                          {new Date(n.timestamp).toLocaleString("tr-TR")}
                        </p>
                      </div>
                    </li>
                  );
                })}
              </ul>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
