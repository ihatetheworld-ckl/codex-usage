#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/Applications"
APP_DIR="$INSTALL_DIR/Codex Usage.app"
if [ -e "$APP_DIR" ]; then
  printf 'Already exists: %s\nQuit and remove the previous Codex Usage app before reinstalling.\n' "$APP_DIR" >&2
  exit 1
fi
if [ ! -f "$PROJECT_ROOT/dist/Codex Usage.zip" ]; then
  /bin/bash "$PROJECT_ROOT/scripts/build.sh"
fi
mkdir -p "$INSTALL_DIR"
/usr/bin/ditto -x -k "$PROJECT_ROOT/dist/Codex Usage.zip" "$INSTALL_DIR"
/usr/bin/codesign --verify --strict "$APP_DIR"
printf 'Installed: %s\n' "$APP_DIR"
