#!/bin/bash
#
# 构建 libssh2 静态 xcframework，供 Termo 内嵌的进程内 SSH 引擎（SSH 迁移阶段 J1）。
#
#   产物 : Vendor/CSSH2.xcframework（仅 libssh2.a + 头文件）
#   架构 : arm64（与 App 一致）
#   许可 : libssh2 = BSD-3-Clause，可闭源静态内嵌。
#
# 关键设计：xcframework 里**只打包 libssh2.a，不合并 OpenSSL**。
#   App 已链接 CFreeRDP.xcframework（内含静态 OpenSSL）；若本包再合并一份 OpenSSL，最终链接会
#   libcrypto/libssl 符号重复 → 冲突。故 libssh2 仅编译/链接时指向同一份静态 OpenSSL（解析头与配置），
#   产物 .a 里保留对 OpenSSL 的未定义外部符号，App 最终链接时由 CFreeRDP 的 OpenSSL 解析。
#   两者必须用**同一份 OpenSSL**（同版本/同 ABI），故默认复用 .freerdp-build 那份。
#
# 依赖（本机）：cmake、git、完整 Xcode。OpenSSL 复用 build-freerdp.sh 产出的静态库
#   （.freerdp-build/openssl-install）；若不存在则本脚本就地自编一份（no-shared）。
#
set -euo pipefail

# ── 配置 ────────────────────────────────────────────────────────────────────
LIBSSH2_TAG="${LIBSSH2_TAG:-libssh2-1.11.1}"   # 可用 LIBSSH2_TAG=… 覆盖
OPENSSL_TAG="${OPENSSL_TAG:-openssl-3.5.0}"    # 仅当需就地自编 OpenSSL 时用（应与 FreeRDP 那份一致）
ARCH="arm64"
DEPLOY="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.libssh2-build"                    # 中间产物（gitignore）
SRC="$WORK/libssh2"
BUILD="$WORK/build"
STAGE="$WORK/stage"                            # cmake --install 输出
OUT="$ROOT/Vendor/CSSH2.xcframework"
LOG="$WORK/cmake.log"

# 复用 FreeRDP 那份静态 OpenSSL（同一 ABI，避免两份 OpenSSL）。不存在则本脚本就地自编到此目录。
OPENSSL_PREFIX="${OPENSSL_PREFIX:-$ROOT/.freerdp-build/openssl-install}"
OSSL_SELF="$WORK/openssl"                       # 就地自编时的源码树
OSSL_SELF_PREFIX="$WORK/openssl-install"        # 就地自编时的 install 输出

# ── 日志框架（对齐 build-freerdp.sh）────────────────────────────────────────
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

trap 'rc=$?; [ $rc -ne 0 ] && { printf "\n%s✗ 第 %s 行中止（退出码 %s）%s\n" "$BOLD$RED" "$LINENO" "$rc" "$RST" >&2;
      [ -f "$LOG" ] && { echo "—— cmake.log 末 30 行 ——" >&2; tail -30 "$LOG" >&2; }; }' ERR

mkdir -p "$WORK"; : > "$LOG"

# ── 预检 ────────────────────────────────────────────────────────────────────
section "预检"
command -v cmake >/dev/null || die "未装 cmake：brew install cmake"
command -v git   >/dev/null || die "未装 git"
if ! xcodebuild -version >/dev/null 2>&1; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
        warn "xcode-select 指向 CommandLineTools，本次临时改用 /Applications/Xcode.app"
    else
        die "create-xcframework 需要完整 Xcode：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    fi
fi
ok "cmake：$(cmake --version | head -1)"
info "libssh2 版本：${LIBSSH2_TAG}（可用 LIBSSH2_TAG=… 覆盖）"
info "日志：$LOG"

# ── OpenSSL（复用 FreeRDP 那份；缺失则就地自编）──────────────────────────────
section "定位静态 OpenSSL"
if [ -f "$OPENSSL_PREFIX/lib/libcrypto.a" ]; then
    ok "复用 FreeRDP 的静态 OpenSSL：${OPENSSL_PREFIX#$ROOT/}"
