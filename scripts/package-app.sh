#!/bin/bash
# 把 SwiftPM 可执行文件打包成带图标的标准 macOS .app
set -e

# SwiftPM 需要完整 Xcode 工具链（actool 等）编译依赖里的 .xcassets 资源并生成 Bundle.module；
# 仅装 Command Line Tools 会报 “type 'Bundle' has no member 'module'”。检测到 Xcode 则指向它（仅本次构建生效）。
if [ -z "$DEVELOPER_DIR" ] && [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

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

# 本地化目录：声明支持简体中文/英文，使系统对话框（上传/保存等文件面板）跟随系统语言。
# AppKit 据 Bundle 的 .lproj 目录解析可用语言，再与系统首选语言取交集决定界面语言。
for loc in zh-Hans en; do
    mkdir -p "$APP/Contents/Resources/$loc.lproj"
    : > "$APP/Contents/Resources/$loc.lproj/Localizable.strings"
done

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
    <key>CFBundleShortVersionString</key><string>0.7.45</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>en</string>
    </array>
    <key>CFBundleAllowMixedLocalizations</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc 签名：UNUserNotificationCenter（上传/下载完成通知）要求 .app 有代码签名，未签名会拿不到授权；
# 顺带让代码签名相对稳定，减少钥匙串重复授权。如已配置开发者证书可把 "-" 换成对应身份。
echo "▸ 签名（ad-hoc）…"
codesign --force --deep --sign - "$APP" || echo "⚠️ 签名失败（通知可能不可用）"

# 刷新 Finder 图标缓存
touch "$APP"
echo "✓ 完成：$APP"
