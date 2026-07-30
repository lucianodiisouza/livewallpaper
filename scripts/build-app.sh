#!/usr/bin/env bash
#
# Assemble the LiveWallpaper.app bundle from the SwiftPM build, generate a looping test video,
# and ad-hoc code-sign it — optionally WITH the App Sandbox entitlement (the M0 spike).
#
# Usage:
#   scripts/build-app.sh              # build, sign WITH sandbox (default — this is the M0 spike)
#   scripts/build-app.sh --no-sandbox # build, sign WITHOUT sandbox (the A/B comparison)
#
# Output: dist/LiveWallpaper.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SANDBOX=1
[[ "${1:-}" == "--no-sandbox" ]] && SANDBOX=0

CONFIG="release"
APP="$ROOT/dist/LiveWallpaper.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
VERSION="0.0.1"

echo "▶ Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LiveWallpaper"

echo "▶ Assembling bundle at dist/LiveWallpaper.app…"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/LiveWallpaper"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LiveWallpaper</string>
    <key>CFBundleDisplayName</key><string>LiveWallpaper</string>
    <key>CFBundleIdentifier</key><string>com.livewallpaper.app</string>
    <key>CFBundleExecutable</key><string>LiveWallpaper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© LiveWallpaper contributors. MIT.</string>
</dict>
</plist>
PLIST

# Generate a looping test wallpaper (continuous motion → easy to eyeball the occlusion pause).
LOOP="$RES/loop.mp4"
if command -v ffmpeg >/dev/null 2>&1; then
    echo "▶ Generating test loop video (ffmpeg)…"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "mandelbrot=size=1920x1080:rate=30" -t 8 \
        -c:v libx264 -pix_fmt yuv420p -movflags +faststart "$LOOP"
else
    echo "⚠ ffmpeg not found — app will use the animated-gradient fallback."
fi

# Code-sign (ad-hoc). Include the sandbox entitlement unless --no-sandbox was passed.
if [[ "$SANDBOX" == "1" ]]; then
    echo "▶ Signing WITH App Sandbox (M0 spike)…"
    codesign --force --deep --sign - \
        --entitlements "$ROOT/LiveWallpaper.entitlements" \
        --options runtime "$APP"
else
    echo "▶ Signing WITHOUT sandbox (comparison build)…"
    codesign --force --deep --sign - "$APP"
fi

echo "▶ Verifying signature / entitlements…"
codesign -dv --entitlements - "$APP" 2>&1 | grep -E "com.apple.security|Signature|Identifier" || true

echo "✅ Built: $APP"
echo "   Launch:  open \"$APP\"    (or: \"$MACOS/LiveWallpaper\" for logs in the terminal)"
echo "   Quit:    the 🖼️ menu-bar item → Quit"
