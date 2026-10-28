#!/bin/zsh
# Builds AerialSwap.app with SwiftPM (no Xcode needed) and ad-hoc signs it.
#   ./build.sh            build ./AerialSwap.app
#   ./build.sh --install  build and move it to /Applications (keeps a single copy)
#   ./build.sh --zip      build and pack AerialSwap-<version>.zip for a GitHub release
# The version is the latest git tag (v1.2 -> 1.2), the build number the commit count.
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=false
ZIP=false
[[ "${1:-}" == "--install" ]] && INSTALL=true
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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AerialSwap</string>
    <key>CFBundleDisplayName</key><string>AerialSwap</string>
    <key>CFBundleIdentifier</key><string>local.aerialswap</string>
    <key>CFBundleExecutable</key><string>AerialSwap</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
    $PROXY_ENTRY
</dict>
</plist>
PLIST

# Ad-hoc signature, no sandbox entitlements (needs access to ~/Library/Application Support/com.apple.wallpaper).
codesign --force --sign - "$APP"

if $ZIP; then
    ZIPFILE="AerialSwap-$VERSION.zip"
    rm -f "$ZIPFILE"
    ditto -c -k --keepParent "$APP" "$ZIPFILE"   # ditto keeps the signature and bundle metadata intact
    echo "Packed $(pwd)/$ZIPFILE (version $VERSION, build $BUILD)"
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

echo "Built $(pwd)/$APP"
if pgrep -x AerialSwap >/dev/null; then
    echo "Note: AerialSwap is still running the previous build. Quit it (Cmd-Q) and reopen to use this one."
fi
