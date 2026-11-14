#!/bin/bash
# Builds a universal (Intel + Apple silicon) HiFi Guard.app, ad-hoc signs it, and
# installs it (default: /Applications). The signed bundle is left in
# ~/Library/Caches/hifi-guard-build/stage for scripts/package.sh.
#
# The bundle is assembled in ~/Library/Caches, outside iCloud-synced folders (Desktop,
# Documents): iCloud re-stamps FinderInfo on files there, and codesign refuses to sign
# a bundle carrying it.
#
# Signed ad-hoc, but with a designated requirement that names only the bundle ID, so
# macOS recognises each rebuild as the same app instead of keying on the build's hash.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${HOME}/Library/Caches/hifi-guard-build"
APP_NAME="HiFi Guard.app"
DEST="${1:-/Applications}"
STAGED="$WORK/stage/$APP_NAME"
MIN_MACOS="15.0"
ARCHS=(x86_64 arm64)

BINARIES=()
for ARCH in "${ARCHS[@]}"; do
    TRIPLE="$ARCH-apple-macosx$MIN_MACOS"
    SCRATCH="$WORK/spm-$ARCH"
    swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --triple "$TRIPLE" --product HiFiGuard
    BINARIES+=("$(swift build -c release --package-path "$ROOT" --scratch-path "$SCRATCH" --triple "$TRIPLE" --show-bin-path)/HiFiGuard")
done

rm -rf "$WORK/stage"
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"
lipo -create -output "$STAGED/Contents/MacOS/HiFiGuard" "${BINARIES[@]}"
cp "$ROOT/Resources/Info.plist" "$STAGED/Contents/Info.plist"
iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$STAGED/Contents/Resources/AppIcon.icns"
codesign --force --sign - -r='designated => identifier "com.saif.hifiguard"' "$STAGED"
codesign --verify --strict "$STAGED"

if [[ "$DEST" == "/Applications" ]]; then
    # Quit the running copy so its taps are released before the bundle is replaced.
    osascript -e 'tell application id "com.saif.hifiguard" to quit' >/dev/null 2>&1 || true
    pkill -x HiFiGuard >/dev/null 2>&1 || true
fi

mkdir -p "$DEST"
rm -rf "${DEST:?}/$APP_NAME"
ditto "$STAGED" "$DEST/$APP_NAME"
codesign --verify --strict "$DEST/$APP_NAME"
echo "Installed $DEST/$APP_NAME ($(lipo -archs "$DEST/$APP_NAME/Contents/MacOS/HiFiGuard"))"
