"use client";

import React, {
  createContext,
  useContext,
  useState,
  useEffect,
  useCallback,
  useMemo,
} from "react";
import { Stock, NewsItem, MarketState, PricePoint } from "@/types";
import { supabase } from "@/lib/supabase";

interface MarketContextType extends MarketState {
  addNews: (news: Omit<NewsItem, "id" | "timestamp">) => Promise<void>;
  getStockById: (id: string) => Stock | undefined;
  resetMarket: () => void;
  selectedStockId: string | null;
  setSelectedStockId: (id: string | null) => void;
}

const MarketContext = createContext<MarketContextType | undefined>(undefined);

type HistoryRow = { price: number; recorded_at: string };
type StockRow = {
  symbol: string;
  name: string;
  color: string;
  current_price: number;
  previous_close: number;
  shares: number;
  updated_at: string;
  price_history?: HistoryRow[];
};
type NewsRow = {
  id: number;
  title: string;
  stock_symbol: string | null;
  impact_pct: number;
  created_at: string;
};

function mapStock(row: StockRow, previousHistory: PricePoint[] = []): Stock {
  const currentPrice = Number(row.current_price);
  const recordedHistory = (row.price_history ?? []).map((point) => {
    const timestamp = new Date(point.recorded_at).getTime();
    return {
      time: new Date(timestamp).toLocaleTimeString("tr-TR", {
        hour: "2-digit",
        minute: "2-digit",
      }),
      price: Number(point.price),
      timestamp,
    };
  });
  const priceHistory = recordedHistory.length
    ? recordedHistory.sort((a, b) => a.timestamp - b.timestamp)
    : [...previousHistory];
  const lastPoint = priceHistory[priceHistory.length - 1];
  const updatedAt = new Date(row.updated_at).getTime();

  if (!lastPoint || lastPoint.timestamp !== updatedAt) {
    priceHistory.push({
      time: new Date(updatedAt).toLocaleTimeString("tr-TR", {
        hour: "2-digit",
        minute: "2-digit",
      }),
      price: currentPrice,
      timestamp: updatedAt,
    });
  }

  const prices = priceHistory.map((point) => point.price);
  const shares = Number(row.shares || 0);
  const id = row.symbol.toLowerCase();

  return {
    id,
    symbol: row.symbol,
    name: row.name,
    fullName: row.name,
    currentPrice,
    previousClose: Number(row.previous_close),
    openPrice: Number(row.previous_close),
    dayHigh: Math.max(currentPrice, ...prices),
    dayLow: Math.min(currentPrice, ...prices),
    volume: shares,
    marketCap: currentPrice * shares,
    sector: "Piyasa",
    avatarColor: row.color,
    priceHistory: priceHistory.slice(-100),
    lastUpdate: updatedAt,
  };
}

function mapNews(row: NewsRow): NewsItem {
  return {
    id: String(row.id),
    title: row.title,
    targetStockId: row.stock_symbol?.toLowerCase() ?? "",
    impactPercent: Number(row.impact_pct),
    timestamp: new Date(row.created_at).getTime(),
    author: "Piyasa",
  };
}

async function loadMarket(): Promise<MarketState> {
  const [stockResult, newsResult] = await Promise.all([
    supabase
      .from("stocks")
      .select(
        "symbol, name, color, current_price, previous_close, shares, updated_at, price_history(price, recorded_at)"
      )
      .order("symbol"),
    supabase
      .from("news_feed")
      .select("id, title, stock_symbol, impact_pct, created_at")
      .order("created_at", { ascending: false })
      .limit(50),
  ]);

  if (stockResult.error) throw stockResult.error;
  if (newsResult.error) throw newsResult.error;

  return {
    stocks: ((stockResult.data ?? []) as StockRow[]).map((row) => mapStock(row)),
    news: ((newsResult.data ?? []) as NewsRow[]).map(mapNews),
  };
}

export function MarketProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<MarketState>({ stocks: [], news: [] });
  const [selectedStockId, setSelectedStockId] = useState<string | null>(null);

  useEffect(() => {
    let active = true;

    const refresh = async () => {
      try {
        const nextState = await loadMarket();
        if (active) setState(nextState);
      } catch (error) {
        console.error("Supabase piyasa verileri yüklenemedi:", error);
      }
    };

    void refresh();

    const channel = supabase
      .channel("next-market-data")
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "stocks" },
        (payload) => {
          if (payload.eventType === "DELETE") {
            const deletedSymbol = String(payload.old.symbol ?? "").toLowerCase();
            setState((previous) => ({
              ...previous,
              stocks: previous.stocks.filter((stock) => stock.id !== deletedSymbol),
            }));
            return;
          }

          const row = payload.new as StockRow;
          setState((previous) => {
            const previousStock = previous.stocks.find(
              (stock) => stock.symbol === row.symbol
            );
            const nextStock = mapStock(row, previousStock?.priceHistory);
            const exists = previous.stocks.some((stock) => stock.id === nextStock.id);
            return {
              ...previous,
              stocks: exists
                ? previous.stocks.map((stock) =>
                    stock.id === nextStock.id ? nextStock : stock
                  )
                : [...previous.stocks, nextStock],
            };
          });
        }
      )
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "news_feed" },
        (payload) => {
          const news = mapNews(payload.new as NewsRow);
          setState((previous) => ({
            ...previous,
            news: [news, ...previous.news.filter((item) => item.id !== news.id)].slice(0, 50),
          }));
        }
      )
      .subscribe();

    return () => {
      active = false;
      void supabase.removeChannel(channel);
    };
  }, []);

  const addNews = useCallback(
    async (news: Omit<NewsItem, "id" | "timestamp">) => {
      const target = state.stocks.find((stock) => stock.id === news.targetStockId);
      const { data, error } = await supabase.rpc("admin_publish_news", {
        p_title: news.title,
        p_symbol: target?.symbol ?? null,
        p_impact_pct: news.impactPercent,
      });

      if (error) {
        console.error("Haber Supabase'e gönderilemedi:", error);
        return;
      }

      const created = mapNews(data as NewsRow);
      setState((previous) => ({
        ...previous,
        news: [created, ...previous.news.filter((item) => item.id !== created.id)].slice(0, 50),
      }));
    },
    [state.stocks]
  );

  const getStockById = useCallback(
    (id: string) => state.stocks.find((s) => s.id === id),
    [state.stocks]
  );

  const resetMarket = useCallback(async () => {
    const { error } = await supabase.rpc("admin_reset_market");
    if (error) {
      console.error("Piyasa sıfırlanamadı:", error);
      return;
    }
    try {
      setState(await loadMarket());
      setSelectedStockId(null);
    } catch (loadError) {
      console.error("Sıfırlanan piyasa yüklenemedi:", loadError);
    }
  }, []);

  const value = useMemo<MarketContextType>(
    () => ({
      stocks: state.stocks,
      news: state.news,
      addNews,
      getStockById,
      resetMarket,
      selectedStockId,
      setSelectedStockId,
    }),
    [
      state.stocks,
      state.news,
      addNews,
      getStockById,
      resetMarket,
      selectedStockId,
    ]
  );

  return (
    <MarketContext.Provider value={value}>{children}</MarketContext.Provider>
  );
}

export function useMarket() {
  const ctx = useContext(MarketContext);
  if (!ctx) {
    throw new Error("useMarket must be used within a MarketProvider");
  }
  return ctx;
}
