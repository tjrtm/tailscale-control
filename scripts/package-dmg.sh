#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-Tailscale Control}"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || echo 1.0.0)}"
APP_DIR="$ROOT_DIR/build/${APP_NAME}.app"
DIST_DIR="$ROOT_DIR/dist"
DMG_ROOT="$DIST_DIR/dmg-root"
DMG_NAME="${APP_NAME// /-}-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

if [[ ! -d "$APP_DIR" ]]; then
  "$ROOT_DIR/scripts/build.sh"
fi

rm -rf "$DMG_ROOT"
mkdir -p "$DMG_ROOT" "$DIST_DIR"
cp -R "$APP_DIR" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

hdiutil verify "$DMG_PATH" >/dev/null
printf 'Created %s\n' "$DMG_PATH"
