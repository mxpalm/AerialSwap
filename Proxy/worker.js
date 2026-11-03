// AerialSwap's Discover proxy: forwards video searches to Pixabay and Wallpaper Engine Workshop searches to Steam, and
// adds the API keys, which are kept here as Cloudflare secrets, so no key ships inside the app. See Proxy/README.md.
//
//   GET /videos?q=ocean&video_type=film&...   ->   https://pixabay.com/api/videos/?key=<secret>&q=ocean&...
//   GET /workshop?search_text=ocean&...       ->   https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/
//                                                  ?key=<secret>&appid=431960&requiredtags[0]=Video&...
//
// Responses are cached for 24 hours in Workers KV (Pixabay's API terms ask for that), so repeated searches from
// any user don't reach Pixabay. Each IP gets a limited number of uncached searches per minute.

const PIXABAY = "https://pixabay.com/api/videos/";
// Only the parameters AerialSwap sends are forwarded; anything else is dropped.
const ALLOWED = ["q", "video_type", "min_width", "safesearch", "order", "per_page", "page", "editors_choice", "category"];
const CACHE_SECONDS = 24 * 3600;

const STEAM = "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/";
// Public profile names of the items' creators, for the credit.
const STEAM_PLAYERS = "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/";
// resolution=4k: only wallpapers tagged as 4K. resolution=1440: 1440p and up; every item has one resolution tag
// (Wallpaper Engine sets it), so the lower ones are excluded, and "Other resolution", which can be anything.
const RESOLUTION_TAGS = { "4k": "3840 x 2160" };
const RESOLUTION_EXCLUDED = {
  "1440": ["1920 x 1080", "1366 x 768", "1280 x 720", "Standard Definition", "Ultrawide 2560 x 1080",
           "Ultrawide Standard Definition", "Dual Standard Definition", "Portrait 1080 x 1920",
           "Portrait 720 x 1280", "Portrait Standard Definition", "Other resolution"],
};
// Wallpaper Engine's Workshop, video wallpapers for everyone only: fixed here, whatever the app asks for.
const WORKSHOP_APP = "431960";
const WORKSHOP_TAGS = ["Video", "Everyone"];
// Ranked by vote, by date, by trend, by subscriptions, by text search.
const QUERY_TYPES = ["0", "1", "3", "9", "12"];
// Workshop results change more often than Pixabay's: an hour.
const WORKSHOP_CACHE_SECONDS = 3600;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (request.method !== "GET") return error(405, "Only GET is supported.");
    if (url.pathname === "/workshop") return workshop(url, request, env, ctx);
    // Whether the app may download Workshop items with the user's Steam: WORKSHOP_DOWNLOADS = "off" pauses them.
    if (url.pathname === "/workshop-status") {
      return json(JSON.stringify({ downloads: env.WORKSHOP_DOWNLOADS !== "off" }), 200, "NONE");
    }
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

// GET /workshop?search_text=&query_type=&page=&numperpage=&days=&tag=&resolution=4k|1440   (all optional)
async function workshop(url, request, env, ctx) {
  if (!env.STEAM_KEY) return error(500, "The proxy has no Steam key.");
  const query = new URLSearchParams();
  const text = (url.searchParams.get("search_text") ?? "").slice(0, 100);
  if (text) query.set("search_text", text);
  const type = url.searchParams.get("query_type") ?? "3";
  query.set("query_type", QUERY_TYPES.includes(type) ? type : "3");
  query.set("page", String(clamp(url.searchParams.get("page"), 1, 1, 100)));
  query.set("numperpage", String(clamp(url.searchParams.get("numperpage"), 30, 3, 50)));
  if (url.searchParams.has("days")) query.set("days", String(clamp(url.searchParams.get("days"), 7, 1, 365)));
  const tags = [...WORKSHOP_TAGS];
  const tag = url.searchParams.get("tag");
  // Workshop tags are words like "Nature" or "Sci-Fi".
  if (tag && /^[A-Za-z0-9 &'-]{1,30}$/.test(tag)) tags.push(tag);
  const resolution = url.searchParams.get("resolution") ?? "";
  if (RESOLUTION_TAGS[resolution]) tags.push(RESOLUTION_TAGS[resolution]);
  tags.forEach((t, i) => query.set(`requiredtags[${i}]`, t));
  (RESOLUTION_EXCLUDED[resolution] ?? []).forEach((t, i) => query.set(`excludedtags[${i}]`, t));
  query.sort();
  const cacheKey = `workshop-creators?${query}`;   // answers with previews and creator names; older entries had neither

  const cached = await env.CACHE?.get(cacheKey);
  if (cached) return json(cached, 200, "HIT");
  if (env.LIMITER) {
    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    const { success } = await env.LIMITER.limit({ key: ip });
    if (!success) return error(429, "Too many searches. Try again in a minute.");
  }

  query.set("appid", WORKSHOP_APP);
  query.set("match_all_tags", "1");
  query.set("return_tags", "1");
  query.set("return_previews", "1");   // extra previews: screenshots and YouTube videos
  query.set("key", env.STEAM_KEY);
  const upstream = await fetch(`${STEAM}?${query}`);
  if (upstream.status === 429) return error(429, "Steam is busy. Try again in a minute.");
  if (!upstream.ok) {
    console.error(`Steam HTTP ${upstream.status}: ${(await upstream.text()).slice(0, 200)}`);
    return error(502, "Steam answered with an error.");
  }
  const body = await withCreatorNames(await upstream.text(), env);
  if (env.CACHE) ctx.waitUntil(env.CACHE.put(cacheKey, body, { expirationTtl: WORKSHOP_CACHE_SECONDS }).catch(() => {}));
  return json(body, 200, "MISS");
}

// Adds `creator_name` (the public Steam profile name) to each item, in one GetPlayerSummaries call for the page.
// When that fails, the answer goes out without names.
async function withCreatorNames(body, env) {
  let data;
  try { data = JSON.parse(body); } catch { return body; }
  const items = data?.response?.publishedfiledetails;
  if (!Array.isArray(items)) return body;
  const ids = [...new Set(items.map((item) => item?.creator).filter((id) => /^\d{1,20}$/.test(id ?? "")))].slice(0, 100);
  if (ids.length === 0) return body;
  try {
    const players = await fetch(`${STEAM_PLAYERS}?key=${encodeURIComponent(env.STEAM_KEY)}&steamids=${ids.join(",")}`);
    if (!players.ok) throw new Error(`HTTP ${players.status}`);
    const names = new Map(((await players.json())?.response?.players ?? []).map((p) => [p.steamid, p.personaname]));
    for (const item of items) {
      const name = names.get(item?.creator);
      if (typeof name === "string" && name.trim()) item.creator_name = name.trim().slice(0, 64);
    }
    return JSON.stringify(data);
  } catch (e) {
    console.error(`Steam player names: ${e.message}`);
    return body;
  }
}

function clamp(value, fallback, min, max) {
  const n = parseInt(value ?? "", 10);
  return Number.isFinite(n) ? Math.min(Math.max(n, min), max) : fallback;
}

function json(body, status, cache) {
  return new Response(body, {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Proxy-Cache": cache },
  });
}

function error(status, message) {
  return json(JSON.stringify({ error: message }), status, "NONE");
}
