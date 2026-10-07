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
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link
          rel="preconnect"
          href="https://fonts.gstatic.com"
          crossOrigin="anonymous"
        />
        <link
          href="https://fonts.googleapis.com/css2?family=Playfair+Display:wght@400;600;700;900&family=Merriweather:wght@400;700&display=swap"
          rel="stylesheet"
        />
      </head>
      <body className="min-h-screen bg-grid antialiased">
        <MarketProvider>{children}</MarketProvider>
      </body>
    </html>
  );
}
