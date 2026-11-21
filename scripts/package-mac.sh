#!/bin/sh
# Builds the Mac app for distribution and packages it as a .zip and a .dmg in
# build/dist/. Uses only tools that ship with macOS and Xcode.
#
#   scripts/package-mac.sh
#
# Signing follows Config/Signing.xcconfig: the certificate in the git-ignored
# Config/Signing.local.xcconfig when present (a stable identity, so users'
# Accessibility permission survives updates), otherwise ad-hoc. Pass --adhoc to
# force ad-hoc. Without a Developer ID + notarization, users still clear the
# quarantine flag once (xattr -d com.apple.quarantine /Applications/ClipStack.app).
set -eu

cd "$(dirname "$0")/.."
DERIVED=build/DerivedData-release
DIST=build/dist
APP="$DERIVED/Build/Products/Release/ClipStack.app"

SIGNING=""
[ "${1:-}" = "--adhoc" ] && SIGNING="CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="

xcodegen generate >/dev/null
# shellcheck disable=SC2086 # SIGNING is intentionally split into settings
xcodebuild -project ClipStack.xcodeproj -scheme ClipStack -configuration Release \
  -derivedDataPath "$DERIVED" $SIGNING \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"
# The identity the app was signed with ("" when ad-hoc), reused for the DMG.
IDENTITY=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)
mkdir -p "$DIST"

# Zip (the format of earlier releases).
ZIP="$DIST/ClipStack-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# DMG: the app next to an Applications shortcut, so installing is a drag.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/ClipStack.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/ClipStack-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "ClipStack $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
# Sign the disk image itself with the app's certificate, so tampering shows.
[ -n "$IDENTITY" ] && codesign --sign "$IDENTITY" --timestamp=none "$DMG"

echo "Packaged ClipStack $VERSION (signed by: ${IDENTITY:-ad-hoc}):"
ls -lh "$ZIP" "$DMG" | awk '{print "  " $5 "  " $9}'
