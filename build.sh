#!/bin/zsh
# Builds AerialSwap.app with SwiftPM (no Xcode needed) and ad-hoc signs it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AerialSwap"

APP="AerialSwap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AerialSwap"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate with Tools/make_icon.swift

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
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature, no sandbox entitlements (needs access to ~/Library/Application Support/com.apple.wallpaper).
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
if pgrep -x AerialSwap >/dev/null; then
    echo "Note: AerialSwap is still running the previous build. Quit it (Cmd-Q) and reopen to use this one."
fi
