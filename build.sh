#!/bin/bash
# Builds Transfer Speed (universal, release, sandboxed).
#   ./build.sh                  build/Transfer Speed.app
#   ./build.sh dmg              also packages build/TransferSpeed-<version>.dmg
#   ./build.sh mas <profile>    Mac App Store package build/TransferSpeed-<version>.pkg (see docs/APP_STORE.md)
#
# The app and DMG are signed with a "Developer ID Application" certificate when one is in the keychain, otherwise ad-hoc.
# With NOTARY_PROFILE set (see `xcrun notarytool store-credentials`), the DMG is notarized and stapled.
# BUNDLE_ID overrides CFBundleIdentifier from Resources/Info.plist.
set -euo pipefail
cd "$(dirname "$0")"

MODE=${1:-app}
case "$MODE" in
    app | dmg | mas) ;;
    *) echo "usage: $0 [dmg | mas <provisioning profile>]" >&2; exit 64 ;;
esac

PLISTBUDDY=/usr/libexec/PlistBuddy
ENTITLEMENTS=Resources/TransferSpeed.entitlements
BUNDLE_ID=${BUNDLE_ID:-$($PLISTBUDDY -c "Print :CFBundleIdentifier" Resources/Info.plist)}
VERSION=$($PLISTBUDDY -c "Print :CFBundleShortVersionString" Resources/Info.plist)

# Assemble outside the project: synced folders (iCloud Drive) add Finder metadata that codesign rejects.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

# Prints the first valid identity whose name starts with one of the given prefixes (extended regex).
find_identity() {
    security find-identity -v -p "$1" | sed -nE "s/.*\"(($2): .*)\"/\1/p" | head -1
}

