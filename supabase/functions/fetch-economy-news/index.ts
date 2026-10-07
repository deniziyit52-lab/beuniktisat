import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-cron-secret",
  "Content-Type": "application/json; charset=utf-8",
};

const FINANCIAL_KEYWORDS = [
  "borsa",
  "hisse",
  "bist",
  "faiz",
  "enflasyon",
  "dolar",
  "kripto",
  "döviz",
  "yatırım",
  "piyasa",
  "ekonomi",
  "merkez bankası",
  "spk",
  "fon",
  "ihracat",
  "büyüme",
  "gram altın",
  "ons altın",
  "altın fiyat",
  "altın fiyatları",
  "cumhuriyet altını",
];

const BLOCKLIST = [
  // Siyasi terimler
  "parti",
  "siyaset",
  "secim",
  "meclis",
  "akp",
  "chp",
  "mhp",
  "dem parti",
  "milletvekili",
  "cumhurbaskan",
  // Kültür/Sanat/Festival - KESİNLİKLE ENGELLE
  "altın portakal",
  "altın koza",
  "festival",
  "film",
  "sinema",
  "gala",
  "sergi",
  "konser",
  "tiyatro",
  "dizi",
  "oyuncu",
  "sanatci",
  "odul",
  "aday",
  "en iyi",
  "kategorisi",
  "portakal",
  "futbol",
  "mac",
  "spor",
  "altın kelebek",
  "altın safran",
  "altın kelebek odul",
  "yildiz odulu",
  "sinema odulu",
  "film odulu",
  "bengu",
  "burak ozcivit",
  "kerem bursin",
  "hande ercel",
  "tuba buyukustun",
  "akdogan",
  "paris",
  "cannes",
  "venedik",
  "berlin",
  "emmy",
  "oscar",
  "bafta",
  "golden globe",
];

const NEWS_API_QUERY =
  '("borsa" OR "hisse" OR "BIST" OR "faiz" OR "enflasyon" OR "döviz" OR "yatırım" OR "merkez bankası" OR "kripto" OR "gram altın" OR "ons altın") NOT ("parti" OR "siyaset" OR "secim" OR "meclis" OR "akp" OR "chp" OR "mhp" OR "film" OR "oyuncu" OR "futbol" OR "festival" OR "altın portakal" OR "portakal")';

interface NewsApiArticle {
  title?: string | null;
  description?: string | null;
  publishedAt?: string | null;
}

interface NewsApiResponse {
  status?: string;
  code?: string;
  message?: string;
  articles?: NewsApiArticle[];
}

interface NewsRecord {
  title: string;
  summary: string;
  created_at: string;
  importance_score: number;
}

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: corsHeaders,
  });
}

function cleanText(value: string): string {
  return value
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

function normalizeForSearch(value: string): string {
  return value
    .toLocaleLowerCase("tr-TR")
    .replaceAll("ı", "i")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "");
}

function normalizeTitle(value: string): string {
  return normalizeForSearch(value).replace(/[^a-z0-9]+/g, " ").trim();
}

function isFinancialNews(title: string, summary: string): boolean {
  const fullText = `${title} ${summary}`.toLocaleLowerCase("tr-TR");

  // Blocklist check - KESİNLİKLE ENGELLE
  for (const term of BLOCKLIST) {
    if (fullText.includes(term.toLocaleLowerCase("tr-TR"))) {
      return false;
    }
  }

  // Count financial keywords - EN AZ 3 TANE OLMALI
  let keywordCount = 0;
  for (const keyword of FINANCIAL_KEYWORDS) {
    if (fullText.includes(keyword.toLocaleLowerCase("tr-TR"))) {
      keywordCount++;
    }
  }

  return keywordCount >= 3;
}

function constantTimeEquals(left: string, right: string): boolean {
  const leftBytes = new TextEncoder().encode(left);
  const rightBytes = new TextEncoder().encode(right);
  let difference = leftBytes.length ^ rightBytes.length;
  const length = Math.max(leftBytes.length, rightBytes.length);

  for (let index = 0; index < length; index += 1) {
    difference |=
      (leftBytes[index] ?? 0) ^ (rightBytes[index] ?? 0);
  }

  return difference === 0;
}

