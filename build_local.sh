#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$ROOT_DIR/bin"
OUTPUT_BIN="$OUTPUT_DIR/wechat-sync"
MODULE_CACHE_PATH="${TMPDIR:-/tmp}/wechat-sync-clang-cache"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$MODULE_CACHE_PATH"

swiftc \
  -module-cache-path "$MODULE_CACHE_PATH" \
  "$ROOT_DIR"/Sources/WeChatSync/*.swift \
  -o "$OUTPUT_BIN" \
  -framework AppKit \
  -framework ApplicationServices \
  -lsqlite3

echo "Built: $OUTPUT_BIN"
