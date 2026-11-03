// Tests the proxy without Cloudflare: node Proxy/test.mjs
// Pixabay, KV and the rate limiter are replaced by in-memory fakes.
import assert from "node:assert/strict";
import worker from "./worker.js";

const upstreamCalls = [];
let upstreamStatus = 200;
const workshopBody = JSON.stringify({ response: { total: 2, publishedfiledetails: [
  { publishedfileid: "1", title: "A", creator: "76561198000000001" },
  { publishedfileid: "2", title: "B", creator: "76561198000000002" },
] } });
const playersBody = JSON.stringify({ response: { players: [{ steamid: "76561198000000001", personaname: " Abi Toads " }] } });
globalThis.fetch = async (url) => {
  const target = new URL(url);
  upstreamCalls.push(target);
  if (upstreamStatus !== 200) return new Response("[ERROR 400] Invalid or missing API key", { status: upstreamStatus });
  if (target.pathname.includes("QueryFiles")) return new Response(workshopBody);
  if (target.pathname.includes("GetPlayerSummaries")) return new Response(playersBody);
  return new Response('{"totalHits":1,"hits":[]}');
};

function checkKey(k) {
  if (new TextEncoder().encode(k).length > 512) throw new Error(`KV key too long: ${k.length}`);
}

function makeEnv({ key = "SECRET", limit = 100 } = {}) {
  const kv = new Map();
  let used = 0;
  return {
    PIXABAY_KEY: key,
    // Like Workers KV: keys longer than 512 bytes throw.
    CACHE: {
      get: async (k) => { checkKey(k); return kv.get(k) ?? null; },
      put: async (k, v) => { checkKey(k); kv.set(k, v); },
    },
    LIMITER: { limit: async () => ({ success: ++used <= limit }) },
  };
}
const ctx = { waitUntil: (p) => p };
const get = (env, path, init) => worker.fetch(new Request(`https://proxy.example${path}`, init), env, ctx);

// Forwards only allowed parameters, adds the key, clamps per_page, never returns the key.
let env = makeEnv();
let r = await get(env, "/videos?q=ocean&per_page=500&key=STOLEN&callback=x");
assert.equal(r.status, 200);
assert.equal(r.headers.get("X-Proxy-Cache"), "MISS");
const sent = upstreamCalls.at(-1);
assert.equal(sent.searchParams.get("key"), "SECRET");
assert.equal(sent.searchParams.get("per_page"), "50");
assert.equal(sent.searchParams.get("callback"), null);
// Pixabay's category is forwarded.
await get(env, "/videos?q=&category=nature");
assert.equal(upstreamCalls.at(-1).searchParams.get("category"), "nature");
assert.ok(!(await r.text()).includes("SECRET"));

// The same search (parameters in another order) comes from the cache and doesn't count against the limit.
const before = upstreamCalls.length;
r = await get(env, "/videos?per_page=50&q=ocean");
assert.equal(r.headers.get("X-Proxy-Cache"), "HIT");
assert.equal(upstreamCalls.length, before);

// Rate limit applies to uncached searches.
env = makeEnv({ limit: 1 });
assert.equal((await get(env, "/videos?q=a")).status, 200);
assert.equal((await get(env, "/videos?q=b")).status, 429);

// Pixabay errors become 502 without Pixabay's text; other paths, methods and a missing key are refused.
upstreamStatus = 400;
r = await get(makeEnv(), "/videos?q=c");
assert.equal(r.status, 502);
assert.ok(!(await r.text()).includes("API key"));
upstreamStatus = 200;
assert.equal((await get(makeEnv(), "/other")).status, 404);
assert.equal((await get(makeEnv(), "/videos", { method: "POST" })).status, 405);
assert.equal((await get(makeEnv({ key: "" }), "/videos?q=d")).status, 500);

