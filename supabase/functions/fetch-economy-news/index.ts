import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-cron-secret",
  "Content-Type": "application/json; charset=utf-8",
};

const ECONOMY_TERMS = [
  "borsa",
  "hisse",
  "ekonomi",
  "finans",
  "piyasa",
  "merkez bank",
  "faiz",
  "enflasyon",
  "doviz",
  "kur",
  "yatirim",
  "bankac",
  "sirket",
  "ihracat",
  "ithalat",
  "altin",
  "petrol",
  "ticaret",
  "buyume",
  "resesyon",
  "butce",
  "vergi",
  "kredi",
  "kripto",
  "halka arz",
  "bilanco",
  "dolar",
  "euro",
  "ekonomik",
];

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

function isEconomyArticle(title: string, summary: string): boolean {
  const text = normalizeForSearch(`${title} ${summary}`);
  return ECONOMY_TERMS.some((term) => text.includes(term));
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
    newsUrl.searchParams.set(
      "q",
      '"borsa" OR "ekonomi" OR "finans" OR "piyasa" OR "merkez bankası" OR "enflasyon" OR "faiz" OR "döviz" OR "yatırım"',
    );
    newsUrl.searchParams.set("language", "tr");
    newsUrl.searchParams.set("sortBy", "publishedAt");
    newsUrl.searchParams.set("pageSize", "30");

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

    const selectedArticles: NewsRecord[] = [];
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
        !isEconomyArticle(title, summary)
      ) {
        continue;
      }

      selectedArticles.push({
        title,
        summary: summary.slice(0, 500),
        created_at: publishedAt.toISOString(),
      });
      if (selectedArticles.length === 2) break;
    }

    if (selectedArticles.length === 0) {
      return jsonResponse({ inserted: 0, message: "No matching Turkish economy articles found." });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const titles = selectedArticles.map((article) => article.title);
    const { data: existingArticles, error: lookupError } = await supabase
      .from("news_feed")
      .select("title")
      .in("title", titles);

    if (lookupError) {
      console.error("Could not check existing news titles.", lookupError);
      return jsonResponse({ error: "Could not check existing news." }, 500);
    }

    const existingTitles = new Set((existingArticles ?? []).map((article) => article.title));
    const articlesToInsert = selectedArticles.filter(
      (article) => !existingTitles.has(article.title),
    );

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
    }));

    const { data: insertedArticles, error: insertError } = await supabase
      .from("news_feed")
      .insert(rows)
      .select("id, title");

    if (insertError) {
      console.error("Could not insert fetched news.", insertError);
      return jsonResponse({ error: "Could not save fetched news." }, 500);
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
