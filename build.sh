#!/bin/bash
# 构建「共享转换器」菜单栏 app（通用二进制，macOS 13+）并打包 DMG
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="共享转换器"
EXEC_NAME="SMBConverter"
BUNDLE_ID="com.huimei.shareconverter"
DEPLOY="13.0"
BUILD_DIR="build"
ICONSET="$BUILD_DIR/AppIcon.iconset"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
DIST_DIR="dist"
DMG="$DIST_DIR/$APP_NAME.dmg"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> 1/6 生成图标"
if [ ! -f "$BUILD_DIR/icon-1024.png" ] || [ makeicon.swift -nt "$BUILD_DIR/icon-1024.png" ]; then
  swift makeicon.swift "$BUILD_DIR/icon-1024.png" >/dev/null
fi
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
SRC="$BUILD_DIR/icon-1024.png"
gen() { sips -z "$2" "$2" "$SRC" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png      128
gen icon_128x128@2x.png   256
gen icon_256x256.png      256
gen icon_256x256@2x.png   512
gen icon_512x512.png      512
cp "$SRC" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$BUILD_DIR/AppIcon.icns"

echo "==> 2/6 编译 arm64 / x86_64"
swiftc -O SMBConverter.swift \
  -target arm64-apple-macos$DEPLOY \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$BUILD_DIR/$EXEC_NAME.arm64"
swiftc -O SMBConverter.swift \
  -target x86_64-apple-macos$DEPLOY \
  -framework SwiftUI -framework AppKit -framework ServiceManagement \
  -o "$BUILD_DIR/$EXEC_NAME.x86_64"

echo "==> 3/6 合并通用二进制"
lipo -create "$BUILD_DIR/$EXEC_NAME.arm64" "$BUILD_DIR/$EXEC_NAME.x86_64" \
  -output "$BUILD_DIR/$EXEC_NAME"
rm -f "$BUILD_DIR/$EXEC_NAME.arm64" "$BUILD_DIR/$EXEC_NAME.x86_64"

echo "==> 4/6 打包 .app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$EXEC_NAME" "$APP_DIR/Contents/MacOS/$EXEC_NAME"
cp "$BUILD_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXEC_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>$DEPLOY</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>SMB 共享路径转换工具</string>
</dict>
</plist>
PLIST

echo "==> 5/6 Ad-hoc 签名"
codesign --force --sign - "$APP_DIR"

echo "==> 6/6 打包 DMG"
HELP_HTML="共享转换器-使用说明.html"
STAGE="$BUILD_DIR/dmg-staging"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# 使用说明（双击在浏览器打开，离线可读）
cp "$HELP_HTML" "$STAGE/使用说明.html"
# 卷图标（与 app 同款）
cp "$BUILD_DIR/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

RW_DMG="$BUILD_DIR/$APP_NAME.rw.dmg"
rm -f "$RW_DMG" "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -fs HFS+ -format UDRW "$RW_DMG" >/dev/null

# 挂载 → 标记卷图标 + 排列安装窗口 → 卸载 → 压缩为只读
MOUNT_OUT=$(hdiutil attach "$RW_DMG" -nobrowse -readwrite | grep "/Volumes/$APP_NAME")
MOUNT_POINT=$(echo "$MOUNT_OUT" | awk -F'\t' '{print $NF}')
SetFile -a C "$MOUNT_POINT"

# 用 Finder 记录图标视图布局（需要“自动操作/Finder”权限，失败不影响打包）
osascript <<'OSA' 2>/dev/null || true
tell application "Finder"
  set d to disk "共享转换器"
  tell container window of d
    set toolbar visible to false
    set statusbar visible to false
    set current view to icon view
    set bounds to {100, 100, 560, 460}
  end tell
  set icon size of icon view options of container window of d to 96
  set arrangement of icon view options of container window of d to not arranged
  set position of item "共享转换器.app" of d to {110, 130}
  set position of item "Applications" of d to {330, 130}
  set position of item "使用说明.html" of d to {220, 280}
  close container window of d
end tell
OSA

hdiutil detach "$MOUNT_POINT" >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$RW_DMG"; rm -rf "$STAGE"

echo ""
echo "✅ 完成"
echo "   App: $APP_DIR"
echo "   DMG: $DMG"
