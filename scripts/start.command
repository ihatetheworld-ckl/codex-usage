#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$HOME/Applications/Codex Usage.app"
if [ ! -x "$APP_DIR/Contents/MacOS/CodexUsage" ]; then
  /bin/bash "$PROJECT_ROOT/scripts/install.sh"
fi
/usr/bin/open "$APP_DIR"
