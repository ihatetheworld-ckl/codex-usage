#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build"
APP_DIR="$PROJECT_ROOT/dist/Codex Usage.app"
APP_VERSION="${CODEX_USAGE_VERSION:-$(tr -d '\r\n' < "$PROJECT_ROOT/VERSION")}"
if ! [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then printf 'Invalid version\n' >&2; exit 1; fi
APP_ARCHS="${CODEX_USAGE_ARCHS:-$(uname -m)}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-usage-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGING_APP="$STAGING_DIR/Codex Usage.app"
mkdir -p "$BUILD_DIR/ModuleCache" "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources" "$PROJECT_ROOT/dist"
SDK_PATH="$(/usr/bin/xcrun --show-sdk-path)"
ARCH_BINARIES=()
for APP_ARCH in $APP_ARCHS; do
  case "$APP_ARCH" in arm64|x86_64) ;; *) printf 'Unsupported architecture\n' >&2; exit 1 ;; esac
  ARCH_BINARY="$STAGING_DIR/CodexUsage-$APP_ARCH"
  /usr/bin/swiftc -O -sdk "$SDK_PATH" -target "$APP_ARCH-apple-macosx13.0" -module-cache-path "$BUILD_DIR/ModuleCache" \
  "$PROJECT_ROOT/Sources/Usage.swift" "$PROJECT_ROOT/Sources/CodexClient.swift" \
  "$PROJECT_ROOT/Sources/Brand.swift" "$PROJECT_ROOT/Sources/WidgetViews.swift" \
  "$PROJECT_ROOT/Sources/App.swift" "$PROJECT_ROOT/Sources/main.swift" \
  -framework AppKit -o "$ARCH_BINARY"
  ARCH_BINARIES+=("$ARCH_BINARY")
done
/usr/bin/lipo -create "${ARCH_BINARIES[@]}" -output "$STAGING_APP/Contents/MacOS/CodexUsage"
/usr/bin/swiftc -O -module-cache-path "$BUILD_DIR/ModuleCache" \
  "$PROJECT_ROOT/Sources/Brand.swift" "$PROJECT_ROOT/scripts/GenerateIcon.swift" \
  -framework AppKit -o "$BUILD_DIR/generate-icon"
"$BUILD_DIR/generate-icon" "$BUILD_DIR/AppIcon.iconset" "$PROJECT_ROOT/Assets"
/usr/bin/iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$STAGING_APP/Contents/Resources/AppIcon.icns"
cat > "$STAGING_APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.codex-usage-sidebar</string>
  <key>CFBundleExecutable</key><string>CodexUsage</string>
  <key>CFBundleName</key><string>Codex Usage</string>
  <key>CFBundleDisplayName</key><string>Codex 用量</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
  <key>CFBundleVersion</key><string>$APP_VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Sign outside File Provider folders, which may immediately restore Finder metadata.
/usr/bin/xattr -cr "$STAGING_APP"
/usr/bin/codesign --force --sign - "$STAGING_APP"
/usr/bin/codesign --verify --strict "$STAGING_APP"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$STAGING_APP" "$PROJECT_ROOT/dist/Codex Usage.zip"
/usr/bin/ditto --norsrc "$STAGING_APP" "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
printf 'Signed archive: %s\n' "$PROJECT_ROOT/dist/Codex Usage.zip"
