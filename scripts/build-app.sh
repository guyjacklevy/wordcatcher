#!/bin/bash
# Builds dist/WordCatcher.app from the Swift package.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/WordCatcher.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WordCatcher "$APP/Contents/MacOS/WordCatcher"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature with a stable designated requirement, so macOS keeps the
# Accessibility permission across rebuilds.
codesign --force --sign - \
  --identifier app.wordcatcher.mac \
  --requirements '=designated => identifier "app.wordcatcher.mac"' \
  "$APP"

echo "Built $APP"
