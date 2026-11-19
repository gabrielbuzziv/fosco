#!/bin/bash
# Builds the download, build/Fosco-<version>.dmg, for Apple silicon and Intel.
#
# With a "Developer ID Application" certificate in the keychain the app is signed with it and
# notarized, so it opens on other Macs without a warning. Notarizing needs credentials stored once
# under the name in NOTARY_PROFILE (default: fosco):
#   xcrun notarytool store-credentials fosco --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer id>
# Without the certificate the app is signed ad hoc, and whoever downloads it has to allow it in
# System Settings › Privacy & Security the first time.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
DMG="build/Fosco-$VERSION.dmg"
DEVELOPER_ID="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-fosco}"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

UNIVERSAL=1 SIGN_IDENTITY="${DEVELOPER_ID:--}" ./scripts/build-app.sh
APP="build/Fosco.app"

if [ -n "$DEVELOPER_ID" ]; then
  # The app gets a ticket of its own, so it still opens offline once it is out of the disk image.
  ditto -c -k --keepParent "$APP" build/Fosco.zip
  notarize build/Fosco.zip
  rm build/Fosco.zip
  xcrun stapler staple "$APP"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Fosco.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Fosco -srcfolder "$STAGE" -format UDZO -quiet "$DMG"

if [ -n "$DEVELOPER_ID" ]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
else
  echo "warning: no Developer ID certificate; the app is signed ad hoc, and macOS blocks it on other Macs until it is allowed in System Settings › Privacy & Security" >&2
fi
echo "$DMG"
shasum -a 256 "$DMG"
