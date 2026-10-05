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
import { seedStocks, seedNews } from "@/data/mockData";

const STORAGE_KEY = "borsa-simulation-state-v1";

interface MarketContextType extends MarketState {
  addNews: (news: Omit<NewsItem, "id" | "timestamp">) => void;
  updateStockPrice: (stockId: string, impactPercent: number) => void;
  getStockById: (id: string) => Stock | undefined;
  resetMarket: () => void;
  selectedStockId: string | null;
  setSelectedStockId: (id: string | null) => void;
}

const MarketContext = createContext<MarketContextType | undefined>(undefined);

function loadInitialState(): MarketState {
  if (typeof window === "undefined") {
    return { stocks: seedStocks, news: seedNews };
  }
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) {
      const parsed = JSON.parse(raw) as MarketState;
      if (parsed.stocks && parsed.stocks.length > 0) {
        return parsed;
      }
    }
  } catch {
    // ignore
  }
  return { stocks: seedStocks, news: seedNews };
}

export function MarketProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<MarketState>(() => loadInitialState());
  const [selectedStockId, setSelectedStockId] = useState<string | null>(null);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  useEffect(() => {
    if (!mounted) return;
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
    } catch {
      // ignore
    }
  }, [state, mounted]);

  const updateStockPrice = useCallback(
    (stockId: string, impactPercent: number) => {
      setState((prev) => {
        const now = Date.now();
        const stocks = prev.stocks.map((s) => {
          if (s.id !== stockId) return s;
          const newPrice = Number(
            (s.currentPrice * (1 + impactPercent / 100)).toFixed(2)
          );
          const newPoint: PricePoint = {
            time: new Date(now).toLocaleTimeString("tr-TR", {
              hour: "2-digit",
              minute: "2-digit",
            }),
            price: newPrice,
            timestamp: now,
          };
          const newHistory = [...s.priceHistory, newPoint].slice(-60);
          return {
            ...s,
            currentPrice: newPrice,
            dayHigh: Math.max(s.dayHigh, newPrice),
            dayLow: Math.min(s.dayLow, newPrice),
            priceHistory: newHistory,
            volume: s.volume + Math.floor(Math.random() * 50000) + 10000,
            lastUpdate: now,
          };
        });
        return { ...prev, stocks };
      });
    },
    []
  );

  const addNews = useCallback(
    (news: Omit<NewsItem, "id" | "timestamp">) => {
      const newItem: NewsItem = {
        ...news,
        id: `news-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
        timestamp: Date.now(),
      };
      setState((prev) => ({
        ...prev,
        news: [newItem, ...prev.news].slice(0, 50),
      }));
      updateStockPrice(news.targetStockId, news.impactPercent);
    },
    [updateStockPrice]
  );

  const getStockById = useCallback(
    (id: string) => state.stocks.find((s) => s.id === id),
    [state.stocks]
  );

  const resetMarket = useCallback(() => {
    setState({ stocks: seedStocks, news: seedNews });
    setSelectedStockId(null);
    try {
      localStorage.removeItem(STORAGE_KEY);
    } catch {
      // ignore
    }
  }, []);

  const value = useMemo<MarketContextType>(
    () => ({
      stocks: state.stocks,
      news: state.news,
      addNews,
      updateStockPrice,
      getStockById,
      resetMarket,
      selectedStockId,
      setSelectedStockId,
    }),
    [
      state.stocks,
      state.news,
      addNews,
      updateStockPrice,
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
