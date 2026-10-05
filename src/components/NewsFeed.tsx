"use client";

import { useMarket } from "@/context/MarketContext";

function timeAgo(timestamp: number): string {
  const diff = Date.now() - timestamp;
  const mins = Math.floor(diff / 60000);
  if (mins < 1) return "şimdi";
  if (mins < 60) return `${mins} dk önce`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours} saat önce`;
  const days = Math.floor(hours / 24);
  return `${days} gün önce`;
}

export function NewsFeed() {
  const { news, getStockById, setSelectedStockId } = useMarket();

  return (
    <div className="bg-wallstreet-panel/60 backdrop-blur-sm border border-wallstreet-border rounded-xl overflow-hidden h-full flex flex-col">
      <div className="px-4 py-3 border-b border-wallstreet-border flex items-center justify-between bg-wallstreet-bg/40">
        <div className="flex items-center gap-2">
          <div className="w-2.5 h-2.5 rounded-full bg-neon-red animate-pulse-red" />
          <h2 className="font-bold text-gray-100 text-sm sm:text-base">
            Canlı Haber Beslemesi
          </h2>
        </div>
        <span className="text-[10px] text-gray-500 font-mono px-2 py-0.5 bg-wallstreet-bg/80 rounded border border-wallstreet-border">
          LIVE
        </span>
      </div>

      <div className="flex-1 overflow-y-auto scrollbar-thin max-h-[600px] xl:max-h-none">
        {news.length === 0 ? (
          <div className="p-8 text-center text-gray-500 text-sm">
            Henüz haber yok.
          </div>
        ) : (
          <ul className="divide-y divide-wallstreet-border/60">
            {news.map((item) => {
              const stock = getStockById(item.targetStockId);
              const isPositive = item.impactPercent >= 0;

              return (
                <li
                  key={item.id}
                  className="p-4 hover:bg-wallstreet-bg/50 transition-colors group"
                >
                  <div className="flex items-start gap-3">
                    <div className="shrink-0 mt-0.5">
                      {isPositive ? (
                        <div className="w-7 h-7 rounded-full flex items-center justify-center bg-neon-green/10 border border-neon-green/30">
                          <span className="text-neon-green text-xs font-bold">
                            ▲
                          </span>
                        </div>
                      ) : (
                        <div className="w-7 h-7 rounded-full flex items-center justify-center bg-neon-red/10 border border-neon-red/30">
                          <span className="text-neon-red text-xs font-bold">
                            ▼
                          </span>
                        </div>
                      )}
                    </div>

                    <div className="flex-1 min-w-0">
                      <p className="text-sm text-gray-200 leading-snug mb-2 group-hover:text-gray-100 transition-colors">
                        {item.title}
                      </p>

                      <div className="flex items-center justify-between gap-2 flex-wrap">
                        <button
                          onClick={() =>
                            stock && setSelectedStockId(stock.id)
                          }
                          className="inline-flex items-center gap-1.5"
                        >
                          {stock && (
                            <>
                              <span
                                className="font-mono text-[10px] font-bold px-1.5 py-0.5 rounded"
                                style={{
                                  background: `${stock.avatarColor}22`,
                                  color: stock.avatarColor,
                                }}
                              >
                                {stock.symbol}
                              </span>
                              <span className="text-xs text-gray-500 hover:text-gray-300 transition-colors">
                                {stock.name}
                              </span>
                            </>
                          )}
                        </button>

                        <div className="flex items-center gap-2">
                          <span
                            className={`font-mono text-[11px] font-bold px-1.5 py-0.5 rounded ${
                              isPositive
                                ? "bg-neon-green/10 text-neon-green"
                                : "bg-neon-red/10 text-neon-red"
                            }`}
                          >
                            {isPositive ? "+" : ""}
                            {item.impactPercent.toFixed(1)}%
                          </span>
                          <span className="text-[10px] text-gray-500 font-mono">
                            {timeAgo(item.timestamp)}
                          </span>
                        </div>
                      </div>
                    </div>
                  </div>
                </li>
              );
            })}
          </ul>
        )}
      </div>
    </div>
  );
}
