// Tests the proxy without Cloudflare: node Proxy/test.mjs
// Pixabay, KV and the rate limiter are replaced by in-memory fakes.
import assert from "node:assert/strict";
import worker from "./worker.js";

const upstreamCalls = [];
let upstreamStatus = 200;
globalThis.fetch = async (url) => {
  upstreamCalls.push(new URL(url));
  return new Response(upstreamStatus === 200 ? '{"totalHits":1,"hits":[]}' : "[ERROR 400] Invalid or missing API key",
                      { status: upstreamStatus });
};

function makeEnv({ key = "SECRET", limit = 100 } = {}) {
  const kv = new Map();
  let used = 0;
  return {
    PIXABAY_KEY: key,
    CACHE: { get: async (k) => kv.get(k) ?? null, put: async (k, v) => { kv.set(k, v); } },
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

console.log("proxy tests passed");
