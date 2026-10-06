import type { Config } from "tailwindcss";

const config: Config = {
  content: [
    "./src/pages/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/components/**/*.{js,ts,jsx,tsx,mdx}",
    "./src/app/**/*.{js,ts,jsx,tsx,mdx}",
  ],
  theme: {
    extend: {
      colors: {
        wallstreet: {
          bg: "#0a0e17",
          panel: "#111827",
          border: "#1f2937",
          accent: "#1e3a5f",
        },
        neon: {
          green: "#00ff88",
          red: "#ff3b5c",
          blue: "#00d4ff",
          yellow: "#ffd700",
          purple: "#a855f7",
        },
      },
      fontFamily: {
        mono: ['"JetBrains Mono"', '"Fira Code"', "ui-monospace", "monospace"],
      },
      animation: {
        "ticker-scroll": "ticker 32s linear infinite",
        "pulse-green": "pulse-green 2s ease-in-out infinite",
        "pulse-red": "pulse-red 2s ease-in-out infinite",
        "glow-green": "glow-green 1.5s ease-in-out infinite alternate",
        "glow-red": "glow-red 1.5s ease-in-out infinite alternate",
      },
      keyframes: {
        ticker: {
          "0%": { transform: "translateX(0%)" },
          "100%": { transform: "translateX(-50%)" },
        },
        "pulse-green": {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.6" },
        },
        "pulse-red": {
          "0%, 100%": { opacity: "1" },
          "50%": { opacity: "0.6" },
        },
        "glow-green": {
          "0%": { textShadow: "0 0 5px #00ff88, 0 0 10px #00ff88" },
          "100%": { textShadow: "0 0 10px #00ff88, 0 0 20px #00ff88, 0 0 30px #00ff88" },
        },
        "glow-red": {
          "0%": { textShadow: "0 0 5px #ff3b5c, 0 0 10px #ff3b5c" },
          "100%": { textShadow: "0 0 10px #ff3b5c, 0 0 20px #ff3b5c, 0 0 30px #ff3b5c" },
        },
      },
      boxShadow: {
        "neon-green": "0 0 15px rgba(0, 255, 136, 0.3), inset 0 0 15px rgba(0, 255, 136, 0.05)",
        "neon-red": "0 0 15px rgba(255, 59, 92, 0.3), inset 0 0 15px rgba(255, 59, 92, 0.05)",
        "neon-blue": "0 0 15px rgba(0, 212, 255, 0.3), inset 0 0 15px rgba(0, 212, 255, 0.05)",
        "panel": "0 4px 6px -1px rgba(0, 0, 0, 0.3), 0 2px 4px -1px rgba(0, 0, 0, 0.2)",
      },
    },
  },
  plugins: [],
};

export default config;