function calculateImportanceScore(title: string, summary: string): number {
  const highImpactWords = ["borsa", "spk", "faiz", "merkez bankası", "enflasyon", "kripto", "döviz", "dolar", "gram altın", "ons altın"];
  const mediumImpactWords = ["ekonomi", "ihracat", "ithalat", "büyüme", "yatırım", "fon", "şirket", "vergi"];

  const fullText = `${title} ${summary}`.toLocaleLowerCase("tr-TR");
  let score = 0;

  for (const word of highImpactWords) {
    if (fullText.includes(word)) {
      score += 10;
    }
  }

  for (const word of mediumImpactWords) {
    if (fullText.includes(word)) {
      score += 5;
    }
  }

  return score;
}

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return jsonResponse({ error: "Only POST requests are accepted." }, 405);
  }

  const cronSecret = Deno.env.get("CRON_SECRET");
  if (!cronSecret) {
    console.error("CRON_SECRET is not configured.");
    return jsonResponse({ error: "Function is not configured." }, 500);
  }
  if (!constantTimeEquals(request.headers.get("x-cron-secret") ?? "", cronSecret)) {
    return jsonResponse({ error: "Unauthorized." }, 401);
  }

  const newsApiKey = Deno.env.get("NEWS_API_KEY");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!newsApiKey || !supabaseUrl || !serviceRoleKey) {
    console.error("Required news or Supabase secrets are missing.");
    return jsonResponse({ error: "Function is not configured." }, 500);
  }

  try {
    const newsUrl = new URL("https://newsapi.org/v2/everything");
    newsUrl.searchParams.set("q", NEWS_API_QUERY);
    newsUrl.searchParams.set("language", "tr");
    newsUrl.searchParams.set("sortBy", "publishedAt");
    newsUrl.searchParams.set("pageSize", "100");

    const apiResponse = await fetch(newsUrl, {
      headers: { "X-Api-Key": newsApiKey },
      signal: AbortSignal.timeout(15_000),
    });
    const apiBody = (await apiResponse.json()) as NewsApiResponse;

    if (!apiResponse.ok || apiBody.status !== "ok" || !Array.isArray(apiBody.articles)) {
      console.error("News API request failed.", {
        status: apiResponse.status,
        code: apiBody.code,
        message: apiBody.message,
      });
      return jsonResponse({ error: "News provider request failed." }, 502);
    }

    const candidateArticles: NewsRecord[] = [];
    const seenTitles = new Set<string>();
    for (const article of apiBody.articles) {
      const title = cleanText(article.title ?? "");
      const summary = cleanText(article.description ?? "");
      const publishedAt = article.publishedAt
        ? new Date(article.publishedAt)
        : null;

      if (
        !title ||
        !summary ||
        /^\[?removed\]?$/i.test(title) ||
        /^\[?removed\]?$/i.test(summary) ||
        title.length > 280 ||
        !publishedAt ||
        Number.isNaN(publishedAt.getTime()) ||
        !isFinancialNews(title, summary)
      ) {
        continue;
      }

      const normalizedTitle = normalizeTitle(title);
      if (seenTitles.has(normalizedTitle)) continue;
      seenTitles.add(normalizedTitle);

      candidateArticles.push({
        title,
        summary: summary.slice(0, 500),
        created_at: publishedAt.toISOString(),
        importance_score: calculateImportanceScore(title, summary),
      });
    }

    if (candidateArticles.length === 0) {
      return jsonResponse({ inserted: 0, message: "No matching Turkish economy articles found." });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: existingArticles, error: lookupError } = await supabase
      .from("news_feed")
      .select("title")
      .in("title", candidateArticles.map((article) => article.title));

    if (lookupError) {
      console.error("Could not check existing news titles.", lookupError);
      return jsonResponse({ error: "Could not check existing news." }, 500);
    }

    const existingTitles = new Set(
      (existingArticles ?? []).map((article) => normalizeTitle(article.title)),
    );
    const articlesToInsert = candidateArticles
      .filter((article) => !existingTitles.has(normalizeTitle(article.title)))
      .slice(0, 8);

    if (articlesToInsert.length === 0) {
      return jsonResponse({ inserted: 0, message: "Articles are already in the news archive." });
    }

    const baseId = BigInt(Date.now()) * 1_000n;
    const rows = articlesToInsert.map((article, index) => ({
      id: Number(baseId + BigInt(index)),
      title: article.title,
      summary: article.summary,
      stock_symbol: null,
      impact_pct: 0,
      created_at: article.created_at,
      importance_score: article.importance_score,
    }));

    const { data: insertedArticles, error: insertError } = await supabase
      .from("news_feed")
      .insert(rows)
      .select("id, title");

    if (insertError) {
      console.error("Could not insert fetched news.", insertError);
      return jsonResponse({ error: "Could not save fetched news." }, 500);
    }

    // Check total count and keep only top 15 articles by importance_score and created_at
    const { data: allArticles, error: countError } = await supabase
      .from("news_feed")
      .select("id")
      .order("importance_score", { ascending: false })
      .order("created_at", { ascending: false });

    if (countError) {
      console.error("Could not check article count.", countError);
      return jsonResponse({ error: "Could not check article count." }, 500);
    }

    if (allArticles && allArticles.length > 15) {
      const articlesToDelete = allArticles.slice(15);
      const idsToDelete = articlesToDelete.map((article) => article.id);

      const { error: deleteError } = await supabase
        .from("news_feed")
        .delete()
        .in("id", idsToDelete);

      if (deleteError) {
        console.error("Could not delete excess articles.", deleteError);
        return jsonResponse({ error: "Could not delete excess articles." }, 500);
      }
    }

    return jsonResponse({
      inserted: insertedArticles?.length ?? 0,
      titles: insertedArticles?.map((article) => article.title) ?? [],
    });
  } catch (error) {
    console.error("News fetch failed.", error);
    return jsonResponse({ error: "News fetch failed." }, 500);
  }
});
