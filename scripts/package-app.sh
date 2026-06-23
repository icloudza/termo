#!/bin/bash
# 把 SwiftPM 可执行文件打包成带图标的标准 macOS .app
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/termo.app"
NAME="termo"

echo "▸ 编译 release…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

echo "▸ 组装 $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 可执行文件
cp "$BIN/$NAME" "$APP/Contents/MacOS/$NAME"

# SwiftPM 资源 bundle（Bundle.module 依赖它）
for b in "$BIN"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/MacOS/"
done

# 应用图标
cp "$ROOT/Sources/termo/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>termo</string>
    <key>CFBundleDisplayName</key><string>termo</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>com.termo.app</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# 刷新 Finder 图标缓存
touch "$APP"
echo "✓ 完成：$APP"
