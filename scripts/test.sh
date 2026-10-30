#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_ROOT/.build/ModuleCache"
/usr/bin/swiftc -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
  "$PROJECT_ROOT/Sources/Usage.swift" "$PROJECT_ROOT/Tests/UsageTests.swift" \
  -o "$PROJECT_ROOT/.build/usage-tests"
"$PROJECT_ROOT/.build/usage-tests"
if [ -x "$PROJECT_ROOT/dist/Codex Usage.app/Contents/MacOS/CodexUsage" ]; then
  python3 "$PROJECT_ROOT/Tests/transport_test.py"
fi
