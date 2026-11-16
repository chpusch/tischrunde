#!/bin/bash
# Builds a launchable Tischrunde.app (universal: Apple Silicon + Intel) into build/.
# Usage: scripts/build_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*string = "\(.*\)".*/\1/p' Sources/TischrundeCore/Version.swift)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP="build/Tischrunde.app"
ARCHS=(--arch arm64 --arch x86_64)

echo "==> Baue Tischrunde $VERSION (Release, universal)"
swift build -c release "${ARCHS[@]}" --product Tischrunde
swift build -c release "${ARCHS[@]}" --product tischrunde-cli
BIN_DIR=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

echo "==> Erzeuge App-Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tischrunde" "$APP/Contents/MacOS/Tischrunde"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$BIN_DIR/tischrunde-cli" build/tischrunde-cli

echo "==> Icon"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Texte"
mkdir -p "$APP/Contents/Resources/de.lproj"
if xcrun --find xcstringstool >/dev/null 2>&1; then
    xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Contents/Resources" || true
fi

echo "==> Ad-hoc-Signatur"
codesign --force --deep --sign - "$APP"
codesign --force --sign - build/tischrunde-cli
codesign --verify --verbose "$APP"

echo "Fertig: $APP und build/tischrunde-cli"
