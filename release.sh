#!/bin/bash
# Builds a universal Flick.app and packs it into build/Flick.dmg, with an
# Applications shortcut to drag it onto. Publish with:
#   gh release create v<version> build/Flick.dmg
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=1 ./build.sh
STAGE=build/dmg
rm -rf "$STAGE" build/Flick.dmg
mkdir -p "$STAGE"
ditto build/Flick.app "$STAGE/Flick.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Flick -srcfolder "$STAGE" -ov -format UDZO build/Flick.dmg >/dev/null
rm -rf "$STAGE"
codesign --verify --deep --strict build/Flick.app
echo "Packed: build/Flick.dmg ($(du -h build/Flick.dmg | cut -f1)), $(lipo -archs build/Flick.app/Contents/MacOS/Flick)"
