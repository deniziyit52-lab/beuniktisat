export interface PricePoint {
  time: string;
  price: number;
  timestamp: number;
}

export interface Stock {
  id: string;
  symbol: string;
  name: string;
  fullName: string;
  currentPrice: number;
  previousClose: number;
  openPrice: number;
  dayHigh: number;
  dayLow: number;
  volume: number;
  marketCap: number;
  sector: string;
  avatarColor: string;
  priceHistory: PricePoint[];
  lastUpdate: number;
}

export interface NewsItem {
  id: string;
  title: string;
  summary?: string;
  targetStockId: string;
  impactPercent: number;
  timestamp: number;
  author?: string;
}

export type MarketState = {
  stocks: Stock[];
  news: NewsItem[];
};
