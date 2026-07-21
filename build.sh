#!/bin/bash
# Regenerate the Xcode project and build (and optionally run) Shelf.
set -e
cd "$(dirname "$0")"

echo "▸ Generating Xcode project…"
xcodegen generate

CONFIG="${CONFIG:-Debug}"
DERIVED="build"

echo "▸ Building ($CONFIG)…"
xcodebuild \
  -project Shelf.xcodeproj \
  -scheme Shelf \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  build "$@" | grep -E '(error:|warning:|BUILD |Compiling|Linking)' || true

APP="$DERIVED/Build/Products/$CONFIG/Shelf.app"
if [ -d "$APP" ]; then
  echo "▸ Built: $APP"
  if [ "$1" == "run" ] || [ "$2" == "run" ]; then
    echo "▸ Launching…"
    open "$APP"
  fi
fi