else
    warn "未找到 ${OPENSSL_PREFIX#$ROOT/}/lib/libcrypto.a —— 就地自编一份（建议先跑 build-freerdp.sh 以共用同一份）"
    command -v perl >/dev/null || die "未装 perl（OpenSSL 配置需要；macOS 自带）"
    OPENSSL_PREFIX="$OSSL_SELF_PREFIX"
    if [ -f "$OPENSSL_PREFIX/lib/libcrypto.a" ]; then
        ok "复用本脚本上次自编的 OpenSSL"
    else
        if [ -d "$OSSL_SELF/.git" ]; then
            run_quiet git -C "$OSSL_SELF" fetch --tags --depth 1 origin "tags/$OPENSSL_TAG"
            run_quiet git -C "$OSSL_SELF" checkout -f "$OPENSSL_TAG"
        else
            step "浅克隆 OpenSSL @${OPENSSL_TAG}…"
            run_quiet git clone --depth 1 --branch "$OPENSSL_TAG" https://github.com/openssl/openssl.git "$OSSL_SELF"
        fi
        step "Configure + make（darwin64-arm64 / no-shared）…"
        ( cd "$OSSL_SELF" && run_quiet ./Configure darwin64-arm64-cc \
            no-shared no-tests no-apps no-docs \
            --prefix="$OPENSSL_PREFIX" -mmacosx-version-min="$DEPLOY" ) || die "OpenSSL Configure 失败（详见 ${LOG}）"
        run_quiet make -C "$OSSL_SELF" -j"$(sysctl -n hw.ncpu)"
        run_quiet make -C "$OSSL_SELF" install_sw
        ok "OpenSSL 就绪（自编）"
    fi
fi

# ── 取源码 ──────────────────────────────────────────────────────────────────
section "获取 libssh2 源码"
if [ -d "$SRC/.git" ]; then
    step "复用并切到 tag ${LIBSSH2_TAG}…"
    run_quiet git -C "$SRC" fetch --tags --depth 1 origin "tags/$LIBSSH2_TAG"
    run_quiet git -C "$SRC" checkout -f "$LIBSSH2_TAG"
else
    step "浅克隆 libssh2 @${LIBSSH2_TAG}…"
    run_quiet git clone --depth 1 --branch "$LIBSSH2_TAG" https://github.com/libssh2/libssh2.git "$SRC"
fi
ok "源码就绪：${SRC#$ROOT/}"

# ── 安全补丁：CVE-2026-55200（CVSS 9.2，有公开 PoC）─────────────────────────
# ssh2_transport_read() 在“无需解密即可取包长”分支只校验 packet_length 下界、漏了上界，
# 随后 total_num += packet_length → 整数溢出到堆越界写，恶意/被劫持的服务器可 RCE 到客户端。
# 1.11.1 另一分支已有该上界检查，此处回填官方 PR #2052（+5/-1，仅 transport.c）。
# 上游尚无含修复的 release，故对固定 tag 就地打补丁；每次构建重新 checkout，补丁在此幂等重打。
section "应用安全补丁 CVE-2026-55200"
TP="$SRC/src/transport.c"
[ -f "$TP" ] || die "未找到 $TP"
# 非破坏性校验：无花括号的脆弱分支应恰好出现 1 处（已修复分支写作 “< 1) {”，不匹配）
VULN=$(perl -0777 -ne 'print scalar(() = /if\(p->packet_length < 1\)\n\s+return LIBSSH2_ERROR_DECRYPT;/g)' "$TP")
if [ "$VULN" = "1" ]; then
    perl -0777 -i -pe 's{if\(p->packet_length < 1\)\n(\s+)return LIBSSH2_ERROR_DECRYPT;}{if(p->packet_length < 1) {\n$1    return LIBSSH2_ERROR_DECRYPT;\n$1}\n$1else if(p->packet_length > LIBSSH2_PACKET_MAXPAYLOAD) {\n$1    return LIBSSH2_ERROR_OUT_OF_BOUNDARY;\n$1}}g' "$TP"
    PC=$(grep -c "packet_length > LIBSSH2_PACKET_MAXPAYLOAD" "$TP")
    [ "$PC" -ge 2 ] || die "CVE-2026-55200 补丁复核失败（MAXPAYLOAD 上界检查=$PC，期望 ≥2）"
    ok "已应用 CVE-2026-55200 补丁（transport.c 补上界检查，现有 $PC 处 MAXPAYLOAD 边界返回）"
