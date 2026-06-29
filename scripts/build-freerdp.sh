#!/bin/bash
#
# 构建 FreeRDP 静态 xcframework，供 Termo 内嵌（RDP 模块阶段 B）。
#
#   产物 : Vendor/CFreeRDP.xcframework（合并后的单一静态库 + 头文件）
#   架构 : arm64（与 App 一致，仅 Apple Silicon）
#   许可 : 关闭 FFmpeg/OpenH264/x264/swscale 等 LGPL/GPL/专利依赖，保持 Apache-2.0 + OpenSSL 干净可闭源内嵌
#
# 依赖（本机）：cmake、ninja(可选)、git、Homebrew 的 openssl@3（提供静态 libssl.a/libcrypto.a）
#   brew install cmake openssl@3
#
# 注：FreeRDP 的 CMake 选项随版本有出入；若失败多为某个 WITH_* 开关名变更，详见 .freerdp-build/cmake.log。
#
set -euo pipefail

# ── 配置 ────────────────────────────────────────────────────────────────────
FREERDP_TAG="${FREERDP_TAG:-3.9.0}"          # 可用 FREERDP_TAG=3.x.y 覆盖
ARCH="arm64"
DEPLOY="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.freerdp-build"                   # 中间产物（gitignore）
SRC="$WORK/FreeRDP"
BUILD="$WORK/build"
STAGE="$WORK/stage"                           # cmake --install 输出
OUT="$ROOT/Vendor/CFreeRDP.xcframework"
LOG="$WORK/cmake.log"

# ── 日志框架（对齐 package-app.sh 风格）──────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; RST=""; fi
STEP=0
section() { printf '\n%s━━ %s %s━━━━━━━━━━━━━━━━━━━━%s\n' "$BOLD$BLU" "$1" "$DIM" "$RST"; }
step()    { STEP=$((STEP+1)); printf '%s[%d]%s %s\n' "$BOLD" "$STEP" "$RST" "$1"; }
info()    { printf '    %s%s%s\n' "$DIM" "$1" "$RST"; }
ok()      { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
warn()    { printf '    %s⚠%s  %s\n' "$YLW" "$RST" "$1"; }
die()     { printf '\n%s✗ 失败：%s%s\n' "$BOLD$RED" "$1" "$RST" >&2; exit 1; }
run_quiet() { "$@" >>"$LOG" 2>&1; }

# 出错兜底：set -e 触发时打印行号与日志尾，避免静默退出（cmake --build 等无 || die 的命令失败时尤其需要）。
trap 'rc=$?; [ $rc -ne 0 ] && { printf "\n%s✗ 第 %s 行中止（退出码 %s）%s\n" "$BOLD$RED" "$LINENO" "$rc" "$RST" >&2;
      [ -f "$LOG" ] && { echo "—— cmake.log 末 30 行 ——" >&2; tail -30 "$LOG" >&2; }; }' ERR

mkdir -p "$WORK"; : > "$LOG"

# ── 预检 ────────────────────────────────────────────────────────────────────
section "预检"
command -v cmake >/dev/null || die "未装 cmake：brew install cmake"
command -v git   >/dev/null || die "未装 git"
OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
[ -n "$OPENSSL_PREFIX" ] && [ -f "$OPENSSL_PREFIX/lib/libssl.a" ] \
    || die "未找到 openssl@3 静态库：brew install openssl@3（需 $OPENSSL_PREFIX/lib/libssl.a）"
ok "cmake：$(cmake --version | head -1)"
ok "openssl@3：$OPENSSL_PREFIX"
info "FreeRDP 版本：${FREERDP_TAG}（可用 FREERDP_TAG=… 覆盖）"
info "日志：$LOG"

# ── 取源码 ──────────────────────────────────────────────────────────────────
section "获取 FreeRDP 源码"
if [ -d "$SRC/.git" ]; then
    step "复用并切到 tag ${FREERDP_TAG}…"
    run_quiet git -C "$SRC" fetch --tags --depth 1 origin "tags/$FREERDP_TAG"
    run_quiet git -C "$SRC" checkout -f "$FREERDP_TAG"
else
    step "浅克隆 FreeRDP @${FREERDP_TAG}…"
    run_quiet git clone --depth 1 --branch "$FREERDP_TAG" https://github.com/FreeRDP/FreeRDP.git "$SRC"
fi
ok "源码就绪：${SRC#$ROOT/}"

