#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CODEX_USAGE_ARCHS='arm64 x86_64' /bin/bash "$PROJECT_ROOT/scripts/build.sh"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$STAGING_DIR/Codex Usage"
/usr/bin/ditto -x -k "$PROJECT_ROOT/dist/Codex Usage.zip" "$STAGING_DIR/Codex Usage"
/usr/bin/codesign --verify --strict "$STAGING_DIR/Codex Usage/Codex Usage.app"
ACTUAL_ARCHS="$(/usr/bin/lipo -archs "$STAGING_DIR/Codex Usage/Codex Usage.app/Contents/MacOS/CodexUsage")"
if [[ " $ACTUAL_ARCHS " != *' arm64 '* || " $ACTUAL_ARCHS " != *' x86_64 '* ]]; then
  printf 'Universal archive is missing an architecture: %s\n' "$ACTUAL_ARCHS" >&2
  exit 1
fi
cp "$PROJECT_ROOT/LICENSE" "$PROJECT_ROOT/NOTICE" "$PROJECT_ROOT/THIRD-PARTY-NOTICES.md" "$PROJECT_ROOT/README.md" "$STAGING_DIR/Codex Usage/"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$STAGING_DIR/Codex Usage" "$PROJECT_ROOT/dist/CodexUsage-macOS-universal.zip"
