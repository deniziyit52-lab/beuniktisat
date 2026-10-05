import { Stock, NewsItem, PricePoint } from "@/types";

function generatePriceHistory(
  basePrice: number,
  volatility: number,
  points: number = 48
): PricePoint[] {
  const history: PricePoint[] = [];
  let price = basePrice * (0.9 + Math.random() * 0.2);
  const now = Date.now();
  const intervalMs = 30 * 60 * 1000;

  for (let i = points; i >= 0; i--) {
    const change = (Math.random() - 0.5) * volatility;
    price = Math.max(0.5, price + change);
    const timestamp = now - i * intervalMs;
    history.push({
      time: new Date(timestamp).toLocaleTimeString("tr-TR", {
        hour: "2-digit",
        minute: "2-digit",
      }),
      price: Number(price.toFixed(2)),
      timestamp,
    });
  }

  return history;
}

const now = Date.now();

export const seedStocks: Stock[] = [
  {
    id: "deniz",
    symbol: "DENIZ",
    name: "Deniz Holding",
    fullName: "Deniz Yatırım Holding A.Ş.",
    currentPrice: 87.45,
    previousClose: 82.1,
    openPrice: 82.5,
    dayHigh: 89.2,
    dayLow: 81.3,
    volume: 1_250_000,
    marketCap: 8_745_000,
    sector: "Teknoloji & Finans",
    avatarColor: "#00d4ff",
    priceHistory: generatePriceHistory(85, 2.5),
    lastUpdate: now,
  },
  {
    id: "ahmet",
    symbol: "AHMET",
    name: "Ahmet Enerji",
    fullName: "Ahmet Yenilenebilir Enerji A.Ş.",
    currentPrice: 54.2,
    previousClose: 56.8,
    openPrice: 56.5,
    dayHigh: 57.1,
    dayLow: 53.4,
    volume: 890_000,
    marketCap: 5_420_000,
    sector: "Enerji",
    avatarColor: "#ffd700",
    priceHistory: generatePriceHistory(55, 1.8),
    lastUpdate: now,
  },
  {
    id: "ayse",
    symbol: "AYSE",
    name: "Ayşe Gıda",
    fullName: "Ayşe Organik Gıda Sanayi A.Ş.",
    currentPrice: 124.8,
    previousClose: 118.3,
    openPrice: 119.0,
    dayHigh: 126.5,
    dayLow: 118.0,
    volume: 2_100_000,
    marketCap: 12_480_000,
    sector: "Gıda",
    avatarColor: "#a855f7",
    priceHistory: generatePriceHistory(120, 3.2),
    lastUpdate: now,
  },
  {
    id: "mehmet",
    symbol: "MEHME",
    name: "Mehmet İnşaat",
    fullName: "Mehmet İnşaat ve Gayrimenkul A.Ş.",
    currentPrice: 42.15,
    previousClose: 43.5,
    openPrice: 43.2,
    dayHigh: 44.0,
    dayLow: 41.8,
    volume: 650_000,
    marketCap: 4_215_000,
    sector: "Gayrimenkul",
    avatarColor: "#ff3b5c",
    priceHistory: generatePriceHistory(43, 1.2),
    lastUpdate: now,
  },
  {
    id: "elif",
    symbol: "ELIF",
    name: "Elif Sağlık",
    fullName: "Elif Sağlık Hizmetleri A.Ş.",
    currentPrice: 168.9,
    previousClose: 162.4,
    openPrice: 163.0,
    dayHigh: 170.2,
    dayLow: 161.5,
    volume: 3_400_000,
    marketCap: 16_890_000,
    sector: "Sağlık",
    avatarColor: "#00ff88",
    priceHistory: generatePriceHistory(165, 4.0),
    lastUpdate: now,
  },
  {
    id: "can",
    symbol: "CAN",
    name: "Can Medya",
    fullName: "Can Dijital Medya Grubu A.Ş.",
    currentPrice: 31.75,
    previousClose: 30.1,
    openPrice: 30.2,
    dayHigh: 32.4,
    dayLow: 29.8,
    volume: 480_000,
    marketCap: 3_175_000,
    sector: "Medya & İletişim",
    avatarColor: "#ff8c42",
    priceHistory: generatePriceHistory(31, 1.0),
    lastUpdate: now,
  },
  {
    id: "zeynep",
    symbol: "ZEYNE",
    name: "Zeynep Moda",
    fullName: "Zeynep Tekstil ve Moda A.Ş.",
    currentPrice: 76.3,
    previousClose: 79.8,
    openPrice: 79.0,
    dayHigh: 80.1,
    dayLow: 75.6,
    volume: 720_000,
    marketCap: 7_630_000,
    sector: "Tekstil",
    avatarColor: "#ec4899",
    priceHistory: generatePriceHistory(78, 2.0),
    lastUpdate: now,
  },
  {
    id: "burak",
    symbol: "BURAK",
    name: "Burak Savunma",
    fullName: "Burak Savunma Teknolojileri A.Ş.",
    currentPrice: 215.4,
    previousClose: 210.0,
    openPrice: 211.2,
    dayHigh: 218.9,
    dayLow: 210.0,
    volume: 1_850_000,
    marketCap: 21_540_000,
    sector: "Savunma",
    avatarColor: "#14b8a6",
    priceHistory: generatePriceHistory(212, 5.0),
    lastUpdate: now,
  },
];

export const seedNews: NewsItem[] = [
  {
    id: "news-1",
    title: "Deniz Holding CEO'su, yeni dijital platform tanıtımını duyurdu",
    targetStockId: "deniz",
    impactPercent: 8.5,
    timestamp: now - 1000 * 60 * 60 * 2,
    author: "Piyasa Haber",
  },
  {
    id: "news-2",
    title: "Ahmet Enerji'de maliyet artışı endişesi - Analistler",
    targetStockId: "ahmet",
    impactPercent: -6.2,
    timestamp: now - 1000 * 60 * 60 * 1.5,
    author: "Ekonomi Gazetesi",
  },
  {
    id: "news-3",
    title: "Ayşe Gıda'nın yeni ürün yelpazesi büyük ilgi gördü",
    targetStockId: "ayse",
    impactPercent: 12.3,
    timestamp: now - 1000 * 60 * 60 * 1,
    author: "Haber Merkezi",
  },
  {
    id: "news-4",
    title: "Elif Sağlık, yeni hastane yatırımı için anlaşma imzaladı",
    targetStockId: "elif",
    impactPercent: 9.8,
    timestamp: now - 1000 * 60 * 30,
    author: "Sağlık Haber",
  },
  {
    id: "news-5",
    title: "Zeynep Moda, yaz koleksiyonu satışlarında düşüş yaşadı",
    targetStockId: "zeynep",
    impactPercent: -7.4,
    timestamp: now - 1000 * 60 * 15,
    author: "Moda Dergisi",
  },
];
