#!/bin/bash
# Builds BluetoothAutoSleeper (GUI + background daemon) and installs it into /Applications.
#
#   ./build.sh          build and install (relaunches the app if it was running)
#   ./build.sh --zip    also write dist/BluetoothAutoSleeper-v<version>.zip for a release
#
# INSTALL_DIR=~/Applications ./build.sh installs somewhere else.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="BluetoothAutoSleeper"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$ROOT/Info.plist")"
DEST="${INSTALL_DIR:-/Applications}"
ZIP=0
[ "${1:-}" = "--zip" ] && ZIP=1

SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --sdk macosx --find swiftc)"

# Build outside the project: synced folders (iCloud Documents) attach extended
# attributes to everything, and codesign refuses bundles that carry them.
OUT="$(mktemp -d -t bluetoothautosleeper)"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/$NAME.app"

echo "Building $NAME $VERSION (universal)..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/BluetoothAutoSleeper.icns" "$APP/Contents/Resources/"

# swiftc takes one -target per call: build each architecture, then lipo them together.
# $1 = output name, rest = sources.
build() {
  local out="$1"; shift
  for arch in arm64 x86_64; do
    "$SWIFTC" -O -sdk "$SDK" -target "$arch-apple-macos11.0" "$@" -o "$OUT/$out-$arch"
  done
  lipo -create "$OUT/$out-arm64" "$OUT/$out-x86_64" -output "$APP/Contents/MacOS/$out"
}
build "$NAME" "$ROOT"/{Main,AppDelegate,ContentView,LogsView,DaemonManager}.swift
build "BluetoothAutoSleeperDemon" "$ROOT/BluetoothDaemon.swift"

# Ad-hoc signature: required on Apple Silicon, and keeps the bundle intact in a zip.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"

if [ "$ZIP" = 1 ]; then
  mkdir -p "$ROOT/dist"
  ZIPFILE="$ROOT/dist/$NAME-v$VERSION.zip"
  rm -f "$ZIPFILE"
  ditto -c -k --norsrc --keepParent "$APP" "$ZIPFILE"
  echo "Release zip: $ZIPFILE"
fi

# Quit a running GUI first (the daemon keeps running on its own and is left alone;
# stop and restart it from the app to pick up a new daemon build).
GUI="$DEST/$NAME.app/Contents/MacOS/$NAME"
WAS_RUNNING=0
if pgrep -fx "$GUI" >/dev/null 2>&1; then
  WAS_RUNNING=1
  echo "Quitting the running $NAME..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    pgrep -fx "$GUI" >/dev/null 2>&1 || break
    sleep 0.2
  done
fi

mkdir -p "$DEST"
rm -rf "$DEST/$NAME.app"
ditto "$APP" "$DEST/$NAME.app"
echo "Installed: $DEST/$NAME.app"

[ "$WAS_RUNNING" = 1 ] && open "$DEST/$NAME.app"
exit 0
