#!/bin/zsh
# Builds Pegline.app with the command line tools only (no Xcode project needed).
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  mkdir -p build/icon
  swiftc -O scripts/make-icon.swift -o build/icon/make-icon
  build/icon/make-icon build/icon
  iconutil -c icns build/icon/AppIcon.iconset -o build/AppIcon.icns
fi

APP=build/Pegline.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Pegline" "$APP/Contents/MacOS/Pegline"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature with the hardened runtime. Replace "-" with a Developer ID to distribute.
codesign --force --sign - --options runtime "$APP"
echo "Built $APP"
