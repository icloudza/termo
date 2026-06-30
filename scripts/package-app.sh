#!/bin/bash
#
# Termo 打包脚本 —— Xcode archive 管线产出去符号、瘦身的 Termo.app 与品牌 DMG。
#
#   构建   : xcodebuild archive（Release / arm64 / -Osize / strip / 分离 dSYM）
#   产物   : dist/<版本>/Termo.app、dist/<版本>/Termo-<版本>.dmg、dist/dSYMs/<版本>/
#   签名   : ad-hoc（"-"）。Developer ID 公证/装订见文末 RELEASE 说明（待付费账号到位）。
#
# 依赖：Xcode、create-dmg(brew)。DMG 布局经 Finder/AppleScript 设定，需在图形会话(本机终端)运行。
#
set -euo pipefail

# ── 配置 ────────────────────────────────────────────────────────────────────
SCHEME="Termo"
APP_NAME="Termo"
VOLNAME="Termo"
TEAM_ID="KTP97H9YFF"                  # 付费团队「Huidong Liu」(lxc.rudy@qq.com)，Developer ID 签名/公证用
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.xcbuild"                 # 中间产物（gitignore）
ARCHIVE="$WORK/$APP_NAME.xcarchive"
LOG="$WORK/build.log"

# ── 日志框架 ────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; RST=""
fi
STEP=0
section() { printf '\n%s━━ %s %s━━━━━━━━━━━━━━━━━━━━%s\n' "$BOLD$BLU" "$1" "$DIM" "$RST"; }
step()    { STEP=$((STEP+1)); printf '%s[%d]%s %s\n' "$BOLD" "$STEP" "$RST" "$1"; }
info()    { printf '    %s%s%s\n' "$DIM" "$1" "$RST"; }
ok()      { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
warn()    { printf '    %s⚠%s  %s\n' "$YLW" "$RST" "$1"; }
die()     { printf '\n%s✗ 失败：%s%s\n' "$BOLD$RED" "$1" "$RST" >&2; exit 1; }

# 出错时定位到行号并附上构建日志末尾，便于排查。
trap 'rc=$?; [ $rc -ne 0 ] && { printf "\n%s✗ 脚本第 %s 行中止（退出码 %s）%s\n" "$BOLD$RED" "$LINENO" "$rc" "$RST" >&2;
       [ -f "$LOG" ] && { echo "—— build.log 末 40 行 ——" >&2; tail -40 "$LOG" >&2; }; }' ERR

# 运行 xcodebuild：全量输出入日志文件，终端只留结论；失败由 trap 兜底打印日志尾。
run_quiet() { "$@" >>"$LOG" 2>&1; }

START=$(date +%s)
mkdir -p "$WORK"; : > "$LOG"

# ── 预检 ────────────────────────────────────────────────────────────────────
section "预检"
[ -d "$DEVELOPER_DIR" ] || die "未找到 Xcode（DEVELOPER_DIR=$DEVELOPER_DIR）"
command -v create-dmg >/dev/null || die "未安装 create-dmg，请先：brew install create-dmg"
ok "Xcode：$(basename "$(dirname "$(dirname "$DEVELOPER_DIR")")")"
ok "create-dmg：$(command -v create-dmg)"
info "构建日志：$LOG"

# ── 签名身份决议 ────────────────────────────────────────────────────────────
# 钥匙串有 Developer ID Application 证书 → 正式签名（加固运行时 + 安全时间戳，可公证分发）；
# 没有 → 回退 ad-hoc（仅本地自测；分发到其它 Mac 会被 Gatekeeper 拦）。
# 末尾 `|| true`：无证书时 grep 返回非 0，在 pipefail 下会让赋值失败、触发 set -e；兜住它。
DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o 'Developer ID Application: [^"]*' | head -1 || true)"
NOTARY_PROFILE="${NOTARY_PROFILE:-termo-notary}"   # notarytool 钥匙串凭证名（见文末 RELEASE 说明）
NOTARIZED=false
if [ -n "$DEVID" ]; then
    ok "签名身份：$DEVID"
