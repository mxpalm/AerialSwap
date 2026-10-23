# AerialSwap

Replace one of Apple's built-in Aerial wallpaper videos with your own clip, so macOS plays it
natively (lock screen + desktop) with no background process. Personal use, macOS 27, Apple Silicon.

## Build

```sh
./build.sh --install  # builds and moves AerialSwap.app to /Applications (quit the app first)
./build.sh            # or just build ./AerialSwap.app in the project folder
```

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

The window always shows a video full size, the way the lock screen will: the Aerial you picked on
**Now Playing**, the wallpaper you're previewing in the **Library**, or the new video while you set it up.
On first launch a welcome screen checks this Mac (downloaded Aerials, Enhance detail support, ffmpeg).

**Now Playing** (home) shows what the selected Aerial plays, with a row of every downloaded Aerial and its
status: *Apple original*, your video, or *Reset by macOS*. When macOS has put Apple's video back (usually after
an update), a dialog offers **Reinstall My Video** (AerialSwap keeps a copy of every installed video for this)
or **Keep Apple's**. **Restore Apple's Original…** puts Apple's file back.

1. Drop a video anywhere on the window (or **Add Video**). It plays full size with the lock-screen clock over it.
   Any length works; Apple doesn't require a specific duration.
   Low-resolution videos get a hint: a note for ~720p (about 3x enlargement to fill 4K), and a dialog
   when it's more than 3x (e.g. 736x414), suggesting a higher-quality version, Enhance detail, or upscaling it
   beforehand with a dedicated tool (e.g. Topaz Video AI or Video2X).
   - MP4/MOV with H.264 or HEVC (and AV1 on Macs with an AV1 decoder) are read directly.
   - Anything else (e.g. YouTube's WebM/VP9) needs [ffmpeg](https://ffmpeg.org) (`brew install ffmpeg`).
     AerialSwap asks before converting it into a temporary HEVC file (video only, original size and fps).
     Without ffmpeg it tells you to convert the file yourself.
2. Pick the Aerial it **Replaces**. Only Aerials that are downloaded on this Mac
   are listed. Your current Desktop aerial is preselected (read from `Store/Index.plist`); otherwise the
   screen saver one. The name is what the wallpaper is called in your library.
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
4. **Set as Wallpaper** asks once, then transcodes (progress ring with a time estimate) and installs: Apple's
   original is backed up once, the file is swapped atomically, `WallpaperAgent` is restarted and temp files are
   deleted. **Only save to library** prepares the video without touching any Aerial.
5. Make sure the target Aerial is selected as your wallpaper in System Settings → Wallpaper (the success
   dialog links there).

**Library:** every wallpaper you prepare is kept there. Pick one to preview it full size, then **Use on …** to
switch to it in seconds, without the original file and without converting again. Right-click to delete one;
the wallpaper on screen is not affected. Search filters by name.

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
the Aerial, set it. The library keeps the credit ("<user> on Pixabay"); right-click → **View on Pixabay**.
Only real footage (`video_type=film`) of at least 1920 px width is listed, with SafeSearch on.

Discover needs a Pixabay API key (free at [pixabay.com/api/docs](https://pixabay.com/api/docs/)). AerialSwap uses the
first of:

```sh
defaults write local.aerialswap PixabayKey <key>   # per user
PIXABAY_KEY=<key>                                  # environment
echo <key> > Resources/pixabay.key                 # bundled by build.sh into the app (git-ignored)
```

Pixabay's API terms ask for results to be cached for 24 hours: every search response is kept in
`~/Library/Caches/AerialSwap/discover/` and reused for a day (older ones are deleted on launch, and shown only
when Pixabay can't be reached). The limit is 100 requests per minute per key.

Headless helpers (never touch the aerials folder):

```sh
AerialSwap.app/Contents/MacOS/AerialSwap --list
AerialSwap.app/Contents/MacOS/AerialSwap --transcode in.mp4 out.mov [--fps auto|60|120|240] [--start 0] [--end 30] [--loop 1] [--freeze 60]
AerialSwap.app/Contents/MacOS/AerialSwap --snapshot outDir [TestFootage]   # renders every screen to PNGs with sample data
```

## How it works (findings from macOS 27.0.1)

- Videos live in `~/Library/Application Support/com.apple.wallpaper/aerials/videos/<ASSET-ID>.mov`.
- **xattrs matter.** `WallpaperAerialsExtension` re-downloads any video whose `SourceURL`
  extended attribute doesn't match the manifest URL ("Re-downloading 1 selected video(s) whose URL changed").
  AerialSwap copies `SourceURL`, `LastETag` and `com.apple.quarantine` onto the new file.
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

### Playback behaviour

The lock screen **loops** the video. On unlock the desktop eases to a stop **wherever playback
currently is**, and the next lock continues from there. It does not restart and stop on the last
frame. If you ever need a specific end frame, the CLI's `--freeze <s>` appends a long still of the last
frame (e.g. 60–120 s): any unlock during the hold leaves that frame on the desktop.

## Files

| Path | Purpose |
|---|---|
| `~/Library/Application Support/AerialSwap/backups/<id>.mov.apple-original` | Apple's original (written once, never overwritten) |
| `~/Library/Application Support/AerialSwap/library/` | Your saved wallpapers (`<id>.mov`, `<id>.jpg`, `library.json`) |
| `~/Library/Application Support/AerialSwap/installed/<id>.mov` | Copy of your installed video, for **Reinstall** (deleted on restore) |
| `~/Library/Application Support/AerialSwap/state.json` | What was installed where |
| `~/Library/Logs/AerialSwap.log` | Log |
| `~/Library/Caches/AerialSwap/discover/` | Pixabay search results, kept 24 h |
| `~/Library/Application Support/AerialSwap/tools/` | yt-dlp, deno, ffmpeg when installed without Homebrew |

AerialSwap only writes `videos/<id>.mov` of the selected asset (via a temp file `.<id>.aerialswap-tmp`
in the same folder) and its own folders. It never touches `entries.json`, `manifest.tar`,
`Index.plist`, and never uses sudo.

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

## Manual restore

If the app is gone or something went wrong (replace `<ID>` with the asset ID):

```sh
V=~/Library/Application\ Support/com.apple.wallpaper/aerials/videos
B=~/Library/Application\ Support/AerialSwap/backups
chflags nouchg "$V/<ID>.mov" 2>/dev/null
cp -p "$B/<ID>.mov.apple-original" "$V/<ID>.mov"
killall WallpaperAgent
```

`cp -p` keeps the backup's xattrs. If `SourceURL` is missing, macOS simply re-downloads the original,
which is also fine. Last resort: delete `"$V/<ID>.mov"` and select that Aerial in System Settings to
download it again.

## Known risks

- macOS updates (or a manifest update that changes the asset's URL) can replace the file with Apple's
  version again. The status line then shows *macOS has since reset the file*; just install again.
- Apple may change the wallpaper internals (xattrs, temporal-layer requirement, file layout) in any
  update. Undocumented behaviour, use at your own risk.
- Tested on the desktop: 60 fps (3 temporal layers) and 120 fps (4 layers). 240 fps output has the same
  structure but is untested on the desktop.
- ffmpeg conversion is an extra lossy step (HEVC at 80 Mbps, hardly visible) and drops audio.
  ffmpeg is only used when you agree to it and is never bundled.
