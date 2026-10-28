#!/bin/zsh
# Builds AerialSwap.app with SwiftPM (no Xcode needed) and ad-hoc signs it.
#   ./build.sh            build ./AerialSwap.app
#   ./build.sh --install  build and move it to /Applications (keeps a single copy)
#   ./build.sh --test     build ./AerialSwap.app as a test copy and open it (leaves the LaunchAgent on /Applications)
#   ./build.sh --zip      build and pack AerialSwap-<version>.zip (+ .sig, for in-app updates) for a GitHub release
# With SIGN_IDENTITY="Developer ID Application: …" it's signed with that identity and the hardened runtime instead of
# ad-hoc; --zip then also notarizes and staples it when NOTARY_PROFILE names a `notarytool store-credentials` profile.
# The version is the latest git tag (v1.2 -> 1.2), the build number the commit count.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=false
ZIP=false
TEST=false
[[ "${1:-}" == "--install" ]] && INSTALL=true
[[ "${1:-}" == "--test" ]] && TEST=true
[[ "${1:-}" == "--zip" ]] && ZIP=true
VERSION="$( (git describe --tags --abbrev=0 2>/dev/null || true) | sed 's/^v//')"
VERSION="${VERSION:-1.0}"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
if $INSTALL && pgrep -x AerialSwap >/dev/null; then
    echo "AerialSwap is running. Quit it (Cmd-Q) first so a running transcode isn't interrupted." >&2
    exit 1
fi

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AerialSwap"

APP="AerialSwap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AerialSwap"
# Liquid Glass icon (Assets.car) plus .icns fallback, compiled from Resources/AppIcon.icon by Tools/make_icon.py.
cp Resources/Assets.car "$APP/Contents/Resources/Assets.car"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Optional Pixabay API key for Discover (git-ignored; see README). Never in a release zip: anyone could read it there.
if ! $ZIP && [[ -f Resources/pixabay.key ]]; then cp Resources/pixabay.key "$APP/Contents/Resources/pixabay.key"; fi

# Discover proxy address (Proxy/README.md), not secret, so it may be committed. Searches use it when the app has no key.
PROXY_ENTRY=""
if [[ -f Resources/discover-proxy.url ]]; then
    PROXY_ENTRY="<key>DiscoverProxyURL</key><string>$(tr -d '[:space:]' < Resources/discover-proxy.url)</string>"
fi
# A test copy must not point the group LaunchAgent at itself (see GroupWatcher.install).
TEST_ENTRY=""
if $TEST; then TEST_ENTRY="<key>AerialSwapTestBuild</key><true/>"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AerialSwap</string>
    <key>CFBundleDisplayName</key><string>AerialSwap</string>
    <key>CFBundleIdentifier</key><string>io.github.mxpalm.AerialSwap</string>
    <key>CFBundleExecutable</key><string>AerialSwap</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
    $PROXY_ENTRY
    $TEST_ENTRY
</dict>
</plist>
PLIST

# No sandbox entitlements (needs access to ~/Library/Application Support/com.apple.wallpaper).
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"   # ad-hoc
fi

if $ZIP; then
    ZIPFILE="AerialSwap-$VERSION.zip"
    rm -f "$ZIPFILE"
    ditto -c -k --keepParent "$APP" "$ZIPFILE"   # ditto keeps the signature and bundle metadata intact
    if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "$ZIPFILE" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm -f "$ZIPFILE"
        ditto -c -k --keepParent "$APP" "$ZIPFILE"   # again, now with the notarization ticket in the app
        echo "Notarized and stapled"
    elif [[ -n "${SIGN_IDENTITY:-}" ]]; then
        echo "Note: signed but not notarized (set NOTARY_PROFILE); Gatekeeper still blocks it on first open." >&2
    fi
    # The app installs updates only with a valid signature from the release key (Updater.swift); the key is in the
    # Keychain as "AerialSwap release key" (see docs/TECHNICAL.md, "Releases and updates").
    if ! RELEASE_KEY="$(security find-generic-password -s "AerialSwap release key" -w 2>/dev/null)"; then
        echo "No \"AerialSwap release key\" in the Keychain, so $ZIPFILE can't be signed for in-app updates." >&2
        exit 1
    fi
    swiftc -O -o .build/release_key Tools/release_key.swift
    print -r -- "$RELEASE_KEY" | .build/release_key sign "$ZIPFILE" > "$ZIPFILE.sig"
    unset RELEASE_KEY
    echo "Packed $(pwd)/$ZIPFILE and $ZIPFILE.sig (version $VERSION, build $BUILD)"
    exit 0
fi

if $INSTALL; then
    # Move instead of copy: two bundles with the same identifier confuse LaunchServices.
    rm -rf "/Applications/$APP"
    mv "$APP" "/Applications/$APP"
    touch "/Applications/$APP"   # refresh the Dock/Finder icon cache
    echo "Installed /Applications/$APP"
    exit 0
fi

if $TEST; then
    open -n "$APP"   # -n: a separate instance, even while the installed copy runs
    echo "Opened test build $(pwd)/$APP"
    exit 0
fi

echo "Built $(pwd)/$APP"
if pgrep -x AerialSwap >/dev/null; then
    echo "Note: AerialSwap is still running the previous build. Quit it (Cmd-Q) and reopen to use this one."
fi
