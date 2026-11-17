#!/usr/bin/env bash
# Build "Tailscale Control.app" from Sources/TailscaleControl/**/*.swift.
#   scripts/build.sh              build, bundle and ad-hoc sign the app
#   scripts/build.sh --typecheck  fast type-check of all sources only (no output)
# Environment: VERSION (default: the VERSION file), APP_NAME, BUNDLE_ID, SWIFTC (force a compiler).
# The app icon (scripts/make-icon.swift -> build/icon/AppIcon.icns) is generated on demand and cached; if that fails,
# the app is built without an icon.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-Tailscale Control}"
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || true)"
  VERSION="${VERSION:-1.0.0}"
fi
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
BUNDLE_ID="${BUNDLE_ID:-io.github.tailscale-control.app}"
APP_DIR="$ROOT_DIR/build/${APP_NAME}.app"
EXE_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
TARGET="$(uname -m)-apple-macos13.0"

# Pick a working compiler: the one on PATH, else the Command Line Tools one.
if [[ -n "${SWIFTC:-}" ]]; then
  :
elif swiftc --version >/dev/null 2>&1; then
  SWIFTC="swiftc"
else
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  SWIFTC="/usr/bin/swiftc"
fi

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT_DIR/Sources/TailscaleControl" -name '*.swift' | sort)
if [[ ${#SOURCES[@]} -eq 0 ]]; then echo "No Swift sources found" >&2; exit 1; fi

if [[ "${1:-}" == "--typecheck" ]]; then
  "$SWIFTC" -typecheck -parse-as-library -swift-version 5 -target "$TARGET" "${SOURCES[@]}"
  echo "Typecheck OK (${#SOURCES[@]} files)"
  exit 0
fi

mkdir -p "$EXE_DIR" "$RES_DIR"

"$SWIFTC" -parse-as-library -O -swift-version 5 -target "$TARGET" "${SOURCES[@]}" -o "$EXE_DIR/$APP_NAME"

# App icon: draw it with CoreGraphics and convert with iconutil. Cached under build/icon; failures are not fatal.
ICON_DIR="$ROOT_DIR/build/icon"
ICON_FILE="$ICON_DIR/AppIcon.icns"
ICON_SRC="$ROOT_DIR/scripts/make-icon.swift"
make_icon() {
  mkdir -p "$ICON_DIR"
  rm -rf "$ICON_DIR/AppIcon.iconset" "$ICON_DIR/AppIcon.tmp.icns"
  "$SWIFTC" -O "$ICON_SRC" -o "$ICON_DIR/make-icon" &&
    "$ICON_DIR/make-icon" "$ICON_DIR/AppIcon.iconset" &&
    iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$ICON_DIR/AppIcon.tmp.icns" &&
    mv "$ICON_DIR/AppIcon.tmp.icns" "$ICON_FILE"
}
if [[ ! -f "$ICON_FILE" || "$ICON_SRC" -nt "$ICON_FILE" ]]; then
  make_icon >/dev/null 2>&1 || { echo "warning: icon generation failed; building without an app icon" >&2; rm -f "$ICON_FILE"; }
fi
ICON_PLIST=""
if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$RES_DIR/AppIcon.icns"
  ICON_PLIST="  <key>CFBundleIconFile</key>
  <string>AppIcon</string>"
else
  rm -f "$RES_DIR/AppIcon.icns"
fi

cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
$ICON_PLIST
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST" >/dev/null
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1
codesign --verify --deep --strict "$APP_DIR"
xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true

printf 'Built %s (version %s, build %s)\n' "$APP_DIR" "$VERSION" "$BUILD_NUMBER"