elif [ "$VULN" = "0" ] && grep -q "packet_length > LIBSSH2_PACKET_MAXPAYLOAD" "$TP"; then
    warn "未发现脆弱分支且已存在上界检查 —— 视为已含修复的版本，跳过打补丁"
else
    die "CVE-2026-55200：目标代码不匹配（脆弱分支计数=$VULN）；libssh2 版本可能已变，请人工核对 transport.c"
fi

# ── CMake 配置（静态 / arm64 / OpenSSL 后端）────────────────────────────────
section "CMake 配置（静态 / OpenSSL backend）"
step "cmake configure…"
rm -rf "$BUILD" "$STAGE"
# 关键开关：
#  · BUILD_SHARED_LIBS=OFF       静态库
#  · CRYPTO_BACKEND=OpenSSL      用 OpenSSL 做加密后端（复用同一份静态 OpenSSL）
#  · OPENSSL_USE_STATIC_LIBS=ON  链接静态 libcrypto/libssl（仅编译期解析；产物不合并，见文件头说明）
#  · ENABLE_ZLIB_COMPRESSION=ON  SSH 压缩（系统 zlib，App 已 -lz）
#  · LTO off                     与 FreeRDP 同：避免 bitcode 让 create-xcframework 报 Unknown header
run_quiet cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    -DCMAKE_C_FLAGS="-fno-lto" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
    -DCMAKE_INSTALL_PREFIX="$STAGE" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DLIBSSH2_NO_DEPRECATED=ON \
    -DENABLE_ZLIB_COMPRESSION=ON \
    -DCRYPTO_BACKEND=OpenSSL \
    -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
    -DOPENSSL_USE_STATIC_LIBS=ON \
    || die "cmake 配置失败（详见 ${LOG}）；多为 CRYPTO_BACKEND/OPENSSL_ROOT_DIR 或选项名随版本变更。"
ok "配置完成"

# ── 编译 + 安装 ─────────────────────────────────────────────────────────────
section "编译"
step "cmake --build（并行）…"
run_quiet cmake --build "$BUILD" --parallel "$(sysctl -n hw.ncpu)"
run_quiet cmake --install "$BUILD"
LIBA="$(find "$STAGE" -name 'libssh2.a' | head -1)"
[ -n "$LIBA" ] || die "未在 $STAGE 找到 libssh2.a（检查编译是否真产出静态库）"
ok "编译完成 → ${LIBA#$ROOT/}"

# ── 组装 xcframework（仅 libssh2.a + 头，不含 OpenSSL）──────────────────────
section "组装 xcframework"
step "整理头文件…"
HDR="$WORK/headers"; rm -rf "$HDR"; mkdir -p "$HDR"
cp -R "$STAGE/include/." "$HDR/"   # libssh2.h / libssh2_sftp.h / libssh2_publickey.h
step "xcodebuild -create-xcframework…"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
    -library "$LIBA" -headers "$HDR" \
    -output "$OUT" >>"$LOG" 2>&1 || die "create-xcframework 失败（详见 ${LOG}）"
ok "xcframework → ${OUT#$ROOT/}"

# ── 验收 ────────────────────────────────────────────────────────────────────
section "验收"
LIBIN="$(find "$OUT" -name '*.a' | head -1)"
info "架构：$(lipo -archs "$LIBIN" 2>/dev/null)"
info "含 libssh2_init 符号：$(nm "$LIBIN" 2>/dev/null | grep -c 'libssh2_init' || echo 0)（应 ≥1）"
info "对 OpenSSL 的未定义引用（应有，待 App 链接时由 CFreeRDP 解析）：$(nm -u "$LIBIN" 2>/dev/null | grep -c 'EVP_\|SSL_' || echo 0)"
printf '%s✓ 完成%s  产物：%s\n' "$BOLD$GRN" "$RST" "${OUT#$ROOT/}"
