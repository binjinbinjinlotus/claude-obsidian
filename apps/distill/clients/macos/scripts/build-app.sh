#!/bin/zsh
# Build Distill.app from this Swift package.
# Usage: apps/distill/clients/macos/scripts/build-app.sh [--install]
#   --install  copy the bundle to ~/Applications
set -euo pipefail

APP_DIR="${0:A:h:h}"
PRODUCT_ROOT="${APP_DIR:h:h:h:h}"
BUILD="$APP_DIR/build"
BUNDLE="$BUILD/Distill.app"
WORKSPACE="$PRODUCT_ROOT/apps/distill"

# The app runs the Node core from this checkout (apps/distill/cli/dist/main.js),
# so build the TS workspace first. Skipped when everything is up to date.
if ! command -v npm >/dev/null 2>&1; then
  for d in "$HOME"/.nvm/versions/node/*/bin(Nn) /opt/homebrew/bin /usr/local/bin; do
    [[ -x "$d/npm" ]] && PATH="$d:$PATH"
  done
fi
command -v npm >/dev/null 2>&1 || { echo "npm not found: install Node.js 20+ to build the Distill core." >&2; exit 1; }
if [[ ! -f "$WORKSPACE/node_modules/.package-lock.json" || "$WORKSPACE/package-lock.json" -nt "$WORKSPACE/node_modules/.package-lock.json" ]]; then
  (cd "$WORKSPACE" && npm ci)
fi
ENTRY="$WORKSPACE/cli/dist/main.js"
if [[ ! -f "$ENTRY" || -n "$(find "$WORKSPACE/core/src" "$WORKSPACE/cli/src" "$WORKSPACE/core/package.json" "$WORKSPACE/cli/package.json" -newer "$ENTRY" -print -quit)" ]]; then
  (cd "$WORKSPACE" && npm run build --workspaces)
fi

swift build --package-path "$APP_DIR" -c release
BIN="$(swift build --package-path "$APP_DIR" -c release --show-bin-path)/Distill"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/Distill"
# App icon (regenerate with scripts/make-icon.sh).
cp "$APP_DIR/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"

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
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
