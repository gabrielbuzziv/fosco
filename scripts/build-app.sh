#!/bin/bash
# Builds build/Fosco.app for this Mac, or for Apple silicon and Intel with UNIVERSAL=1.
#
# macOS ties the permissions it grants (clipboard, Desktop) to the signature. An ad hoc signature
# changes with every build and would lose them, so sign with a real identity when there is one:
# SIGN_IDENTITY, or the name or hash stored in .signing-identity (see `security find-identity -v -p codesigning`).
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=(-c release)
if [ "${UNIVERSAL:-0}" = 1 ]; then FLAGS+=(--arch arm64 --arch x86_64); fi
swift build "${FLAGS[@]}"

APP="build/Fosco.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build "${FLAGS[@]}" --show-bin-path)/Fosco" "$APP/Contents/MacOS/Fosco"
# The debug symbols name the folders of the Mac that built the app.
strip -S "$APP/Contents/MacOS/Fosco"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/Fosco.icns "$APP/Contents/Resources/Fosco.icns"

IDENTITY="${SIGN_IDENTITY:-$(cat .signing-identity 2>/dev/null || true)}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "warning: no signing identity set; signing ad hoc, permissions will have to be granted again after each build" >&2
fi
# Apple notarizes only apps with the hardened runtime and a timestamp from its servers.
SIGN_FLAGS=(--force --options runtime)
case "$IDENTITY" in "Developer ID"*) SIGN_FLAGS+=(--timestamp) ;; esac
codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
echo "$APP"