# ── CMake 配置 ──────────────────────────────────────────────────────────────
section "CMake 配置（静态 / arm64 / 去 GPL-LGPL 依赖）"
step "cmake configure…"
rm -rf "$BUILD" "$STAGE"
# 关键开关：
#  · BUILD_SHARED_LIBS=OFF        静态库
#  · WITH_SAMPLE/SERVER/CLIENT_*  关掉示例 App 与服务端（只要库）
#  · WITH_FFMPEG/SWSCALE/...=OFF  避开 LGPL/GPL/专利编解码，保持纯 Apache+OpenSSL
#  · WITH_X11/WAYLAND/SDL/MAC=OFF 不要任何平台 UI 客户端（渲染由 App 自研）
#  · 外设/音频/智能卡全关，先求最小可连通核心
run_quiet cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    -DCMAKE_C_FLAGS="-fno-lto" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
    -DCMAKE_INSTALL_PREFIX="$STAGE" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DWITH_SAMPLE=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_PLATFORM_SERVER=OFF \
    -DWITH_CLIENT=OFF \
    -DWITH_CLIENT_SDL=OFF \
    -DWITH_CLIENT_MAC=OFF \
    -DWITH_X11=OFF \
    -DWITH_WAYLAND=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_OPENH264=OFF \
    -DWITH_X264=OFF \
    -DWITH_OPUS=OFF \
    -DWITH_FAAD2=OFF \
    -DWITH_FAAC=OFF \
    -DWITH_SOXR=OFF \
    -DWITH_JSON_DISABLED=ON \
    -DWITH_AAD=OFF \
    -DWITH_WEBVIEW=OFF \
    -DWITH_KRB5=OFF \
    -DWITH_PCSC=OFF \
    -DWITH_CUPS=OFF \
    -DWITH_PULSE=OFF \
    -DWITH_ALSA=OFF \
    -DWITH_FUSE=OFF \
    -DWITH_LIBSYSTEMD=OFF \
    -DWITH_OPENSSL=ON \
    -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
    -DOPENSSL_USE_STATIC_LIBS=ON \
    || die "cmake 配置失败（详见 ${LOG}）；多为某个 WITH_* 选项名随版本变更。"
ok "配置完成"

# ── 编译 + 安装 ─────────────────────────────────────────────────────────────
section "编译"
step "cmake --build（并行）…"
run_quiet cmake --build "$BUILD" --parallel "$(sysctl -n hw.ncpu)"
run_quiet cmake --install "$BUILD"
ok "编译 + 安装完成 → ${STAGE#$ROOT/}"

# ── 合并静态库 ──────────────────────────────────────────────────────────────
section "合并静态库（FreeRDP + WinPR + OpenSSL → 单一 .a）"
step "收集 .a…"
LIBS=()
while IFS= read -r f; do LIBS+=("$f"); done < <(find "$STAGE" -name 'libfreerdp*.a' -o -name 'libwinpr*.a')
[ "${#LIBS[@]}" -gt 0 ] || die "未在 $STAGE 找到 FreeRDP/WinPR 静态库（检查上一步是否真产出 .a）"
LIBS+=("$OPENSSL_PREFIX/lib/libssl.a" "$OPENSSL_PREFIX/lib/libcrypto.a")
for l in "${LIBS[@]}"; do info "$(basename "$l")"; done
MERGED="$WORK/libCFreeRDP.a"; rm -f "$MERGED"
libtool -static -o "$MERGED" "${LIBS[@]}" >>"$LOG" 2>&1 || die "libtool 合并失败（详见 ${LOG}）"
ok "合并 → $(du -h "$MERGED" | cut -f1) libCFreeRDP.a"

# ── 组装 xcframework ────────────────────────────────────────────────────────
section "组装 xcframework"
step "整理头文件…"
HDR="$WORK/headers"; rm -rf "$HDR"; mkdir -p "$HDR"
cp -R "$STAGE/include/." "$HDR/"            # freerdp3/、winpr3/ 等版本化 include 目录
# 不放 module.modulemap：ObjC 桥经工程 HEADER_SEARCH_PATHS（指到 freerdp3/winpr3）直接 #import <freerdp/...>，
# 静态库按符号链接。放空 modulemap 反而会让 Xcode 误建空 Clang 模块、引发告警/干扰。
step "xcodebuild -create-xcframework…"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
    -library "$MERGED" -headers "$HDR" \
    -output "$OUT" >>"$LOG" 2>&1 || die "create-xcframework 失败（详见 ${LOG}）"
ok "xcframework → ${OUT#$ROOT/}"

# ── 验收 ────────────────────────────────────────────────────────────────────
section "验收"
LIBIN="$(find "$OUT" -name '*.a' | head -1)"
info "架构：$(lipo -archs "$LIBIN" 2>/dev/null)"
info "含 freerdp_new 符号：$(nm "$LIBIN" 2>/dev/null | grep -c 'freerdp_new' || echo 0)（应 ≥1）"
printf '%s✓ 完成%s  产物：%s\n' "$BOLD$GRN" "$RST" "${OUT#$ROOT/}"
