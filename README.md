# AerialSwap

Replace one of Apple's built-in Aerial wallpaper videos with your own clip, so macOS plays it
natively (lock screen + desktop) with no background process. Personal use, macOS 27, Apple Silicon.

## Build

```sh
./build.sh            # needs only the Command Line Tools (swift build + codesign --sign -)
open AerialSwap.app
```

## Usage

1. Drop a video on the window (or **Choose…**). Duration and resolution are shown with a preview.
   Any length works; Apple doesn't require a specific duration.
   - MP4/MOV with H.264 or HEVC (and AV1 on Macs with an AV1 decoder) are read directly.
   - Anything else (e.g. YouTube's WebM/VP9) needs [ffmpeg](https://ffmpeg.org) (`brew install ffmpeg`).
     AerialSwap asks before converting it into a temporary HEVC file (video only, original size and fps).
     Without ffmpeg it tells you to convert the file yourself.
2. Pick the **Target Aerial** (shown with its thumbnail). Only Aerials that are downloaded on this Mac
   are listed. Your current Desktop aerial is preselected (read from `Store/Index.plist`); otherwise the
   screen saver one.
3. Optional: to use only part of the clip, click **Trim…** for QuickTime's trim bar on the preview,
   or type start/end seconds into **Trim**. The output frame rate is picked automatically (see below).
4. **Set as Wallpaper…** asks once, then transcodes (with a time estimate) and installs: Apple's original
   is backed up once, the file is swapped atomically, `WallpaperAgent` is restarted and temp files are deleted.
5. Make sure the target Aerial is selected as your wallpaper in System Settings → Wallpaper.

**Restore original** puts Apple's file back. Each row shows whether the asset is *Original*,
*Replaced*, or *Was replaced, but macOS has since reset the file*. In the last case **Reinstall**
puts your video back with one click (AerialSwap keeps a copy of every installed video for this).

Headless helpers (never touch the aerials folder):

```sh
AerialSwap.app/Contents/MacOS/AerialSwap --list
AerialSwap.app/Contents/MacOS/AerialSwap --transcode in.mp4 out.mov [--fps auto|60|120|240] [--start 0] [--end 30] [--freeze 60]
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
| `~/Library/Application Support/AerialSwap/installed/<id>.mov` | Copy of your installed video, for **Reinstall** (deleted on restore) |
| `~/Library/Application Support/AerialSwap/state.json` | What was installed where |
| `~/Library/Logs/AerialSwap.log` | Log |

AerialSwap only writes `videos/<id>.mov` of the selected asset (via a temp file `.<id>.aerialswap-tmp`
in the same folder) and its own folders. It never touches `entries.json`, `manifest.tar`,
`Index.plist`, and never uses sudo.

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
- Tested on the desktop so far: 60 fps (3 temporal layers). 120/240 fps output has 4 layers but is untested on the desktop.
- ffmpeg conversion is an extra lossy step (HEVC at 80 Mbps, hardly visible) and drops audio.
  ffmpeg is only used when you agree to it and is never bundled.
