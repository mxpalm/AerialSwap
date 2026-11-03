# Discover proxy

A Cloudflare Worker that forwards AerialSwap's Discover searches to the Pixabay API and to Steam's Workshop search,
and adds the API keys. The keys are Cloudflare secrets, so release builds of the app don't carry one. It also holds
the switch that pauses Download with Steam for everyone.

```
AerialSwap  --GET /videos?q=ocean&...-->  Worker (+ key)  -->  pixabay.com/api/videos/
            <--------- JSON --------------  24 h KV cache

AerialSwap  --GET /workshop?search_text=&...-->  Worker (+ STEAM_KEY)  -->  api.steampowered.com/IPublishedFileService/QueryFiles/v1/
            <--------- JSON ------------------  1 h KV cache

AerialSwap  --GET /workshop-status-->  Worker  -->  {"downloads": true}   (WORKSHOP_DOWNLOADS in wrangler.toml)
```

- Only the search parameters AerialSwap sends are forwarded; `per_page` is capped at 50.
- Responses are cached for 24 hours in Workers KV, as Pixabay's API terms ask, so repeated searches from any
  user don't reach Pixabay (it allows 100 requests a minute per key).
- Each IP gets 30 uncached searches a minute.
- Pixabay's errors are logged, not passed on, so the app never sees a key-related message.
- Video files don't go through the proxy: the app downloads them directly from Pixabay's CDN.

`/workshop` (Wallpaper Engine's Workshop, app 431960):
- Always asks for app 431960 with the required tags `Video` and `Everyone`, whatever the app sends; `tag` adds one
  more (letters, digits, spaces, `&`, `'` and `-`, at most 30 characters).
- Only `search_text` (100 characters), `query_type` (0, 1, 3, 9, 12; else 3), `days` (1-365), `page` (1-100) and
  `numperpage` (3-50) are forwarded.
- Always with `return_tags` and `return_previews` (extra screenshots and YouTube preview ids).
- `resolution=4k` adds the tag `3840 x 2160` (4K only).
- Each item gets `creator_name`, its creator's public Steam profile name, from one `ISteamUser/GetPlayerSummaries`
  call per page (skipped when that fails).
- Cached for an hour in KV; the same per-IP limit as `/videos`.
- Without the `STEAM_KEY` secret it answers 500, and the app shows that Workshop search doesn't work.
- Workshop files never go through the proxy, and neither does the app's download: the user's own Steam downloads them.

`/workshop-status` answers `{"downloads": false}` when `WORKSHOP_DOWNLOADS = "off"`, else `{"downloads": true}`.
The app asks before each Download with Steam and refuses to start when it's off. When the proxy can't be reached,
downloads stay on.

Cloudflare's free plan covers this: 100,000 requests a day, plus KV's 100,000 reads and 1,000 writes a
day. Past 1,000 new searches a day, results are simply not cached until the next day.

## Set up (once)

Needs a free Cloudflare account and Node.js. Run these in this folder:

```sh
npx wrangler login                       # opens the browser to sign in
npx wrangler kv namespace create CACHE   # paste the printed id into wrangler.toml
npx wrangler secret put PIXABAY_KEY      # paste your Pixabay API key
npx wrangler secret put STEAM_KEY        # paste a Steam Web API key (steamcommunity.com/dev/apikey)
npx wrangler deploy                      # prints https://aerialswap-discover.<account>.workers.dev
```

Then point the app at it and rebuild:

```sh
echo https://aerialswap-discover.<account>.workers.dev > ../Resources/discover-proxy.url
../build.sh --zip
```

The address isn't secret, so `Resources/discover-proxy.url` can be committed. build.sh writes it into the app's
Info.plist as `DiscoverProxyURL`. Builds that have their own key (`defaults write io.github.mxpalm.AerialSwap PixabayKey`,
`PIXABAY_KEY`, or `Resources/pixabay.key`) still ask Pixabay directly.

Check it:

```sh
curl -i "https://aerialswap-discover.<account>.workers.dev/videos?q=ocean&per_page=3"   # X-Proxy-Cache: MISS, then HIT
curl -i "https://aerialswap-discover.<account>.workers.dev/workshop?search_text=ocean&query_type=12&numperpage=3"
npx wrangler tail                                                                      # live log
```

To change a key: `npx wrangler secret put PIXABAY_KEY` (or `STEAM_KEY`) again. No app update is needed.
The Steam key belongs to the Steam account that created it; never commit or print it.

## Pause Download with Steam

If Valve or Wallpaper Engine's developer objects, or Steam starts refusing downloads, switch them off for every
copy of the app, without an update:

```sh
# in wrangler.toml: [vars] WORKSHOP_DOWNLOADS = "off"
npx wrangler deploy
curl https://aerialswap-discover.<account>.workers.dev/workshop-status   # {"downloads":false}
```

Set it back to `"on"` and deploy again to resume. Workshop search keeps working; to stop that too, delete the key
with `npx wrangler secret delete STEAM_KEY`. See "Steam Workshop downloads" in `docs/TECHNICAL.md`.

## Test

```sh
node test.mjs   # Pixabay, Steam, KV and the rate limiter are faked; no Cloudflare account needed
```
