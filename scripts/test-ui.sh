#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
/usr/bin/swiftc -module-cache-path "$PROJECT_ROOT/.build/ModuleCache" \
  "$PROJECT_ROOT/Sources/Usage.swift" "$PROJECT_ROOT/Sources/Brand.swift" \
  "$PROJECT_ROOT/Sources/WidgetViews.swift" "$PROJECT_ROOT/Sources/CodexClient.swift" \
  "$PROJECT_ROOT/Sources/App.swift" "$PROJECT_ROOT/Tests/WidgetInteractionTests.swift" \
  -framework AppKit -o "$PROJECT_ROOT/.build/widget-ui-tests"
cat > "$PROJECT_ROOT/.build/ui-test-codex" <<'PY'
#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if "id" in request:
        print(json.dumps({"id": request["id"], "result": {}}), flush=True)
PY
chmod +x "$PROJECT_ROOT/.build/ui-test-codex"
CODEX_USAGE_CLI="$PROJECT_ROOT/.build/ui-test-codex" "$PROJECT_ROOT/.build/widget-ui-tests"
