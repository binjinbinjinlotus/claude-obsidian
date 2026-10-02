#!/bin/zsh
# Regenerate Resources/AppIcon.icns from the SwiftUI drawing in
# Sources/Distill/AppIcon.swift (canvas: "App icon").
# Usage: apps/distill/clients/macos/scripts/make-icon.sh
set -euo pipefail

APP_DIR="${0:A:h:h}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift build --package-path "$APP_DIR"
BIN="$(swift build --package-path "$APP_DIR" --show-bin-path)/Distill"
"$BIN" --snapshot "$WORK/AppIcon.iconset" --app-icon >/dev/null
mkdir -p "$APP_DIR/Resources"
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP_DIR/Resources/AppIcon.icns"
echo "Wrote $APP_DIR/Resources/AppIcon.icns"