// Works without KV and limiter bindings.
r = await worker.fetch(new Request("https://proxy.example/videos?q=e"), { PIXABAY_KEY: "SECRET" }, ctx);
assert.equal(r.status, 200);

// Workshop: the Steam key and the fixed app and tags are added; other parameters are dropped or clamped.
env = makeEnv();
env.STEAM_KEY = "STEAMSECRET";
r = await get(env, "/workshop?search_text=ocean&numperpage=500&appid=1&key=STOLEN&tag=Nature&query_type=99&requiredtags[0]=Mature");
assert.equal(r.status, 200);
const steam = upstreamCalls.findLast((u) => u.pathname.includes("QueryFiles"));
assert.equal(steam.origin + steam.pathname, "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/");
assert.equal(steam.searchParams.get("key"), "STEAMSECRET");
assert.equal(steam.searchParams.get("appid"), "431960");
assert.equal(steam.searchParams.get("numperpage"), "50");
assert.equal(steam.searchParams.get("query_type"), "3");
assert.equal(steam.searchParams.get("requiredtags[0]"), "Video");
assert.equal(steam.searchParams.get("requiredtags[1]"), "Everyone");
assert.equal(steam.searchParams.get("requiredtags[2]"), "Nature");
assert.equal(steam.searchParams.get("return_previews"), "1");
// Creator names come from one GetPlayerSummaries call; items without a public name stay without one.
const players = upstreamCalls.at(-1);
assert.equal(players.searchParams.get("steamids"), "76561198000000001,76561198000000002");
const enriched = JSON.parse(await (await get(env, "/workshop?numperpage=500&tag=Nature&query_type=99&search_text=ocean")).text());
assert.equal(enriched.response.publishedfiledetails[0].creator_name, "Abi Toads");
assert.equal(enriched.response.publishedfiledetails[1].creator_name, undefined);
// resolution=4k adds the 4K tag after the topic's; other values are ignored.
await get(env, "/workshop?tag=Nature&resolution=4k");
let q = upstreamCalls.findLast((u) => u.pathname.includes("QueryFiles"));
assert.equal(q.searchParams.get("requiredtags[3]"), "3840 x 2160");
await get(env, "/workshop?resolution=8k&page=2");
q = upstreamCalls.findLast((u) => u.pathname.includes("QueryFiles"));
assert.equal(q.searchParams.get("requiredtags[2]"), null);
// resolution=1440 excludes the resolution tags below 1440p instead.
await get(env, "/workshop?resolution=1440&page=3");
q = upstreamCalls.findLast((u) => u.pathname.includes("QueryFiles"));
assert.equal(q.searchParams.get("requiredtags[2]"), null);
assert.equal(q.searchParams.get("excludedtags[0]"), "1920 x 1080");
assert.equal(q.searchParams.get("excludedtags[10]"), "Other resolution");
// Its cache key is too long for KV as is: hashed, and the second request is a hit.
assert.equal((await get(env, "/workshop?resolution=1440&page=3")).headers.get("X-Proxy-Cache"), "HIT");
assert.ok(!(await r.text()).includes("STEAMSECRET"));
assert.equal((await get(env, "/workshop?numperpage=500&tag=Nature&query_type=99&search_text=ocean")).headers.get("X-Proxy-Cache"), "HIT");
// A tag with odd characters is ignored; without a Steam key the route refuses.
await get(env, "/workshop?tag=%3Cscript%3E");
assert.equal(upstreamCalls.at(-1).searchParams.get("requiredtags[2]"), null);
assert.equal((await get(makeEnv(), "/workshop")).status, 500);

// The download switch: on unless WORKSHOP_DOWNLOADS is "off".
assert.deepEqual(await (await get(makeEnv(), "/workshop-status")).json(), { downloads: true });
assert.deepEqual(await (await get({ ...makeEnv(), WORKSHOP_DOWNLOADS: "off" }, "/workshop-status")).json(), { downloads: false });

console.log("proxy tests passed");
