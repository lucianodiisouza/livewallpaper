#!/usr/bin/env bash
#
# Assemble the "Primo Engine.app" bundle from the SwiftPM build, generate a looping test video,
# and ad-hoc code-sign it — optionally WITH the App Sandbox entitlement (the M0 spike).
#
# Usage:
#   scripts/build-app.sh              # build, sign WITH sandbox (default — this is the M0 spike)
#   scripts/build-app.sh --no-sandbox # build, sign WITHOUT sandbox (the A/B comparison)
#
# Output: dist/Primo Engine.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SANDBOX=1
[[ "${1:-}" == "--no-sandbox" ]] && SANDBOX=0

CONFIG="release"
APP="$ROOT/dist/Primo Engine.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

# Derive the app version automatically so the menu bar / About pane always shows the right
# value, without having to remember to pass `APP_VERSION=` at every release. Order of precedence:
#   1. explicit APP_VERSION env var (release pipelines set this)
#   2. `git describe --tags --always --dirty` for developer builds
#   3. fallback "0.0.1" for an unversioned checkout
if [[ -n "${APP_VERSION:-}" ]]; then
    VERSION="$APP_VERSION"
elif command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    VERSION="$(git -C "$ROOT" describe --tags --always --dirty 2>/dev/null | sed 's/^v//')"
    [[ -z "$VERSION" ]] && VERSION="0.0.1"
else
    VERSION="0.0.1"
fi

echo "▶ Building ($CONFIG)…"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/LiveWallpaper"

echo "▶ Assembling bundle at dist/Primo Engine.app…"
rm -rf "$APP" "$ROOT/dist/LiveWallpaper.app"   # drop the pre-rename bundle if present
mkdir -p "$MACOS" "$RES"
cp "$BIN" "$MACOS/LiveWallpaper"

# App icon (Prism). Source lives in Resources/AppIcon.icns; regenerate with scripts/make-icon.py.
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RES/AppIcon.icns"
else
    echo "⚠ Resources/AppIcon.icns missing — bundle will use the default icon."
fi

# Localizations: copy every `<lang>.lproj` from Resources/ into the bundle. Foundation picks up
# Localizable.strings automatically; the user's language preference is honoured by AppKit.
for lproj in "$ROOT"/Resources/*.lproj; do
    if [[ -d "$lproj" ]]; then
        cp -R "$lproj" "$RES/"
    fi
done

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Primo Engine</string>
    <key>CFBundleDisplayName</key><string>Primo Engine</string>
    <key>CFBundleIdentifier</key><string>com.livewallpaper.app</string>
    <key>CFBundleExecutable</key><string>LiveWallpaper</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© Primo Engine contributors. MIT.</string>
    <!-- Now-playing wallpapers read the current track + album art from Music/Spotify via Apple
         Events. macOS shows this string in the Automation permission prompt. -->
    <key>NSAppleEventsUsageDescription</key><string>Primo Engine shows the song you're playing (title, artist, and album art) on now-playing wallpapers.</string>
    <!-- Allow cleartext HTTP to localhost/.local only, so a local AI provider
         (Ollama / LM Studio) works for shader generation. Public hosts still
         require HTTPS under App Transport Security. -->
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
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
