#!/bin/zsh
# Build Distill.app from this Swift package.
# Usage: apps/distill/clients/macos/scripts/build-app.sh [--install]
#   --install  copy the bundle to ~/Applications
set -euo pipefail

APP_DIR="${0:A:h:h}"
PRODUCT_ROOT="${APP_DIR:h:h:h:h}"
BUILD="$APP_DIR/build"
BUNDLE="$BUILD/Distill.app"

swift build --package-path "$APP_DIR" -c release
BIN="$(swift build --package-path "$APP_DIR" -c release --show-bin-path)/Distill"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/Distill"

VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PRODUCT_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo 0.1.0)"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Distill</string>
  <key>CFBundleDisplayName</key><string>Distill</string>
  <key>CFBundleIdentifier</key><string>com.claude-obsidian.distill</string>
  <key>CFBundleExecutable</key><string>Distill</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>ClaudeObsidianProductRoot</key><string>${PRODUCT_ROOT}</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper treats it as a local build.
codesign --force --sign - "$BUNDLE" >/dev/null
echo "Built $BUNDLE"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Distill.app"
  cp -R "$BUNDLE" "$HOME/Applications/"
  echo "Installed $HOME/Applications/Distill.app"
fi
