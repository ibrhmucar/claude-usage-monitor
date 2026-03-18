#!/bin/bash
set -e
APP_NAME="ClaudeUsageMonitor"
DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="$DIR/build"
APP="$BUILD/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RESOURCES="$APP/Contents/Resources"

echo ""
echo "🧠 Claude Usage Monitor - Build"
echo "===================================="
echo ""

rm -rf "$BUILD"; mkdir -p "$MACOS" "$RESOURCES"

# Icon
if [ -d "$DIR/AppIcon.iconset" ]; then
    echo "🎨 İkon oluşturuluyor..."
    iconutil -c icns "$DIR/AppIcon.iconset" -o "$RESOURCES/AppIcon.icns" 2>/dev/null \
        && echo "✅ İkon eklendi!" \
        || echo "⚠️  İkon oluşturulamadı, devam ediliyor..."
fi

# Compile
echo "⚙️  Derleniyor..."
swiftc -o "$MACOS/$APP_NAME" -O -whole-module-optimization \
    -target arm64-apple-macosx13.0 -sdk $(xcrun --show-sdk-path) \
    -framework Cocoa -framework SwiftUI -framework Combine \
    "$DIR/$APP_NAME.swift"
echo "✅ Derleme başarılı!"

# Info.plist
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeUsageMonitor</string>
    <key>CFBundleIdentifier</key><string>com.claude.usage-monitor</string>
    <key>CFBundleName</key><string>Claude Usage Monitor</string>
    <key>CFBundleDisplayName</key><string>Claude Usage Monitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.1</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
</dict>
</plist>
PLIST

# DMG
echo "📦 DMG oluşturuluyor..."
DMG="$DIR/$APP_NAME.dmg"; rm -f "$DMG"
TMP="$BUILD/dmg_tmp"; mkdir -p "$TMP"
cp -R "$APP" "$TMP/"; ln -s /Applications "$TMP/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$TMP" -ov -format UDZO "$DMG" > /dev/null 2>&1
rm -rf "$TMP"
echo "✅ DMG: $DMG"; echo ""

# Install
read -p "🚀 /Applications'a kurulsun mu? (e/h): " -n 1 -r; echo ""
if [[ $REPLY =~ ^[Ee]$ ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true; sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "✅ Kuruldu!"
    open "/Applications/$APP_NAME.app"
fi

echo ""
echo "===================================="
echo "Üst bardaki simgeye tıklayıp ayarları gir."
echo "===================================="