else
    warn "无 Developer ID Application 证书 → 本次 ad-hoc（仅自测）"
fi

# ── 归档 ────────────────────────────────────────────────────────────────────
section "归档（Release / arm64 / 去符号）"
step "xcodebuild archive…"
rm -rf "$ARCHIVE"
# Developer ID：正式签名 + 加固运行时 + 时间戳（公证前置条件）；否则 ad-hoc。
if [ -n "$DEVID" ]; then
    SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVID" DEVELOPMENT_TEAM="$TEAM_ID" \
          ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp")
else
    SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="")
fi
run_quiet xcodebuild archive \
    -project "$ROOT/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$WORK/dd" \
    "${SIGN[@]}"
PRODUCT="$ARCHIVE/Products/Applications/$APP_NAME.app"
[ -d "$PRODUCT" ] || die "未找到归档产物：$PRODUCT"
ok "归档完成"

# 版本号（决定输出目录）
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PRODUCT/Contents/Info.plist")"
BUILDNO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PRODUCT/Contents/Info.plist")"
DIST="$ROOT/dist/${VERSION}-${BUILDNO}"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
mkdir -p "$DIST"

# ── 导出 ────────────────────────────────────────────────────────────────────
section "导出产物"
step "导出 .app 与 dSYM…"
rm -rf "$APP"; cp -R "$PRODUCT" "$APP"
ok "App → ${APP#$ROOT/}"
if ls "$ARCHIVE/dSYMs/"*.dSYM >/dev/null 2>&1; then
    DSYM="$ROOT/dist/dSYMs/${VERSION}-${BUILDNO}"; mkdir -p "$DSYM"
    cp -R "$ARCHIVE/dSYMs/"*.dSYM "$DSYM/"
    ok "dSYM → ${DSYM#$ROOT/}"
else
    warn "未找到 dSYM（崩溃将无法符号化）"
fi

# ── 公证 App（仅 Developer ID 签名时）────────────────────────────────────────
# 顺序：先公证 + 装订 App，再据此做 DMG（DMG 内即为已装订 App），最后单独公证 DMG。
if [ -n "$DEVID" ]; then
    section "公证 App（notarytool）"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        step "提交 App 公证（--wait，初次比较慢，期间请勿中断）…"
        ZIP="$WORK/app.zip"; rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        # 不走 run_quiet：notarytool 轮询期间需把状态实时显示在终端，否则看似卡死易被误中断。
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee -a "$LOG"
        xcrun stapler staple "$APP" >>"$LOG" 2>&1 \
            && { ok "App 公证 + 装订完成"; NOTARIZED=true; } \
            || die "App 装订失败（公证可能被拒，详见 $LOG）"
    else
        warn "未配置 notarytool 凭证（profile：$NOTARY_PROFILE）→ 跳过公证，仅 Developer ID 签名"
        warn "先建凭证（一次）：xcrun notarytool store-credentials $NOTARY_PROFILE \\"
        warn "      --apple-id <你的AppleID> --team-id $TEAM_ID --password <App 专用密码>"
    fi
fi

# ── DMG ─────────────────────────────────────────────────────────────────────
section "制作 DMG"
step "生成品牌背景…"
run_quiet swift "$ROOT/scripts/make-dmg-background.swift" "$WORK"
BG="$WORK/background.tiff"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$BG" >>"$LOG" 2>&1
ok "背景图（含 @2x）"

step "create-dmg 布局打包…"
STAGE="$WORK/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"
rm -f "$DMG"
# create-dmg 成功仍可能返回非 0（签名 DMG 卷标等），故单独判定产物是否生成。
create-dmg \
    --volname "$VOLNAME" \
    --background "$BG" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 170 198 \
    --app-drop-link 490 198 \
    --hide-extension "$APP_NAME.app" \
    --no-internet-enable \
    "$DMG" "$STAGE" >>"$LOG" 2>&1 || true
[ -f "$DMG" ] || die "DMG 未生成（详见 $LOG）"
ok "DMG → ${DMG#$ROOT/}"

