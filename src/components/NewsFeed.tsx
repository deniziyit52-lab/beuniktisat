"use client";

import { useMarket } from "@/context/MarketContext";

function formatNewsDateTime(timestamp: number): string {
  const date = new Date(timestamp);
  return `${date.toLocaleDateString("tr-TR", {
    day: "numeric",
    month: "long",
    year: "numeric",
  })} - ${date.toLocaleTimeString("tr-TR", {
    hour: "2-digit",
    minute: "2-digit",
  })}`;
}

function formatDateHeader(): string {
  const date = new Date();
  const dayNames = ["Pazar", "Pazartesi", "Salı", "Çarşamba", "Perşembe", "Cuma", "Cumartesi"];
  const monthNames = ["Ocak", "Şubat", "Mart", "Nisan", "Mayıs", "Haziran", "Temmuz", "Ağustos", "Eylül", "Ekim", "Kasım", "Aralık"];
  return `${dayNames[date.getDay()]}, ${date.getDate()} ${monthNames[date.getMonth()]} ${date.getFullYear()}`;
}

function getVolumeNumber(): string {
  const startDate = new Date("2024-01-01");
  const currentDate = new Date();
  const diffTime = Math.abs(currentDate.getTime() - startDate.getTime());
  const diffDays = Math.ceil(diffTime / (1000 * 60 * 60 * 24));
  return `No. ${diffDays}`;
}

export function NewsFeed() {
  const { news, getStockById, setSelectedStockId } = useMarket();
  const lead = news[0];
  const leadStock = lead ? getStockById(lead.targetStockId) : undefined;

  return (
    <section className="news-paper" aria-labelledby="news-paper-title">
      <header className="news-paper-masthead">
        <div className="news-paper-top-border"></div>
        <p className="news-paper-kicker">PİYASA • HABER ARŞİVİ</p>
        <h2 id="news-paper-title" className="news-paper-name">
          THE GLOBAL GAZETTE
        </h2>
        <div className="news-paper-subtitle">
          <span>Daily Financial News</span>
        </div>
        <div className="news-paper-ticker">
          <span className="ticker-date">{formatDateHeader()}</span>
          <span className="ticker-separator">•</span>
          <span className="ticker-weather">Istanbul, Türkiye</span>
          <span className="ticker-separator">•</span>
          <span className="ticker-volume">{getVolumeNumber()}</span>
          <span className="ticker-separator">•</span>
          <span className="ticker-count">{news.length} Makale</span>
        </div>
        <div className="news-paper-bottom-border"></div>
      </header>

      <div className="news-paper-list">
        {news.length === 0 ? (
          <p className="news-paper-empty">Henüz haber yok.</p>
        ) : (
          <>
            <article className="news-paper-lead">
              <p className="news-paper-section-label">GÜNÜN MANŞETİ</p>
              <h3>{lead.title}</h3>
              {lead.summary && (
                <p className="news-paper-spot">{lead.summary}</p>
              )}
              <div className="news-paper-story-meta">
                {leadStock && (
                  <button
                    type="button"
                    onClick={() => setSelectedStockId(leadStock.id)}
                    className="news-paper-stock"
                  >
                    {leadStock.symbol} · {leadStock.name}
                  </button>
                )}
                <span
                  className={`news-paper-impact ${
                    lead.impactPercent >= 0 ? "positive" : "negative"
                  }`}
                >
                  {lead.impactPercent >= 0 ? "+" : ""}
                  {lead.impactPercent.toFixed(1)}%
                </span>
                <time dateTime={new Date(lead.timestamp).toISOString()}>
                  {formatNewsDateTime(lead.timestamp)}
                </time>
              </div>
            </article>

            {news.length > 1 && (
              <ol className="news-paper-columns">
                {news.slice(1).map((item) => {
                  const stock = getStockById(item.targetStockId);
                  const isPositive = item.impactPercent >= 0;

                  return (
                    <li className="news-paper-story" key={item.id}>
                      <div className="news-paper-story-heading">
                        <h4>{item.title}</h4>
                        <time dateTime={new Date(item.timestamp).toISOString()}>
                          {formatNewsDateTime(item.timestamp)}
                        </time>
                      </div>
                      {item.summary && (
                        <p className="news-paper-secondary-spot">{item.summary}</p>
                      )}
                      <div className="news-paper-story-meta">
                        {stock && (
                          <button
                            type="button"
                            onClick={() => setSelectedStockId(stock.id)}
                            className="news-paper-stock"
                          >
                            {stock.symbol} · {stock.name}
                          </button>
                        )}
                        <span
                          className={`news-paper-impact ${
                            isPositive ? "positive" : "negative"
                          }`}
                        >
                          {isPositive ? "+" : ""}
                          {item.impactPercent.toFixed(1)}%
                        </span>
                      </div>
                    </li>
                  );
                })}
              </ol>
            )}
          </>
        )}
      </div>
    </section>
  );
}
