#!/bin/bash
# Builds Flick.app. Pass --install to copy it into /Applications and start it.
#
# Signed with a local key kept in .signing, not ad hoc. macOS ties Accessibility and
# Screen Recording to the signature, so a stable key means rebuilds keep both.
set -euo pipefail
cd "$(dirname "$0")"

# 26.5 has NSGlassEffectView and still builds SwiftUI's @State without the macro
# plugin these command line tools lack. The 27 SDK needs that plugin.
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[ -d "$SDK" ] || SDK="$(xcrun --show-sdk-path)"
TARGET="$(uname -m)-apple-macosx13.0"

mkdir -p build assets .signing

KC="$PWD/.signing/flick.keychain-db"
if [ ! -f "$KC" ]; then
    cd .signing
    cat > cert.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Flick Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
    openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf 2>/dev/null
    openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:flick -name "Flick Local Signing" \
        -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
    security create-keychain -p flick "$KC"
    security set-keychain-settings "$KC"
    security unlock-keychain -p flick "$KC"
    security import id.p12 -k "$KC" -P flick -T /usr/bin/codesign -A >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k flick "$KC" >/dev/null 2>&1
    rm -f id.p12 key.pem cert.cnf
    cd ..
fi
security unlock-keychain -p flick "$KC"
IDENTITY="$(openssl x509 -in .signing/cert.pem -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"

if [ ! -f assets/AppIcon.icns ]; then
    swiftc -O -sdk "$SDK" -target "$TARGET" tools/make_icon.swift -o build/make_icon
    build/make_icon assets/icon_1024.png
    ICONSET=build/AppIcon.iconset
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o assets/AppIcon.icns
fi

swiftc -O -wmo -sdk "$SDK" -target "$TARGET" Sources/Flick/*.swift -o build/Flick

APP="build/Flick.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/Flick "$APP/Contents/MacOS/Flick"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Flick</string>
    <key>CFBundleDisplayName</key><string>Flick</string>
    <key>CFBundleIdentifier</key><string>local.flick.app</string>
    <key>CFBundleExecutable</key><string>Flick</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppSleepDisabled</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --keychain "$KC" --sign "$IDENTITY" --identifier local.flick.app "$APP"
echo "Built: $APP"

if [ "${1:-}" = "--install" ]; then
    AGENT="$HOME/Library/LaunchAgents/local.flick.app.plist"
    launchctl bootout "gui/$(id -u)/local.flick.app" 2>/dev/null || true
    pkill -x Flick 2>/dev/null || true
    sleep 0.4
    rm -rf /Applications/Flick.app
    cp -R "$APP" /Applications/Flick.app
    if [ -f "$AGENT" ]; then
        launchctl bootstrap "gui/$(id -u)" "$AGENT"
    else
        open /Applications/Flick.app
    fi
    echo "Installed: /Applications/Flick.app"
fi