if [ "$MODE" = mas ]; then
    PROFILE=${2:-}
    APP_IDENTITY=$(find_identity codesigning "Apple Distribution|3rd Party Mac Developer Application")
    INSTALLER_IDENTITY=$(find_identity basic "3rd Party Mac Developer Installer|Mac Installer Distribution")
    MISSING=()
    xcodebuild -version >/dev/null 2>&1 || MISSING+=("Xcode (App Store builds need a released Xcode and SDK, not just the Command Line Tools)")
    [ -n "$APP_IDENTITY" ] || MISSING+=("an \"Apple Distribution\" certificate and its private key in the keychain")
    [ -n "$INSTALLER_IDENTITY" ] || MISSING+=("a \"Mac Installer Distribution\" (3rd Party Mac Developer Installer) certificate and its private key in the keychain")
    if [ -z "$PROFILE" ]; then
        MISSING+=("a Mac App Store provisioning profile: ./build.sh mas path/to/TransferSpeed.provisionprofile")
    elif [ ! -f "$PROFILE" ]; then
        MISSING+=("the provisioning profile \"$PROFILE\" (file not found)")
    fi
    if [ ${#MISSING[@]} -gt 0 ]; then
        echo "Can't build for the Mac App Store. Missing:" >&2
        printf '  - %s\n' "${MISSING[@]}" >&2
        echo "See docs/APP_STORE.md for how to create them." >&2
        exit 1
    fi

    security cms -D -i "$PROFILE" >"$WORK/profile.plist" 2>/dev/null || fail "\"$PROFILE\" is not a provisioning profile"
    TEAM=$($PLISTBUDDY -c "Print :TeamIdentifier:0" "$WORK/profile.plist")
    PROFILE_APP_ID=$($PLISTBUDDY -c "Print :Entitlements:com.apple.application-identifier" "$WORK/profile.plist")
    EXPIRES=$(plutil -extract ExpirationDate raw -o - "$WORK/profile.plist")
    # Development and Developer ID profiles list devices or all devices; App Store profiles list neither.
    if $PLISTBUDDY -c "Print :ProvisionedDevices" "$WORK/profile.plist" >/dev/null 2>&1 ||
        $PLISTBUDDY -c "Print :ProvisionsAllDevices" "$WORK/profile.plist" >/dev/null 2>&1; then
        fail "\"$PROFILE\" is not a Mac App Store distribution profile"
    fi
    [ "$PROFILE_APP_ID" = "$TEAM.$BUNDLE_ID" ] || fail "the profile is for $PROFILE_APP_ID, but the bundle ID is $TEAM.$BUNDLE_ID"
    [[ "$EXPIRES" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]] || fail "the provisioning profile expired on $EXPIRES"
    [[ "$APP_IDENTITY" == *"($TEAM)" ]] || fail "\"$APP_IDENTITY\" is not from team $TEAM, which the profile belongs to"
    [[ "$INSTALLER_IDENTITY" == *"($TEAM)" ]] || fail "\"$INSTALLER_IDENTITY\" is not from team $TEAM, which the profile belongs to"

    SIGN=(--sign "$APP_IDENTITY" --options runtime --timestamp)
    echo "Signing as $APP_IDENTITY"
else
    IDENTITY=$(find_identity codesigning "Developer ID Application")
    if [ -n "$IDENTITY" ]; then
        SIGN=(--sign "$IDENTITY" --options runtime --timestamp)
        echo "Signing as $IDENTITY"
    else
        SIGN=(--sign -)
        echo "No Developer ID certificate found; signing ad-hoc"
    fi
fi

# SwiftPM's linker call doesn't tell clang the SDK, so without -isysroot the binary claims it was built with the
# deployment target's SDK (macOS 15) and runs with that release's compatibility behaviour.
BUILD=(-c release --arch arm64 --arch x86_64
    -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$(xcrun --sdk macosx --show-sdk-path)")
swift build "${BUILD[@]}"
BIN="$(swift build "${BUILD[@]}" --show-bin-path)/TransferSpeed"

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift Resources/AppIcon.icns

APP="$WORK/Transfer Speed.app"
PLIST="$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TransferSpeed"
cp Resources/Info.plist "$PLIST"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
$PLISTBUDDY -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"

if [ "$MODE" = mas ]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    cp "$ENTITLEMENTS" "$WORK/mas.entitlements"
    $PLISTBUDDY -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" \
        -c "Add :com.apple.developer.team-identifier string $TEAM" "$WORK/mas.entitlements"
    ENTITLEMENTS="$WORK/mas.entitlements"

    # App Store Connect reads the toolchain keys Xcode writes into Info.plist to enforce its SDK minimums.
    XCODE_VERSION=$(xcodebuild -version | sed -n 's/^Xcode //p')
    XCODE_BUILD=$(xcodebuild -version | sed -n 's/^Build version //p')
    IFS=. read -r MAJOR MINOR PATCH <<<"$XCODE_VERSION"
    SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
    SDK_BUILD=$(xcrun --sdk macosx --show-sdk-build-version)
    $PLISTBUDDY \
        -c "Add :DTXcode string $(printf '%02d%d%d' "$MAJOR" "${MINOR:-0}" "${PATCH:-0}")" \
        -c "Add :DTXcodeBuild string $XCODE_BUILD" \
        -c "Add :DTSDKName string macosx$SDK_VERSION" \
        -c "Add :DTSDKBuild string $SDK_BUILD" \
        -c "Add :DTPlatformName string macosx" \
        -c "Add :DTPlatformVersion string $SDK_VERSION" \
        -c "Add :DTPlatformBuild string $SDK_BUILD" \
        -c "Add :DTCompiler string com.apple.compilers.llvm.clang.1_0" \
        -c "Add :BuildMachineOSBuild string $(sw_vers -buildVersion)" \
        "$PLIST"
fi

xattr -cr "$APP"
codesign --force "${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict "$APP"
mkdir -p build

if [ "$MODE" = mas ]; then
    NAME="TransferSpeed-$VERSION.pkg"
    productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$WORK/$NAME"
    pkgutil --check-signature "$WORK/$NAME"
    cp "$WORK/$NAME" "build/$NAME"
    echo "Built build/$NAME for $BUNDLE_ID. Upload it with Transporter or xcrun altool (see docs/APP_STORE.md)."
    exit 0
fi

rm -rf "build/Transfer Speed.app"
ditto --noextattr "$APP" "build/Transfer Speed.app"
echo "Built build/Transfer Speed.app"

if [ "$MODE" = dmg ]; then
    NAME="TransferSpeed-$VERSION.dmg"
    STAGING="$WORK/staging"
    mkdir "$STAGING"
    mv "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "Transfer Speed" -srcfolder "$STAGING" -fs HFS+ -format UDZO "$WORK/$NAME" >/dev/null
    codesign --force "${SIGN[@]}" "$WORK/$NAME"

    if [ -n "$IDENTITY" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
        xcrun notarytool submit "$WORK/$NAME" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$WORK/$NAME"
        spctl --assess --type open --context context:primary-signature --verbose "$WORK/$NAME"
    elif [ -n "$IDENTITY" ]; then
        echo "Set NOTARY_PROFILE to notarize the DMG"
    fi
    cp "$WORK/$NAME" "build/$NAME"
    echo "Built build/$NAME"
fi
