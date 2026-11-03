# Third-party notices

AerialSwap itself is MIT-licensed (see `LICENSE`). It bundles no third-party code. The programs and
services below are only used when you ask for them, and they keep their own licenses and terms.

## Helper programs (installed on request, never bundled)

When you agree to install helpers, AerialSwap runs Homebrew or downloads the official builds into
`~/Library/Application Support/AerialSwap/tools/` and runs them as separate processes.

| Program | Used for | License | Source |
|---|---|---|---|
| [yt-dlp](https://github.com/yt-dlp/yt-dlp) | Downloading videos from web pages | The Unlicense (public domain) | github.com/yt-dlp/yt-dlp |
| [deno](https://deno.com) | JavaScript runtime that yt-dlp needs for YouTube | MIT | github.com/denoland/deno |
| [FFmpeg](https://ffmpeg.org) | Converting formats macOS can't read; cutting parts of downloads | LGPL-2.1-or-later, or GPL when built with GPL parts. Check the build you have with `ffmpeg -L` | ffmpeg.org; macOS builds from ffmpeg.martin-riedl.de |
| [Homebrew](https://brew.sh) | Installing the helpers when it's already on your Mac | BSD-2-Clause | github.com/Homebrew/brew |

## Services

- **Pixabay** (Discover): search results come from the [Pixabay API](https://pixabay.com/api/docs/), in release
  builds through AerialSwap's Discover proxy on Cloudflare Workers (`Proxy/`), which only adds the API key and
  caches results; it sees your search terms and IP address like any web server, and stores only the results,
  not who searched.
  The videos are under the [Pixabay Content License](https://pixabay.com/service/license-summary/).
  AerialSwap keeps each video's credit ("<user> on Pixabay") in the library.
- **GitHub** (updates): AerialSwap asks the GitHub API at most once a day for the latest release of
  this repository, and downloads it from there when you choose **Update**. Nothing about you or your Mac is sent
  beyond a normal HTTPS request.

- **Wallpaper Engine / Steam Workshop** (Add Video → From Wallpaper Engine, Discover → Workshop): AerialSwap
  reads video wallpapers that the user's own Steam downloaded. Discover → Workshop searches the Workshop through
  Steam's Web API (via the Discover proxy, which holds the Steam Web API key; only the search words, topic, sort,
  filters and page are sent), and **Download with Steam** asks the user's own Steam for Mac to download an item, using the Steamworks
  library (`libsteam_api.dylib`) that comes with Steam. AerialSwap doesn't bundle, change or redistribute any
  Valve code, never sees the Steam login, and before each download asks the proxy only whether downloads are
  switched on. This isn't an official Valve or Wallpaper Engine feature; see "Steam Workshop downloads" in
  docs/TECHNICAL.md. Workshop wallpapers belong to their creators; use them only for yourself and don't share the
  results. Wallpaper Engine is a trademark of Wallpaper Engine Team, Steam a trademark of Valve Corporation;
  AerialSwap is an independent app, not affiliated with either.

## Content you add

Apple's Aerial videos belong to Apple. AerialSwap never copies, changes or redistributes them. You are responsible for having the right to use any video you add, from a file,
a link, or Discover.
