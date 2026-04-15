#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="Moly Context Hub.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
STAGING_DIR="$BUILD_DIR/dmg-staging"
VOL_NAME="Moly Context Hub"
DMG_SIGN_IDENTITY="${DMG_SIGN_IDENTITY:-}"

if [[ ! -d "$APP_DIR" ]]; then
  zsh "$ROOT_DIR/build_app.sh"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
DMG_NAME="Moly-Context-Hub-${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
mkdir -p "$DIST_DIR"

ditto "$APP_DIR" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG_PATH"

hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

if [[ -n "$DMG_SIGN_IDENTITY" ]]; then
  codesign --force --sign "$DMG_SIGN_IDENTITY" "$DMG_PATH"
fi

echo "Built dmg:"
echo "$DMG_PATH"
