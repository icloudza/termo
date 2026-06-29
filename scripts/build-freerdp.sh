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
OPENSSL_TAG="${OPENSSL_TAG:-openssl-3.5.0}"  # 从源码静态编 OpenSSL（带 legacy provider，供 NTLM 的 MD4/RC4）
ARCH="arm64"
DEPLOY="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.freerdp-build"                   # 中间产物（gitignore）
SRC="$WORK/FreeRDP"
BUILD="$WORK/build"
STAGE="$WORK/stage"                           # cmake --install 输出
OSSL_SRC="$WORK/openssl"                       # OpenSSL 源码与构建树（静态 legacy provider 在其 providers/ 下）
OSSL_PREFIX="$WORK/openssl-install"            # OpenSSL install_sw 输出（libcrypto/libssl + headers）
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
command -v perl  >/dev/null || die "未装 perl（OpenSSL 配置需要；macOS 自带）"
# create-xcframework 需完整 Xcode。若 xcode-select 指向 CommandLineTools 导致 xcodebuild 不可用，
# 本次运行临时改用 /Applications/Xcode.app（DEVELOPER_DIR 对子进程生效，无需 sudo 改全局）。
if ! xcodebuild -version >/dev/null 2>&1; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
        warn "xcode-select 指向 CommandLineTools，本次临时改用 /Applications/Xcode.app"
    else
        die "create-xcframework 需要完整 Xcode：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    fi
fi
ok "cmake：$(cmake --version | head -1)"
info "FreeRDP 版本：${FREERDP_TAG}（可用 FREERDP_TAG=… 覆盖）"
info "OpenSSL 版本：${OPENSSL_TAG}（可用 OPENSSL_TAG=… 覆盖）"
info "日志：$LOG"

# ── 构建 OpenSSL（静态 / arm64 / 含 legacy provider）─────────────────────────
# 自源码静态编 OpenSSL，目的是拿到「静态 legacy provider」providers/liblegacy.a —— 它提供 NTLM
# 必需的 MD4/RC4/DES。Homebrew 的 openssl@3 只给动态 legacy.dylib（与本工程静态 libcrypto 不兼容、
# 且 App 不便 dlopen），故必须自编静态版。下游 FreeRDP cmake 与合库统一用 $OPENSSL_PREFIX。
section "构建 OpenSSL（静态 + legacy provider）"
OPENSSL_PREFIX="$OSSL_PREFIX"
LEGACY_A="$OSSL_SRC/providers/liblegacy.a"
if [ -f "$OPENSSL_PREFIX/lib/libcrypto.a" ] && [ -f "$LEGACY_A" ]; then
    ok "复用已构建的 OpenSSL：${OSSL_PREFIX#$ROOT/}"
else
    if [ -d "$OSSL_SRC/.git" ]; then
        step "复用并切到 ${OPENSSL_TAG}…"
        run_quiet git -C "$OSSL_SRC" fetch --tags --depth 1 origin "tags/$OPENSSL_TAG"
        run_quiet git -C "$OSSL_SRC" checkout -f "$OPENSSL_TAG"
    else
        step "浅克隆 OpenSSL @${OPENSSL_TAG}…"
        run_quiet git clone --depth 1 --branch "$OPENSSL_TAG" https://github.com/openssl/openssl.git "$OSSL_SRC"
    fi
    # no-shared 静态构建：legacy provider 产出为 providers/liblegacy.a（不随 install_sw 安装，构建树里取）。
    # 保留 legacy（默认即编）；no-apps/no-tests/no-docs 仅为加速，不影响库本身。
    step "Configure（darwin64-arm64 / no-shared）…"
    ( cd "$OSSL_SRC" && run_quiet ./Configure darwin64-arm64-cc \
        no-shared no-tests no-apps no-docs \
        --prefix="$OPENSSL_PREFIX" \
        -mmacosx-version-min="$DEPLOY" ) || die "OpenSSL Configure 失败（详见 ${LOG}）"
    step "make（并行）+ install_sw…"
    run_quiet make -C "$OSSL_SRC" -j"$(sysctl -n hw.ncpu)"
    run_quiet make -C "$OSSL_SRC" install_sw
    [ -f "$LEGACY_A" ] || die "未生成静态 legacy provider：${LEGACY_A#$ROOT/}（OpenSSL 版本/构建方式或有变）"
    ok "OpenSSL 就绪：libcrypto.a / libssl.a / liblegacy.a"
fi
info "legacy provider：${LEGACY_A#$ROOT/}"

# legacy provider 的入口 ossl_legacy_provider_init 不在 liblegacy.a 里：no-shared 构建只把算法实现
# （md4/rc4/des…）打进 liblegacy.a，入口 legacyprov.c 仅用于可加载模块、未编入静态档。
# 用 -DSTATIC_LEGACY 单独编它：该宏把标准模块入口 OSSL_provider_init 改名为 ossl_legacy_provider_init，
# 正是 C 桥 OSSL_PROVIDER_add_builtin 引用、链接器要找的符号。产物 .o 随后一并合入静态库。
LEGACYPROV_O="$WORK/legacyprov.o"
step "编译 legacy provider 入口（-DSTATIC_LEGACY）…"
( cd "$OSSL_SRC" && cc -arch "$ARCH" -mmacosx-version-min="$DEPLOY" -DSTATIC_LEGACY \
    -Iinclude -Iproviders/implementations/include -Iproviders/common/include -I. \
    -c providers/legacyprov.c -o "$LEGACYPROV_O" ) >>"$LOG" 2>&1 \
    || die "编译 legacyprov.c 失败（详见 ${LOG}）"
nm "$LEGACYPROV_O" 2>/dev/null | grep -q "ossl_legacy_provider_init" \
    || die "legacyprov.o 未导出 ossl_legacy_provider_init（STATIC_LEGACY 宏或源码布局或有变）"
ok "legacy 入口就绪：ossl_legacy_provider_init"

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
    -DCHANNEL_RDPSND=OFF \
    -DCHANNEL_AUDIN=OFF \
    -DCHANNEL_RDPECAM=OFF \
    -DCHANNEL_URBDRC=OFF \
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
# legacy provider 的算法档(liblegacy.a)与入口(legacyprov.o)都必须合入，否则
# ossl_legacy_provider_init 未定义、NTLM 仍缺 MD4。libtool -static 接受 .a 与 .o 混合输入。
LIBS+=("$OPENSSL_PREFIX/lib/libssl.a" "$OPENSSL_PREFIX/lib/libcrypto.a" "$LEGACY_A" "$LEGACYPROV_O")
for l in "${LIBS[@]}"; do info "$(basename "$l")"; done
MERGED="$WORK/libCFreeRDP.a"; rm -f "$MERGED"
libtool -static -o "$MERGED" "${LIBS[@]}" >>"$LOG" 2>&1 || die "libtool 合并失败（详见 ${LOG}）"
ok "合并 → $(du -h "$MERGED" | cut -f1) libCFreeRDP.a"

# ── 组装 xcframework ────────────────────────────────────────────────────────
section "组装 xcframework"
step "整理头文件…"
HDR="$WORK/headers"; rm -rf "$HDR"; mkdir -p "$HDR"
cp -R "$STAGE/include/." "$HDR/"            # freerdp3/、winpr3/ 等版本化 include 目录
cp -R "$OPENSSL_PREFIX/include/." "$HDR/"   # openssl/ —— 供 C 桥 #include <openssl/provider.h> 注册 legacy
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
