#!/bin/bash
# Zips the most recent build (from scripts/build-app.sh) with install notes, for
# giving the app to someone else. Output: dist/HiFi-Guard.zip
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${HOME}/Library/Caches/hifi-guard-build"
STAGED="$WORK/stage/HiFi Guard.app"
FOLDER="$WORK/package/HiFi Guard"
ZIP="$ROOT/dist/HiFi-Guard.zip"

if [[ ! -d "$STAGED" ]]; then
    echo "No build found; run scripts/build-app.sh first." >&2
    exit 1
fi
codesign --verify --strict "$STAGED"

rm -rf "$WORK/package"
mkdir -p "$FOLDER" "$ROOT/dist"
ditto "$STAGED" "$FOLDER/HiFi Guard.app"
cp "$ROOT/Resources/READ ME FIRST.txt" "$FOLDER/"

rm -f "$ZIP"
# ditto keeps the code signature and extended attributes intact; plain zip does not.
ditto -c -k --keepParent "$FOLDER" "$ZIP"
echo "Packaged $ZIP ($(du -h "$ZIP" | cut -f1))"
