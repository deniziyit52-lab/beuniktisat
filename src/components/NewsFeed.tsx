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

export function NewsFeed() {
  const { news, getStockById, setSelectedStockId } = useMarket();
  const lead = news[0];
  const leadStock = lead ? getStockById(lead.targetStockId) : undefined;

  return (
    <section className="news-paper" aria-labelledby="news-paper-title">
      <header className="news-paper-masthead">
        <p className="news-paper-kicker">PİYASA • HABER ARŞİVİ</p>
        <h2 id="news-paper-title" className="news-paper-name">
          Ekonomi Gazetesi
        </h2>
        <div className="news-paper-edition">
          <span>Haberler</span>
          <span>{news.length} kayıt</span>
        </div>
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
