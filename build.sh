#!/bin/bash
# 一键构建：编译 → 生成图标 → 组装 app → 签名 → 打 dmg
set -e
cd "$(dirname "$0")"

APP_NAME="电池管家"
BIN_NAME="BatteryBuddy"
BUILD="build"
APP="$BUILD/$APP_NAME.app"

echo "==> 清理"
rm -rf "$BUILD" 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译主程序"
swiftc -O -swift-version 5 -o "$BUILD/$BIN_NAME" main.swift -framework Cocoa

echo "==> 生成图标"
if [ -f make_icon.swift ]; then
    swiftc -O -o "$BUILD/make_icon" make_icon.swift -framework Cocoa
    "$BUILD/make_icon" "$BUILD/icon_raw.png"
    sips -z 1024 1024 "$BUILD/icon_raw.png" --out "$BUILD/icon_1024.png" >/dev/null
    rm -rf "$BUILD/AppIcon.iconset" 2>/dev/null || true
    mkdir -p "$BUILD/AppIcon.iconset"
    for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
                "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
                "512 icon_256x256@2x" "512 icon_512x512"; do
        set -- $spec
        sips -z "$1" "$1" "$BUILD/icon_1024.png" --out "$BUILD/AppIcon.iconset/$2.png" >/dev/null
    done
    cp "$BUILD/icon_1024.png" "$BUILD/AppIcon.iconset/icon_512x512@2x.png"
    iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
    cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 组装 app"
cp "$BUILD/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
cp Info.plist "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/$BIN_NAME"
codesign -s - --force --deep "$APP"

echo "==> 打 dmg"
STAGE="$BUILD/dmg_stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -sfn /Applications "$STAGE/Applications"
rm -f "$BUILD/$APP_NAME.dmg" 2>/dev/null || true
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$BUILD/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGE" 2>/dev/null || true

echo ""
echo "完成："
echo "  $APP"
echo "  $BUILD/$APP_NAME.dmg"
