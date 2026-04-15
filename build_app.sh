#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="Moly Context Hub.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE_PATH="${TMPDIR:-/tmp}/wechat-sync-clang-cache"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}"
APP_ENTITLEMENTS_PATH="${APP_ENTITLEMENTS_PATH:-}"
APP_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT_DIR/AppResources/Info.plist")"
APP_EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ROOT_DIR/AppResources/Info.plist")"
APP_LOGO_SOURCE="$ROOT_DIR/dist/screenshot-20260324-194824.png"
APP_ICNS_PATH="$RESOURCES_DIR/AppIcon.icns"
EXTENSION_SOURCE_DIR="$ROOT_DIR/chrome-extension"
EXTENSION_DIST_DIR="$ROOT_DIR/dist/chrome-extension"
EXTENSION_ZIP_PATH="$ROOT_DIR/dist/Moly-Context-Hub-Chrome-Extension.zip"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$MODULE_CACHE_PATH"

swiftc \
  -module-cache-path "$MODULE_CACHE_PATH" \
  "$ROOT_DIR"/Sources/WeChatSync/AccessibilityReader.swift \
  "$ROOT_DIR"/Sources/WeChatSync/FrontmostContextReader.swift \
  "$ROOT_DIR"/Sources/WeChatSync/ChromeExtensionBridge.swift \
  "$ROOT_DIR"/Sources/WeChatSync/CrashReporter.swift \
  "$ROOT_DIR"/Sources/WeChatSync/IntentCaptureSupport.swift \
  "$ROOT_DIR"/Sources/WeChatSync/Models.swift \
  "$ROOT_DIR"/Sources/WeChatSync/ExportPathResolver.swift \
  "$ROOT_DIR"/Sources/WeChatSync/MarkdownExporter.swift \
  "$ROOT_DIR"/Sources/WeChatSync/TaskMarkdownExporter.swift \
  "$ROOT_DIR"/Sources/WeChatSync/TaskPlanner.swift \
  "$ROOT_DIR"/Sources/WeChatSync/TaskStore.swift \
  "$ROOT_DIR"/Sources/WeChatSync/Store.swift \
  "$ROOT_DIR"/Sources/WeChatSync/TranscriptExtractor.swift \
  "$ROOT_DIR"/Sources/WeChatSync/WeChatController.swift \
  "$ROOT_DIR"/Sources/WeChatSync/WeChatLocator.swift \
  "$ROOT_DIR"/Sources/WeChatSync/ChromeContextReader.swift \
  "$ROOT_DIR"/Sources/WeChatSync/SyncEngine.swift \
  "$ROOT_DIR"/Sources/WeChatSync/SyncWorker.swift \
  "$ROOT_DIR"/Sources/WeChatSyncApp/Branding.swift \
  "$ROOT_DIR"/Sources/WeChatSyncApp/AppModel.swift \
  "$ROOT_DIR"/Sources/WeChatSyncApp/AppMain.swift \
  -o "$MACOS_DIR/$APP_EXECUTABLE_NAME" \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Network \
  -framework ScreenCaptureKit \
  -framework Vision \
  -framework CoreImage \
  -framework SwiftUI \
  -framework Combine \
  -lsqlite3

cp "$ROOT_DIR/AppResources/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :MolyMarkdownExportPath" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :MolyExportRootPath" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :MolyChromeExtensionPath" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :MolyChromeExtensionPath string $EXTENSION_DIST_DIR" "$CONTENTS_DIR/Info.plist"
if [[ -f "$APP_LOGO_SOURCE" ]]; then
  cp "$APP_LOGO_SOURCE" "$RESOURCES_DIR/AppLogo.png"
  /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 - <<PY
from PIL import Image

source_path = r"$APP_LOGO_SOURCE"
target_path = r"$APP_ICNS_PATH"

source = Image.open(source_path).convert("RGBA")
canvas = Image.new("RGBA", (1024, 1024), (255, 255, 255, 255))
source.thumbnail((900, 900), Image.Resampling.LANCZOS)
offset = ((1024 - source.width) // 2, (1024 - source.height) // 2)
canvas.paste(source, offset, source)
canvas.save(
    target_path,
    format="ICNS",
    sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)],
)
PY
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$CONTENTS_DIR/Info.plist"
fi

if [[ -d "$EXTENSION_SOURCE_DIR" ]]; then
  rm -rf "$EXTENSION_DIST_DIR"
  mkdir -p "$ROOT_DIR/dist"
  ditto "$EXTENSION_SOURCE_DIR" "$EXTENSION_DIST_DIR"
  rm -f "$EXTENSION_ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$EXTENSION_DIST_DIR" "$EXTENSION_ZIP_PATH"
fi

if [[ -n "$APP_SIGN_IDENTITY" ]]; then
  CODESIGN_ARGS=(--force --deep --sign "$APP_SIGN_IDENTITY" --identifier "$APP_BUNDLE_ID")
  if [[ -n "$APP_ENTITLEMENTS_PATH" ]]; then
    CODESIGN_ARGS+=(--entitlements "$APP_ENTITLEMENTS_PATH")
  fi
  codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"
fi

echo "Built app bundle:"
echo "$APP_DIR"
echo "Code signing identity: ${APP_SIGN_IDENTITY}"
