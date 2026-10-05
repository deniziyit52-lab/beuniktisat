import type { Metadata } from "next";
import "./globals.css";
import { MarketProvider } from "@/context/MarketContext";

export const metadata: Metadata = {
  title: "Borsa Simulation | Ekonomi Kulübü",
  description:
    "Üniversite Ekonomi Kulübü Borsa Simülasyonu - Üye hisselerini takip edin ve alışveriş yapın",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="tr">
      <body className="min-h-screen bg-grid antialiased">
        <MarketProvider>{children}</MarketProvider>
      </body>
    </html>
  );
}
