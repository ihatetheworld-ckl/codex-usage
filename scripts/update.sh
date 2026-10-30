#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/Applications"
APP_DIR="$INSTALL_DIR/Codex Usage.app"
if [ ! -d "$APP_DIR" ]; then
  /bin/bash "$PROJECT_ROOT/scripts/install.sh"
  /usr/bin/open "$APP_DIR"
  exit 0
fi
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")"
if [ "$IDENTIFIER" != 'local.codex-usage-sidebar' ]; then
  printf 'Refusing to replace an unrelated application.\n' >&2
  exit 1
fi
STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.codex-usage-update.XXXXXX")"
OLD_MOVED=0
NEW_PLACED=0
SUCCESS=0
cleanup() {
  if [ "$OLD_MOVED" = 1 ] && [ "$SUCCESS" != 1 ]; then
    if [ "$NEW_PLACED" = 1 ]; then mv "$APP_DIR" "$STAGING_DIR/failed.app"; fi
    mv "$STAGING_DIR/previous.app" "$APP_DIR"
    /usr/bin/open "$APP_DIR"
  fi
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
/usr/bin/ditto -x -k "$PROJECT_ROOT/dist/Codex Usage.zip" "$STAGING_DIR"
/usr/bin/codesign --verify --strict "$STAGING_DIR/Codex Usage.app"
mkdir -p "$PROJECT_ROOT/.build/backups"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP_DIR" \
  "$PROJECT_ROOT/.build/backups/Codex-Usage-$(date +%Y%m%d-%H%M%S).zip"
"$APP_DIR/Contents/MacOS/CodexUsage" --quit
for attempt in {1..40}; do
  if ! /usr/bin/pgrep -x CodexUsage >/dev/null; then break; fi
  sleep 0.1
done
if /usr/bin/pgrep -x CodexUsage >/dev/null; then
  printf 'Codex Usage is still running; update cancelled.\n' >&2
  exit 1
fi
mv "$APP_DIR" "$STAGING_DIR/previous.app"
OLD_MOVED=1
mv "$STAGING_DIR/Codex Usage.app" "$APP_DIR"
NEW_PLACED=1
/usr/bin/codesign --verify --strict "$APP_DIR"
SUCCESS=1
if [ "${CODEX_USAGE_NO_LAUNCH:-0}" != 1 ]; then /usr/bin/open "$APP_DIR"; fi
printf 'Updated: %s\n' "$APP_DIR"
