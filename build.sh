#!/bin/bash
# Regenerate the Xcode project and build Mutiny.
#
#   ./build.sh              generate project + Debug build
#   ./build.sh run          build and launch
#   ./build.sh release       Release build, ad-hoc signed (local)
#   ./build.sh notarize      Release build → Developer ID sign (hardened runtime)
#                            → notarize → staple → dist/Mutiny-<ver>.zip
#
# Notarizing needs a one-time stored credential profile (Apple ID method):
#   xcrun notarytool store-credentials mutiny-notary \
#     --apple-id "you@example.com" --team-id YKF353373Y \
#     --password "<app-specific-password>"
# Override the profile name with NOTARY_PROFILE=... if you used a different one.
set -e
cd "$(dirname "$0")"

MODE="${1:-debug}"
NOTARY_PROFILE="${NOTARY_PROFILE:-mutiny-notary}"
DEV_ID="${DEV_ID:-Developer ID Application}"   # matched as a substring by codesign

echo "▸ Generating Xcode project…"
xcodegen generate

if [ "$MODE" == "release" ] || [ "$MODE" == "notarize" ]; then
  CONFIG=Release
else
  CONFIG="${CONFIG:-Debug}"
fi
DERIVED="build"

echo "▸ Building ($CONFIG)…"
xcodebuild \
  -project Mutiny.xcodeproj \
  -scheme Mutiny \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  build | grep -E '(error:|warning:|BUILD |Compiling|Linking)' || true

APP="$DERIVED/Build/Products/$CONFIG/Mutiny.app"
if [ ! -d "$APP" ]; then
  echo "✗ Build did not produce $APP" >&2
  exit 1
fi
echo "▸ Built: $APP"

case "$MODE" in
  run)
    echo "▸ Launching…"; open "$APP" ;;

  release)
    codesign --force --deep --sign - "$APP"
    mkdir -p dist
    VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
    ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/Mutiny-$VER.zip"
    echo "▸ Ad-hoc release zip: dist/Mutiny-$VER.zip (unsigned distribution — Gatekeeper will warn)" ;;

  notarize)
    VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
    mkdir -p dist

    echo "▸ Signing with Developer ID (hardened runtime + secure timestamp)…"
    codesign --force --timestamp --options runtime \
      --entitlements Mutiny.entitlements \
      --sign "$DEV_ID" "$APP"
    codesign --verify --strict --verbose=2 "$APP"

    echo "▸ Zipping for submission…"
    SUBMIT_ZIP="dist/Mutiny-$VER-submit.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMIT_ZIP"

    echo "▸ Submitting to Apple notary service (this can take a few minutes)…"
    xcrun notarytool submit "$SUBMIT_ZIP" \
      --keychain-profile "$NOTARY_PROFILE" --wait

    echo "▸ Stapling ticket…"
    xcrun stapler staple "$APP"

    echo "▸ Verifying…"
    xcrun stapler validate "$APP"
    spctl -a -vvv --type execute "$APP" || true

    DIST_ZIP="dist/Mutiny-$VER.zip"
    rm -f "$SUBMIT_ZIP" "$DIST_ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST_ZIP"
    echo "▸ Notarized & stapled: $DIST_ZIP" ;;
esac
