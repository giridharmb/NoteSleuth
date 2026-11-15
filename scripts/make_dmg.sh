#!/bin/bash
# Builds a Developer ID–signed build/QuickNoteSearch-<version>.dmg.
# Set NOTARY_PROFILE to a `xcrun notarytool store-credentials` profile name to also notarize and staple.
set -euo pipefail
cd "$(dirname "$0")/.."

export SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"
[ -n "$SIGN_ID" ] || { echo "No Developer ID Application certificate found" >&2; exit 1; }
scripts/build_app.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
DMG="build/QuickNoteSearch-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/QuickNoteSearch.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "QuickNoteSearch $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

codesign --verify --strict "$DMG"
codesign --verify --deep --strict build/QuickNoteSearch.app
shasum -a 256 "$DMG"
