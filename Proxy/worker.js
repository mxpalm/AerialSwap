// AerialSwap's Discover proxy: forwards video searches to Pixabay and adds the API key, which is kept here as a
// Cloudflare secret, so the key never ships inside the app. See Proxy/README.md.
//
//   GET /videos?q=ocean&video_type=film&...   ->   https://pixabay.com/api/videos/?key=<secret>&q=ocean&...
//
// Responses are cached for 24 hours in Workers KV (Pixabay's API terms ask for that), so repeated searches from
// any user don't reach Pixabay. Each IP gets a limited number of uncached searches per minute.

const PIXABAY = "https://pixabay.com/api/videos/";
// Only the parameters AerialSwap sends are forwarded; anything else is dropped.
const ALLOWED = ["q", "video_type", "min_width", "safesearch", "order", "per_page", "page", "editors_choice"];
const CACHE_SECONDS = 24 * 3600;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method !== "GET") return error(405, "Only GET is supported.");
    if (url.pathname !== "/videos") return error(404, "Not found.");
    if (!env.PIXABAY_KEY) return error(500, "The proxy has no Pixabay key.");

    // The normalized search (without the key) is both the cache key and what gets forwarded.
    const query = new URLSearchParams();
    for (const name of ALLOWED) {
      const value = url.searchParams.get(name);
      if (value !== null) query.set(name, value.slice(0, 100));
    }
    const perPage = parseInt(query.get("per_page") ?? "30", 10) || 30;
    query.set("per_page", String(Math.min(Math.max(perPage, 3), 50)));
    query.sort();
    const cacheKey = `videos?${query}`;

    const cached = await env.CACHE?.get(cacheKey);
    if (cached) return json(cached, 200, "HIT");

    if (env.LIMITER) {
      const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
      const { success } = await env.LIMITER.limit({ key: ip });
      if (!success) return error(429, "Too many searches. Try again in a minute.");
    }

    query.set("key", env.PIXABAY_KEY);
    const upstream = await fetch(`${PIXABAY}?${query}`);
    if (upstream.status === 429) return error(429, "Pixabay is busy. Try again in a minute.");
    if (!upstream.ok) {
      // e.g. 400 "Invalid or missing API key": the proxy's problem, so log Pixabay's text instead of passing it on.
      console.error(`Pixabay HTTP ${upstream.status}: ${(await upstream.text()).slice(0, 200)}`);
      return error(502, "Pixabay answered with an error.");
    }
    const body = await upstream.text();
    // KV's free tier allows 1,000 writes a day; past that, results just aren't cached.
    if (env.CACHE) ctx.waitUntil(env.CACHE.put(cacheKey, body, { expirationTtl: CACHE_SECONDS }).catch(() => {}));
    return json(body, 200, "MISS");
  },
};

function json(body, status, cache) {
  return new Response(body, {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Proxy-Cache": cache },
  });
}

function error(status, message) {
  return json(JSON.stringify({ error: message }), status, "NONE");
}
