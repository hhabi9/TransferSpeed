#!/bin/bash
# Builds build/Transfer Speed.app (universal, release).
# ./build.sh dmg  also packages build/TransferSpeed-<version>.dmg
#
# Signs with a "Developer ID Application" certificate when one is in the keychain, otherwise ad-hoc.
# With NOTARY_PROFILE set (see `xcrun notarytool store-credentials`), the DMG is notarized and stapled.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/TransferSpeed"

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
if [ -n "$IDENTITY" ]; then
    SIGN=(--sign "$IDENTITY" --options runtime --timestamp)
    echo "Signing as $IDENTITY"
else
    SIGN=(--sign -)
    echo "No Developer ID certificate found; signing ad-hoc"
fi

APP="build/Transfer Speed.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TransferSpeed"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force "${SIGN[@]}" "$APP"
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
    codesign --force "${SIGN[@]}" "$DMG"

    if [ -n "$IDENTITY" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG"
    elif [ -n "$IDENTITY" ]; then
        echo "Set NOTARY_PROFILE to notarize the DMG"
    fi
    echo "Built $DMG"
fi
