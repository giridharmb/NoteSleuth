#!/bin/bash
# Builds build/NoteSleuth.app. Pass --install to copy it to /Applications and launch it.
# Signs with your first Apple Development / Developer ID identity if present (so Full Disk Access
# survives rebuilds); otherwise ad-hoc, which means re-granting Full Disk Access after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64 --arch x86_64) # universal: Apple silicon + Intel
swift build -c release "${ARCHS[@]}"
APP=build/NoteSleuth.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"
cp "$BIN/NoteSleuth" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
[ -f Support/AppIcon.icns ] || scripts/make_icon.sh
cp Support/AppIcon.icns "$APP/Contents/Resources/"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}' || true)}"
# Hardened runtime + secure timestamp are required for notarization; skipped for ad-hoc builds.
RUNTIME=()
[ -n "$SIGN_ID" ] && RUNTIME=(--options runtime --timestamp --entitlements Support/NoteSleuth.entitlements)
# Sign Sparkle's helpers inside-out (Sparkle's documented order), then the app.
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
SIGN=(codesign --force --sign "${SIGN_ID:--}")
[ -n "$SIGN_ID" ] && SIGN+=(--options runtime --timestamp)
"${SIGN[@]}" "$SPK/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$SPK/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPK/Autoupdate" "$SPK/Updater.app"
"${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force "${RUNTIME[@]}" --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP (signed: ${SIGN_ID:-ad-hoc})"

if [ "${1:-}" = "--install" ]; then
  pkill -x NoteSleuth || true
  rm -rf /Applications/NoteSleuth.app
  cp -R "$APP" /Applications/
  open /Applications/NoteSleuth.app
  echo "Installed to /Applications"
fi