# ── 公证 DMG（App 已公证时）──────────────────────────────────────────────────
if [ "$NOTARIZED" = true ]; then
    section "公证 DMG"
    step "提交 DMG 公证（--wait，期间请勿中断）…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee -a "$LOG"
    xcrun stapler staple "$DMG" >>"$LOG" 2>&1 && ok "DMG 公证 + 装订完成" || die "DMG 装订失败（详见 $LOG）"
fi

# ── 验收 ────────────────────────────────────────────────────────────────────
section "验收"
BIN="$APP/Contents/MacOS/$APP_NAME"
codesign --verify --deep --strict --verbose=2 "$APP" >>"$LOG" 2>&1 \
    && ok "签名校验通过（$([ -n "$DEVID" ] && echo "Developer ID" || echo "ad-hoc")）" \
    || warn "签名校验未通过"
if [ "$NOTARIZED" = true ]; then
    spctl --assess --type execute -vv "$APP" >>"$LOG" 2>&1 \
        && ok "Gatekeeper 验收通过（已公证 + 装订）" || warn "Gatekeeper 验收未通过（详见 $LOG）"
fi
WARNS=$(grep -c ": warning:" "$LOG" 2>/dev/null | tr -d ' ' || echo 0)
ELAPSED=$(( $(date +%s) - START ))

printf '\n%s──────── 产物概览 ────────%s\n' "$BOLD" "$RST"
printf '  版本     : %s (build %s)\n' "$VERSION" "$BUILDNO"
printf '  App 体积 : %s\n' "$(du -sh "$APP" | cut -f1)"
printf '  DMG 体积 : %s\n' "$(du -sh "$DMG" | cut -f1)"
printf '  架构     : %s\n' "$(lipo -archs "$BIN" 2>/dev/null)"
printf '  签名     : %s\n' "$([ -n "$DEVID" ] && { [ "$NOTARIZED" = true ] && echo 'Developer ID + 已公证（可分发）' || echo 'Developer ID（未公证）'; } || echo 'ad-hoc（仅自测）')"
printf '  符号数   : %s %s(已 strip 应很少)%s\n' "$(nm -a "$BIN" 2>/dev/null | wc -l | tr -d ' ')" "$DIM" "$RST"
printf '  包内 dSYM: %s %s(应为 0)%s\n' "$(find "$APP" -name '*.dSYM' | wc -l | tr -d ' ')" "$DIM" "$RST"
printf '  编译警告 : %s\n' "$WARNS"
printf '  耗时     : %ss\n' "$ELAPSED"
printf '  输出目录 : %s\n' "${DIST#$ROOT/}/"
printf '%s✓ 完成%s\n' "$BOLD$GRN" "$RST"

# ── RELEASE（Developer ID 公证分发）──────────────────────────────────────────
# 签名 + 公证已在上方自动接入：钥匙串有 Developer ID Application 证书即正式签名，
# 配好 notarytool 凭证即自动公证 + 装订（App 与 DMG 各一次）。启用只需两步（各一次性）：
#
#   1) 创建证书：Xcode ▸ Settings ▸ Accounts ▸ 选团队 ▸ Manage Certificates
#      ▸ ＋ ▸ Developer ID Application（仅「账户持有人」可建；你是持有人）。
#
#   2) 存公证凭证（任选其一）：
#      a) App 专用密码（简单）：appleid.apple.com ▸ 登录与安全 ▸ App 专用密码，然后：
#         xcrun notarytool store-credentials $NOTARY_PROFILE \
#             --apple-id <你的AppleID> --team-id KTP97H9YFF --password <App专用密码>
#      b) App Store Connect API Key（更适合自动化）：用 --key/--key-id/--issuer 存。
#
# 之后照常运行本脚本即可产出「Developer ID + 已公证」可分发 DMG；自定义凭证名：
#   NOTARY_PROFILE=my-profile ./scripts/package-app.sh
#
# 上架 Mac App Store 是另一套流程（Apple Distribution 证书 + -exportArchive App Store
# 方式 + Transporter 上传 + App Sandbox），不复用本直发脚本。
