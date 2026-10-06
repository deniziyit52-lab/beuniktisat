"use client";

import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { NewsFeed } from "@/components/NewsFeed";

export function NewsAccessButton() {
  const [isOpen, setIsOpen] = useState(false);
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  useEffect(() => {
    if (!isOpen) return;

    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setIsOpen(false);
    };

    document.body.classList.add("news-modal-open");
    document.addEventListener("keydown", closeOnEscape);
    return () => {
      document.body.classList.remove("news-modal-open");
      document.removeEventListener("keydown", closeOnEscape);
    };
  }, [isOpen]);

  return (
    <>
      {mounted &&
        createPortal(
          <button
            type="button"
            onClick={() => setIsOpen(true)}
            aria-haspopup="dialog"
            aria-expanded={isOpen}
            aria-controls="news-paper-title"
            className="news-fab"
          >
            📰 Haberler
          </button>,
          document.body
        )}
      {isOpen &&
        mounted &&
        createPortal(
          <div
            className="news-modal-overlay is-open"
            role="presentation"
            onMouseDown={(event) => {
              if (event.target === event.currentTarget) setIsOpen(false);
            }}
          >
            <div
              className="news-modal-dialog"
              role="dialog"
              aria-modal="true"
              aria-labelledby="news-paper-title"
            >
              <button
                type="button"
                onClick={() => setIsOpen(false)}
                className="news-modal-close"
                aria-label="Haberleri kapat"
                title="Kapat"
              >
                ×
              </button>
              <NewsFeed />
            </div>
          </div>,
          document.body
        )}
    </>
  );
}
