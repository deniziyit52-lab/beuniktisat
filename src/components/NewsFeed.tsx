"use client";

import { useMarket } from "@/context/MarketContext";
import { useState } from "react";

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
  const [selectedNews, setSelectedNews] = useState<any>(null);
  const lead = news[0];
  const leadStock = lead ? getStockById(lead.targetStockId) : undefined;

  const handleNewsClick = (newsItem: any) => {
    setSelectedNews(newsItem);
  };

  const closeDetailModal = () => {
    setSelectedNews(null);
  };

  return (
    <>
      <section className="news-paper" aria-labelledby="news-paper-title">
        <header className="news-paper-masthead">
          <div className="news-paper-top-border"></div>
          <p className="news-paper-kicker">📰 PİYASA • HABER ARŞİVİ</p>
          <h2 id="news-paper-title" className="news-paper-name">
            EKONOMİ GAZETESİ
          </h2>
          <div className="news-paper-bottom-border"></div>
        </header>

      <div className="news-paper-list">
        {news.length === 0 ? (
          <p className="news-paper-empty">Henüz haber yok.</p>
        ) : (
          <>
            <article
              className="news-paper-lead"
              onClick={() => lead && handleNewsClick(lead)}
            >
              <p className="news-paper-section-label">🔥 GÜNÜN MANŞETİ</p>
              <h3>💎 {lead.title}</h3>
              {lead.summary && (
                <p className="news-paper-spot">{lead.summary}</p>
              )}
              <div className="news-paper-story-meta">
                {leadStock && (
                  <button
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      setSelectedStockId(leadStock.id);
                    }}
                    className="news-paper-stock"
                  >
                    📊 {leadStock.symbol} · {leadStock.name}
                  </button>
                )}
                <span
                  className={`news-paper-impact ${
                    lead.impactPercent >= 0 ? "positive" : "negative"
                  }`}
                >
                  {lead.impactPercent >= 0 ? "📈" : "📉"}
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
                    <li
                      className="news-paper-story"
                      key={item.id}
                      onClick={() => handleNewsClick(item)}
                    >
                      <div className="news-paper-story-heading">
                        <h4>💰 {item.title}</h4>
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
                            onClick={(e) => {
                              e.stopPropagation();
                              setSelectedStockId(stock.id);
                            }}
                            className="news-paper-stock"
                          >
                            📊 {stock.symbol} · {stock.name}
                          </button>
                        )}
                        <span
                          className={`news-paper-impact ${
                            isPositive ? "positive" : "negative"
                          }`}
                        >
                          {isPositive ? "📈" : "📉"}
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

      {/* News Detail Modal */}
      {selectedNews && (
        <div
          className="news-detail-modal-overlay is-open"
          role="dialog"
          aria-modal="true"
          aria-labelledby="newsDetailTitle"
          onClick={closeDetailModal}
        >
          <div
            className="news-detail-modal-dialog"
            onClick={(e) => e.stopPropagation()}
          >
            <button
              type="button"
              onClick={closeDetailModal}
              className="news-detail-modal-close"
              aria-label="Kapat"
              title="Kapat"
            >
              ×
            </button>
            <div className="news-detail-content">
              <header className="news-detail-header">
                <span className="news-detail-badge">📰 Detaylı Haber</span>
                <h2 id="newsDetailTitle" className="news-detail-title">
                  {selectedNews.title}
                </h2>
                <div className="news-detail-meta">
                  {selectedNews.targetStockId && getStockById(selectedNews.targetStockId) ? (
                    <span className="news-detail-stock">
                      📊 {getStockById(selectedNews.targetStockId)?.symbol} ·{" "}
                      {getStockById(selectedNews.targetStockId)?.name}
                    </span>
                  ) : (
                    <span className="news-detail-stock">📈 Piyasa</span>
                  )}
                  <span
                    className={`news-detail-impact ${
                      selectedNews.impactPercent >= 0 ? "positive" : "negative"
                    }`}
                  >
                    {selectedNews.impactPercent >= 0 ? "📈" : "📉"}
                    {selectedNews.impactPercent >= 0 ? "+" : ""}
                    {selectedNews.impactPercent.toFixed(1)}%
                  </span>
                  <time
                    className="news-detail-time"
                    dateTime={new Date(selectedNews.timestamp).toISOString()}
                  >
                    {formatNewsDateTime(selectedNews.timestamp)}
                  </time>
                </div>
              </header>
              <div className="news-detail-body">
                {selectedNews.summary && (
                  <p className="news-detail-summary">{selectedNews.summary}</p>
                )}
                <div className="news-detail-stats">
                  <div className="stat-item">
                    <span className="stat-label">📅 Tarih</span>
                    <span className="stat-value">
                      {new Date(selectedNews.timestamp).toLocaleDateString("tr-TR")}
                    </span>
                  </div>
                  <div className="stat-item">
                    <span className="stat-label">⏰ Saat</span>
                    <span className="stat-value">
                      {new Date(selectedNews.timestamp).toLocaleTimeString("tr-TR")}
                    </span>
                  </div>
                  <div className="stat-item">
                    <span className="stat-label">📊 Etki</span>
                    <span
                      className={`stat-value ${
                        selectedNews.impactPercent >= 0 ? "positive" : "negative"
                      }`}
                    >
                      {selectedNews.impactPercent >= 0 ? "+" : ""}
                      {selectedNews.impactPercent.toFixed(1)}%
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
