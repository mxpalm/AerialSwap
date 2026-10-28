# Discover proxy

A Cloudflare Worker that forwards AerialSwap's Discover searches to the Pixabay API and adds the API key.
The key is a Cloudflare secret, so release builds of the app don't carry one.

```
AerialSwap  --GET /videos?q=ocean&...-->  Worker (+ key)  -->  pixabay.com/api/videos/
            <--------- JSON --------------  24 h KV cache
```

- Only the search parameters AerialSwap sends are forwarded; `per_page` is capped at 50.
- Responses are cached for 24 hours in Workers KV, as Pixabay's API terms ask, so repeated searches from any
  user don't reach Pixabay (it allows 100 requests a minute per key).
- Each IP gets 30 uncached searches a minute.
- Pixabay's errors are logged, not passed on, so the app never sees a key-related message.
- Video files don't go through the proxy: the app downloads them directly from Pixabay's CDN.

Cloudflare's free plan covers this: 100,000 requests a day, plus KV's 100,000 reads and 1,000 writes a
day. Past 1,000 new searches a day, results are simply not cached until the next day.

## Set up (once)

Needs a free Cloudflare account and Node.js. Run these in this folder:

```sh
npx wrangler login                       # opens the browser to sign in
npx wrangler kv namespace create CACHE   # paste the printed id into wrangler.toml
npx wrangler secret put PIXABAY_KEY      # paste your Pixabay API key
npx wrangler deploy                      # prints https://aerialswap-discover.<account>.workers.dev
```

Then point the app at it and rebuild:

```sh
echo https://aerialswap-discover.<account>.workers.dev > ../Resources/discover-proxy.url
../build.sh --zip
```

The address isn't secret, so `Resources/discover-proxy.url` can be committed. build.sh writes it into the app's
Info.plist as `DiscoverProxyURL`. Builds that have their own key (`defaults write local.aerialswap PixabayKey`,
`PIXABAY_KEY`, or `Resources/pixabay.key`) still ask Pixabay directly.

Check it:

```sh
curl -i "https://aerialswap-discover.<account>.workers.dev/videos?q=ocean&per_page=3"   # X-Proxy-Cache: MISS, then HIT
npx wrangler tail                                                                      # live log
```

To change the key: `npx wrangler secret put PIXABAY_KEY` again. No app update is needed.

## Test

```sh
node test.mjs   # Pixabay, KV and the rate limiter are faked; no Cloudflare account needed
```
