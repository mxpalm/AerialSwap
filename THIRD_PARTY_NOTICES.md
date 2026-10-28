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
- **GitHub** (update check): AerialSwap asks the GitHub API at most once a day for the latest release of
  this repository. Nothing about you or your Mac is sent beyond a normal HTTPS request.

## Content you add

Apple's Aerial videos belong to Apple. AerialSwap never copies, changes or redistributes them. You are responsible for having the right to use any video you add, from a file,
a link, or Discover.
