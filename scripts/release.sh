#!/bin/bash
# Builds Word Catcher and packs it as web/downloads/WordCatcher.zip for the download page.
# Push afterwards, and Vercel serves it at /downloads/WordCatcher.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh
mkdir -p web/downloads
rm -f web/downloads/WordCatcher.zip
ditto -c -k --keepParent dist/WordCatcher.app web/downloads/WordCatcher.zip
echo "Packed web/downloads/WordCatcher.zip ($(du -h web/downloads/WordCatcher.zip | cut -f1))"
