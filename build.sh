#!/bin/bash
# Builds build/Transfer Speed.app (universal, release, ad-hoc signed).
# ./build.sh dmg  also packages build/TransferSpeed-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/TransferSpeed"

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

APP="build/Transfer Speed.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TransferSpeed"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "dmg" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
    DMG="build/TransferSpeed-$VERSION.dmg"
    STAGING=$(mktemp -d)
    trap 'rm -rf "$STAGING"' EXIT
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    rm -f "$DMG"
    hdiutil create -volname "Transfer Speed" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    codesign --force --sign - "$DMG"
    echo "Built $DMG"
fi
