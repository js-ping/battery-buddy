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

# 把 batt 二进制一并打包，让 app 自包含（首次运行自动铺到 ~/.local/bin）
BATT_SRC="$HOME/.local/bin/batt"
[ -x "$BATT_SRC" ] || BATT_SRC="/usr/local/bin/batt"
if [ -x "$BATT_SRC" ]; then
    cp "$BATT_SRC" "$APP/Contents/Resources/batt"
    chmod 755 "$APP/Contents/Resources/batt"
    echo "    已内置 batt ($(du -h "$BATT_SRC" | cut -f1))"
else
    echo "    ⚠️ 未找到 batt，构建产物不自包含"
fi

codesign -s - --force --deep "$APP"

echo "==> 打 dmg"
STAGE="$BUILD/dmg_stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -sfn /Applications "$STAGE/Applications"

# 备用卸载工具：app 打不开时用它
cat > "$STAGE/卸载.command" <<'UNINSTALL_EOF'
#!/bin/bash
clear
echo "=========================================="
echo "  电池管家 - 卸载"
echo "=========================================="
echo ""
echo "将停止充电限制、删除后台服务与所有配置文件。"
echo "需要输一次开机密码。"
echo ""
read -n 1 -s -r -p "按任意键继续..."
echo ""

B="$HOME/.local/bin/batt"
[ -x "$B" ] && sudo "$B" uninstall >/dev/null 2>&1

sudo launchctl bootout system/cc.chlc.batt >/dev/null 2>&1
sudo rm -f /Library/LaunchDaemons/cc.chlc.batt.plist
sudo rm -f /etc/batt.json
rm -f "$HOME/.local/bin/batt"
rm -f "$HOME/Library/LaunchAgents/com.ping.batterybuddy.plist"
rm -rf "/Applications/电池管家.app"

echo ""
echo "✅ 已卸载，充电行为恢复为 macOS 默认。"
echo ""
read -n 1 -s -r -p "按任意键关闭..."
UNINSTALL_EOF
chmod +x "$STAGE/卸载.command"

rm -f "$BUILD/$APP_NAME.dmg" 2>/dev/null || true
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$BUILD/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGE" 2>/dev/null || true

echo ""
echo "完成："
echo "  $APP"
echo "  $BUILD/$APP_NAME.dmg"
