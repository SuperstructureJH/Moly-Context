#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$ROOT_DIR"

if [[ ! -x "$ROOT_DIR/bin/wechat-sync" ]]; then
  zsh "$ROOT_DIR/build_local.sh"
fi

"$ROOT_DIR/bin/wechat-sync" setup

echo
echo "If permission is now enabled, press Enter to start watch mode."
read

"$ROOT_DIR/bin/wechat-sync" watch --interval 5 --verbose
