# AerialSwap

Play your own clips as Aerial wallpapers, natively (lock screen + desktop) with no background process. They sit in
their own **AerialSwap** group in System Settings → Wallpaper, next to Apple's Aerials; nothing of Apple's is
replaced. Needs macOS 27 and a Mac with Apple Silicon.

AerialSwap relies on undocumented parts of macOS (see *Known risks*). Use it at your own risk.

## Install

1. Download `AerialSwap-<version>.zip` from [Releases](https://github.com/mxpalm/AerialSwap/releases) and unzip it.
2. Move `AerialSwap.app` to your Applications folder.
3. Open it. The app isn't signed with an Apple Developer ID, so macOS blocks it the first time: click **Done**,
   then go to System Settings → Privacy & Security and click **Open Anyway**.
4. If no Aerial is downloaded yet, choose any Aerial in System Settings → Wallpaper once, then come back.

## Uninstall

Quit AerialSwap, then remove the group from System Settings and its LaunchAgent (this puts Apple's Aerials list
back and deletes AerialSwap's copies in the Aerials folder):

```sh
/Applications/AerialSwap.app/Contents/MacOS/AerialSwap --remove-group
```

Then move the app to the Trash. Your wallpapers stay in `~/Library/Application Support/AerialSwap/`; delete that
folder, `~/Library/Caches/AerialSwap` and `~/Library/Logs/AerialSwap.log` to remove everything. If you deleted
the app first, see *Removing the group without the app*.

## Build

```sh
./build.sh --install  # builds and moves AerialSwap.app to /Applications (quit the app first)
./build.sh            # or just build ./AerialSwap.app in the project folder
./build.sh --zip      # build and pack AerialSwap-<version>.zip for a GitHub release
```

The version comes from the latest git tag (`v1.2` → 1.2, `1.0` without tags), the build number from the
commit count.

Needs only the Command Line Tools (`swift build` + `codesign --sign -`).

The app icon is a Liquid Glass icon: `Resources/AppIcon.icon` (open it in Icon Composer). Its
compiled form, `Resources/Assets.car` plus the `AppIcon.icns` fallback, is committed, so building
needs no Xcode. After changing the icon, recompile with Xcode installed:

```sh
python3 Tools/make_icon.py            # regenerate the artwork from the script, then compile
python3 Tools/make_icon.py --compile  # only compile (keeps edits made in Icon Composer)
```

```sh
open /Applications/AerialSwap.app
```

## Usage

The window always shows a video full size, the way the lock screen will: the wallpaper you're previewing
in the **Library**, the one on your desktop, or the new video while you set it up.
On first launch a welcome screen checks this Mac (downloaded Aerials, Enhance detail support, ffmpeg).

The **Library** (home) lists your wallpapers and opens on the one macOS shows; badges say which one is
*On Desktop* / *On Screen Saver*. Right-click → **Use For** puts a wallpaper on the desktop, the screen saver
or both. Apple's Aerials aren't listed: pick those in System Settings → Wallpaper (⚙ → **Open Wallpaper
Settings**).

1. Drop a video anywhere on the window (or **Add Video**). It plays full size with the lock-screen clock over it.
   Any length works; Apple doesn't require a specific duration.
   Low-resolution videos get a hint: a note for ~720p (about 3x enlargement to fill 4K), and a dialog
   when it's more than 3x (e.g. 736x414), suggesting a higher-quality version, Enhance detail, or upscaling it
   beforehand with a dedicated tool (e.g. Topaz Video AI or Video2X).
   - MP4/MOV with H.264 or HEVC (and AV1 on Macs with an AV1 decoder) are read directly.
   - Anything else (e.g. YouTube's WebM/VP9) needs [ffmpeg](https://ffmpeg.org) (`brew install ffmpeg`).
     AerialSwap asks before converting it into a temporary HEVC file (video only, original size and fps).
     Without ffmpeg it tells you to convert the file yourself.
2. Optional: name it. The name is what the wallpaper is called in your library and in System Settings.
3. Optional: to use only part of the clip, drag the blue handles on the filmstrip at the bottom; the
   preview shows the frame under the handle and then loops the new range. The output frame rate is picked
   automatically (see below).
   **Smooth loop** (on by default) crossfades the clip's last second into its first, so the lock screen
   loop has no visible cut. The result is 1 s shorter; it needs a clip of at least 3 s.
   **Motion** (shown when the video has fewer frames than it could use) generates real in-between frames
   with VideoToolbox's optical-flow frame rate conversion, so the slow-down after unlocking doesn't stutter:
   - *Smooth · 60 fps* (default for 24/30 fps videos): ~2.5x real time to prepare.
   - *Maximum · 120 fps* (also offered for 60 fps videos): twice the frames again, ~3x real time.
   All in-between frames of a pair of source frames come from one optical-flow pass.
   - *Original*: frames as recorded (repeated to fill 60 fps).
   **Enhance detail (experimental)** (opt-in, for videos up to 1080p, including upright phone videos) uses Apple's
   on-device ML upscaler (`VTSuperResolutionScaler`) instead of normal scaling. On test footage text, edges and
   textures came out sharper; on real videos the result varies from clearly sharper to only slightly better,
   so the app shows a warning when it's turned on. It only supports 4x, so 1080p goes via 8K: ~1.25 s per source frame, ~30–40x the clip length.
   macOS downloads the model once (a few seconds). The model output is ~3% darker, so each frame is
   brightness-matched to the original. A noise filter (`VTTemporalNoiseFilter`) was tested too and gave no
   measurable improvement on compressed web videos, so it isn't used.
4. **Set as Wallpaper** asks once, then transcodes (progress ring with a time estimate), saves the video to the
   library, adds it to the AerialSwap group and switches the desktop and screen saver to it. `WallpaperAgent` is
   restarted and temp files are deleted. **Only save to library** prepares the video without changing the
   wallpaper (it still shows up in the group).
5. Only desktop and screen saver choices that already show an Aerial can be switched from the app. If yours
   shows a photo or a color, pick the video in System Settings → Wallpaper → AerialSwap (the success dialog
   says so and links there).

**Library:** every wallpaper you prepare is kept there, and every one is in the AerialSwap group in System
Settings → Wallpaper. Pick one to preview it full size, then **Set as Wallpaper** to switch to it in seconds,
without the original file and without converting again. Right-click to delete one: it leaves the group too, so
if it's on screen, macOS shows something else. Search filters by name. Deleting one in System Settings only
removes its copy there (the tile then can't load); AerialSwap puts it back the next time it opens.

**Add from URL** (**Add Video ⌄ → From URL…** or ⌘⇧O, or drag a link from the browser onto the window): paste a link to a video
file, or a page on YouTube, Vimeo and [many other sites](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md).
Video files are downloaded directly; pages need [yt-dlp](https://github.com/yt-dlp/yt-dlp) (`brew install yt-dlp`),
which fetches the best video-only stream up to 4K (no sound, so nothing is merged). The download lands in the temp
folder and opens like a video you added; YouTube's 4K streams are VP9 or AV1, so Macs without an AV1 decoder get the
usual ffmpeg conversion offer. Only use videos you're allowed to use.
Missing helpers can be installed from the dialog (**Install…**), and ffmpeg also when a video needs converting.
AerialSwap asks first, then uses Homebrew if it's there (`brew install yt-dlp ffmpeg`; Homebrew's yt-dlp brings
deno, which YouTube needs; outdated copies get upgraded). Without Homebrew it downloads the official `yt-dlp_macos`
and deno builds from GitHub and a signed, notarized ffmpeg from [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de)
(there is no official macOS build) into `~/Library/Application Support/AerialSwap/tools/`, ~190 MB, checking each
file against its publisher's SHA-256. That yt-dlp updates itself once a week; that ffmpeg gets macOS's certificate
bundle (`SSL_CERT_FILE=/etc/ssl/cert.pem`), as its static OpenSSL has none.
**Only download … to …** takes a start and/or end time (`1:30`, `90`, `1:02:03`) and fetches just that part, so a
6 s clip of a 10-minute 4K video is ~5 MB instead of ~700 MB. It needs ffmpeg too (yt-dlp uses it to cut the stream
without re-encoding; video files are cut at the nearest keyframe before the start), and shows a spinner instead of a
percentage, as yt-dlp reports the part only when it's done.

**Discover:** free videos from [Pixabay](https://pixabay.com/). Pick a topic (Featured, From Above, Mountains, …)
or search, then pick a video to preview it full size (a smaller version, at least 1280 px wide, is streamed). **Use This Video** downloads
the 4K version (1080p when Pixabay has no 4K) into the temp folder and opens it like a video you added: trim, pick
set it. The library keeps the credit ("<user> on Pixabay"); right-click → **View on Pixabay**.
Only real footage (`video_type=film`) of at least 1920 px width is listed, with SafeSearch on.

Discover needs a Pixabay API key (free at [pixabay.com/api/docs](https://pixabay.com/api/docs/)). Release builds
don't contain one: they search through the Discover proxy, a small Cloudflare Worker that adds the key
(see [`Proxy/README.md`](Proxy/README.md); its address goes in `Resources/discover-proxy.url`). A key of your
own takes precedence over the proxy. AerialSwap uses the first of:

```sh
defaults write io.github.mxpalm.AerialSwap PixabayKey <key>   # per user
PIXABAY_KEY=<key>                                  # environment
echo <key> > Resources/pixabay.key                 # bundled by build.sh into the app (git-ignored)
```

`./build.sh --zip` never bundles the key: anyone who downloads the app could read it from the bundle.

Pixabay's API terms ask for results to be cached for 24 hours: the proxy caches them for everyone, and every search response is also kept in
`~/Library/Caches/AerialSwap/discover/` and reused for a day (older ones are deleted on launch, and shown only
when Pixabay can't be reached). The limit is 100 requests per minute per key.

Headless helpers (`--list`, `--transcode` and `--snapshot` never touch the aerials folder):

```sh
AerialSwap.app/Contents/MacOS/AerialSwap --list
AerialSwap.app/Contents/MacOS/AerialSwap --transcode in.mp4 out.mov [--fps auto|60|120|240] [--start 0] [--end 30] [--loop 1] [--freeze 60]
AerialSwap.app/Contents/MacOS/AerialSwap --snapshot outDir [TestFootage]   # renders every screen to PNGs with sample data
AerialSwap.app/Contents/MacOS/AerialSwap --sync-group     # brings the AerialSwap group in line with the library
AerialSwap.app/Contents/MacOS/AerialSwap --remove-group   # removes the group and its LaunchAgent, puts Apple's manifest back
```

## How it works (findings from macOS 27.0.1)

- Videos live in `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<ASSET-ID>.mov`.
- **xattrs matter.** `WallpaperAerialsExtension` re-downloads any video whose `SourceURL`
  extended attribute doesn't match the manifest URL ("Re-downloading 1 selected video(s) whose URL changed").
  AerialSwap tags its videos with `SourceURL`, `LastETag` and `com.apple.quarantine` like downloaded ones.
- **Temporal layers matter.** On unlock the desktop "ramps down" (slows to a stop). That needs HEVC
  temporal sub-layers with TSA pictures (`tscl` / `tsas` sample groups, like Apple's 240 fps files).
  Without them the ramp fails with `VideoSampleReadingErrors Code=4` and the desktop turns grey.
  AerialSwap encodes with VideoToolbox hierarchical HEVC (`BaseLayerFrameRate` = 15 fps).
- Output format: HEVC Main 10, `hvc1`, 3840×2160, 10-bit 4:2:0, BT.709 primaries/matrix with sRGB
  transfer (same tags as Apple's files), aspect-fill center crop, no audio.
- Encoding rate: 20 Mbps at 60 fps (14 / 26 / 32 Mbps at 30 / 120 / 240 fps), close to Apple's own
  Aerials (~10–12 Mbps at 240 fps). Compared with 30 Mbps on a worst-case detail clip: 32% smaller,
  42 dB PSNR / 0.99 SSIM between the two.
- Output frame rate is automatic: 60 fps for normal video (24/30/60), 120 or 240 fps only when the
  source really has that many frames (e.g. iPhone slo-mo). Upsampling a 30 fps clip to 240 would only
  repeat frames: no smoother slow-down on unlock, but ~4x transcode time and a bigger file.
- HDR sources are converted to SDR. HDR10 (PQ) uses AVFoundation's conversion, which is correct
  (203 nits reference white -> ~90% white). For HLG (iPhone HDR) AVFoundation comes out ~1.5 stops too
  dark, so HLG frames are rendered with Core Image and a tone curve that matches the PQ result
  (mid-tones unchanged, highlights compressed instead of clipped). Measured with synthetic test patches.
- Frame rate conversion: output frame *k* shows the latest source frame at or before *k*/fps, so
  30 → 60 duplicates frames and 240 → 60 drops them; the clip length stays exact.

### The AerialSwap group (findings from macOS 27.2)

- A wallpaper extension of our own isn't possible: the `com.apple.wallpaper` extension point
  (`/System/Library/ExtensionKit/ExtensionPoints/com.apple.wallpaper.appexpt`) requires the private entitlement
  `com.apple.private.wallpaper.extension`.
- The groups in System Settings → Wallpaper (Landscape, Cityscape, …) are the `categories` of
  `aerials/manifest/entries.json`. The group is one more category there, with one asset per library item
  (the asset ID is the library item's ID, the name its file name). Nothing checks a signature on that file.
- Each video is an APFS clone of the library file at `videos/<id>.mov`, and a frame of it is
  `thumbnails/<id>.png` (the group's tile is a copy at `thumbnails/<subcategory id>.png`: the extension keeps
  subcategory previews under their own ID), all tagged with `SourceURL` = the manifest's URL
  (`https://aerialswap.invalid/<id>.mov` / `.png`), so the extension treats them as downloaded and never fetches
  anything. That prefix is how AerialSwap tells its own entries and files from Apple's.
- **The version matters.** `WallpaperAerialsExtension` also has a manifest of its own
  (`WallpaperAerialsExtension.appex/Contents/Resources/entries.json`) and uses the one with the higher `version`;
  on a tie, the downloaded one. On 27.2 the bundled one is version 2 and the downloaded one version 1, so the
  downloaded file was ignored (log: `Loading fallback manifest`). The written manifest gets at least the bundled
  version (log: `Loading downloaded manifest`). It's built on Apple's downloaded manifest, kept in
  `group/apple-entries.json`: the URLs of Apple's Aerials stay the ones their files are tagged with.
- The extension reads entries.json only when it starts, so a change restarts `WallpaperAerialsExtension` and
  `WallpaperAgent`.
- When macOS downloads a new manifest it replaces entries.json and the group is gone. A LaunchAgent
  (`~/Library/LaunchAgents/io.github.mxpalm.AerialSwap.group.plist`) watches the file and runs `AerialSwap --sync-group`,
  which adds the group back and restarts WallpaperAgent. It also runs at login. It's not a background process:
  launchd starts it on a change, and it exits. If the group has been removed 3 times within 10 minutes, it stops
  adding it (log: "removed the AerialSwap group 3 times") until AerialSwap is opened. The app syncs at launch,
  whenever it becomes active, and after each library change. It installs the agent again if the app moved.
- Tested: the group shows up with the right names and thumbnails, and the videos play on the desktop and lock screen.
  They also ease to a stop on unlock like Apple's.

### Playback behaviour

The lock screen **loops** the video. On unlock the desktop eases to a stop **wherever playback
currently is**, and the next lock continues from there. It does not restart and stop on the last
frame. If you ever need a specific end frame, the CLI's `--freeze <s>` appends a long still of the last
frame (e.g. 60–120 s): any unlock during the hold leaves that frame on the desktop.

## Files

| Path | Purpose |
|---|---|
| `~/Library/Application Support/AerialSwap/library/` | Your saved wallpapers (`<id>.mov`, `<id>.jpg`, `library.json`). If `library.json` can't be read, it's kept as `library.json.unreadable-<time>` and rebuilt from the videos (as "Recovered wallpaper") |
| `~/Library/Application Support/AerialSwap/group/apple-entries.json` | Apple's downloaded Aerials manifest, which the group is built on and which `--remove-group` puts back |
| `~/Library/LaunchAgents/io.github.mxpalm.AerialSwap.group.plist` | Adds the group back after macOS replaced the manifest (`--sync-group`) |
| `~/Library/Application Support/AerialSwap/Index.plist.before-change` | `Store/Index.plist` as it was before the last desktop / screen saver switch |
| `~/Library/Logs/AerialSwap.log` | Log |
| `~/Library/Caches/AerialSwap/discover/` | Pixabay search results, kept 24 h |
| `~/Library/Application Support/AerialSwap/tools/` | yt-dlp, deno, ffmpeg when installed without Homebrew |

AerialSwap writes its own folders, `entries.json`, and its own videos and thumbnails tagged with
`https://aerialswap.invalid/` (via a temp file and rename). Only files with that tag are ever deleted; Apple's
videos are never touched. It writes the `assetID` inside `Store/Index.plist`'s existing Aerial choices when you switch the
desktop or screen saver. It never touches `manifest.tar` and never uses sudo.

## Testing

A repeatable test suite checks every module with synthetic footage (needs ffmpeg, test-only):

```sh
Tools/testsuite/generate.sh       # once: 23 clips into TestFootage/ (git-ignored, ~260 MB, ~35 s)
Tools/testsuite/run.py --quick    # ~3 min, skips 4K sources and Enhance detail
Tools/testsuite/run.py            # all 30 cases, ~6 min
Tools/testsuite/run.py -k hdr     # only matching cases
```

Footage: 720p (24/30/60 fps), 1080p (24/30/60/120/240), 4K (24/30/60/120), 21:9 widescreen, 736x414,
a 2 s clip, an upright phone video, HDR10 and HLG gray patches (also rotated), and a procedural landscape for
Enhance detail. Each output is checked for format (HEVC Main 10, hvc1, 3840x2160, 10-bit, no audio, color
tags, temporal-layer sample groups), automatic frame rate, exact frame count with and without Smooth loop,
repeated frames with Smooth motion (< 5%), HDR patch levels, orientation, and Enhance detail brightness.
The suite only writes to `TestFootage/out/`, never to the aerials folder.

## Removing the group without the app

Put Apple's manifest back, delete AerialSwap's copies and restart:


```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/io.github.mxpalm.AerialSwap.group.plist; rm ~/Library/LaunchAgents/io.github.mxpalm.AerialSwap.group.plist
A=~/Library/Application\ Support/com.apple.wallpaper/aerials
cp ~/Library/Application\ Support/AerialSwap/group/apple-entries.json "$A/manifest/entries.json"
for f in "$A"/videos/*.mov "$A"/thumbnails/*.png; do
  xattr -p SourceURL "$f" 2>/dev/null | grep -q '^https://aerialswap.invalid/' && rm "$f"
done
killall WallpaperAerialsExtension WallpaperAgent
```

## Known risks

- The group relies on undocumented internals: the manifest format, the `version` comparison with the bundled
  manifest, and the extension accepting assets it didn't download. A macOS update can change any of these;
  then the group is gone and the library still has every video. While the group is in entries.json, Aerials that
  only Apple's bundled manifest lists (none on 27.2) don't show up.
- Apple may change the wallpaper internals (xattrs, temporal-layer requirement, file layout) in any
  update. Undocumented behaviour, use at your own risk. On a macOS major version newer than the tested one
  (`AerialStore.testedMajorVersion`, 27), the Set as Wallpaper confirmation says so.
- Tested on the desktop: 60 fps (3 temporal layers) and 120 fps (4 layers). 240 fps output has the same
  structure but is untested on the desktop.
- ffmpeg conversion is an extra lossy step (HEVC at 80 Mbps, hardly visible) and drops audio.
  ffmpeg is only used when you agree to it and is never bundled.

## Releases and updates

1. Tag the version and build the zip:
   ```sh
   git tag v1.1
   ./build.sh --zip
   ```
2. Publish `AerialSwap-1.1.zip` as a GitHub release for tag `v1.1`, e.g.
   `gh release create v1.1 AerialSwap-1.1.zip`.

Once a day the app asks GitHub for the latest release of `mxpalm/AerialSwap`. When a newer one exists, it
shows a notice and a **Download AerialSwap x.y…** item in the ⚙ menu. **Check for Updates…** (⚙ menu and
the app menu) checks right away. The check only works while the repository is public; a private repo or a
repo without releases finds nothing.

By default the app is ad-hoc signed, not with a Developer ID, so macOS blocks a downloaded copy on first open.
To open it, try once, then go to System Settings → Privacy & Security and click **Open Anyway**. An update is a
manual download: quit AerialSwap, replace the app in `/Applications`, open it the same way.

With an Apple Developer account, `build.sh` signs with your Developer ID and the hardened runtime instead, and
`--zip` notarizes and staples the app, so it opens without the warning:

```sh
xcrun notarytool store-credentials AerialSwap --apple-id <you@example.com> --team-id <TEAMID>   # once
SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)" NOTARY_PROFILE=AerialSwap ./build.sh --zip
```

Then drop step 3 of *Install* above.

## License

MIT, see `LICENSE`. Helpers and services AerialSwap can use (yt-dlp, deno, FFmpeg, Homebrew, Pixabay,
GitHub) keep their own licenses and terms, see `THIRD_PARTY_NOTICES.md`.
