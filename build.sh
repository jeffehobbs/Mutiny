#!/bin/bash
# Regenerate the Xcode project and build (and optionally run) Mutiny.
set -e
cd "$(dirname "$0")"

echo "▸ Generating Xcode project…"
xcodegen generate

CONFIG="${CONFIG:-Debug}"
DERIVED="build"

echo "▸ Building ($CONFIG)…"
xcodebuild \
  -project Mutiny.xcodeproj \
  -scheme Mutiny \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  build "$@" | grep -E '(error:|warning:|BUILD |Compiling|Linking)' || true

APP="$DERIVED/Build/Products/$CONFIG/Mutiny.app"
if [ -d "$APP" ]; then
  echo "▸ Built: $APP"
  if [ "$1" == "run" ] || [ "$2" == "run" ]; then
    echo "▸ Launching…"
    open "$APP"
  fi
fi
