#!/bin/bash
# Builds Word Catcher and installs it in ~/Applications, then (re)starts it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

DEST="$HOME/Applications/WordCatcher.app"
mkdir -p "$HOME/Applications"
pkill -x WordCatcher 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R dist/WordCatcher.app "$DEST"
rm -rf dist/WordCatcher.app # one copy only, so "open at login" always points at the installed app

open "$DEST"
echo "Installed $DEST"
