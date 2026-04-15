#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -d "$ROOT_DIR/build/Moly Context Hub.app" ]]; then
  zsh "$ROOT_DIR/build_app.sh"
fi

open "$ROOT_DIR/build/Moly Context Hub.app"
