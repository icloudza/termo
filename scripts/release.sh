#!/bin/bash
#
# Termo 发版向导 —— 改版本号 + 提交 + 推送 + 打 tag，推 tag 后由 GitHub Actions 接管
# （构建 / Developer ID 签名 / 公证 / Sparkle appcast / 发布 Release）。本脚本不本地构建。
#
# 用法：
#   scripts/release.sh            交互发版（每步确认）
#   scripts/release.sh --dry-run  仅预览要执行的动作，不做任何改动
#
# 版本号唯一源为 Termo/Info.plist：
#   CFBundleShortVersionString  展示版本（如 0.9.2），给人看
#   CFBundleVersion             构建号（整数，如 28），Sparkle 据此判断「谁更新」，必须严格递增
#
# tag 名固定为 v<展示版本>；tag 注释即用户在「软件更新」弹窗中看到的更新日志。
#
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Termo/Info.plist"
DEFAULT_BRANCH="main"
DRY_RUN=0
case "${1:-}" in
    --dry-run|-n) DRY_RUN=1 ;;
    "")           ;;
    *)            echo "未知参数：$1（用法：release.sh [--dry-run]）" >&2; exit 2 ;;
esac

# ── 日志框架 ────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; RST=""
fi
section() { printf '\n%s━━ %s %s━━━━━━━━━━━━━━━━━━━━%s\n' "$BOLD$BLU" "$1" "$DIM" "$RST"; }
info()    { printf '    %s%s%s\n' "$DIM" "$1" "$RST"; }
ok()      { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
warn()    { printf '    %s⚠%s  %s\n' "$YLW" "$RST" "$1"; }
die()     { printf '\n%s✗ %s%s\n' "$BOLD$RED" "$1" "$RST" >&2; exit 1; }

trap 'die "第 $LINENO 行出错，已中止。已执行的步骤需手动检查（见上方输出）。"' ERR

# 执行一条命令：dry-run 下只打印；否则打印后执行。
run() {
    printf '    %s$ %s%s\n' "$DIM" "$*" "$RST"
    [ "$DRY_RUN" = 1 ] && return 0
    "$@"
}

# 询问确认；非 yes 即中止。dry-run 下自动通过并标注。
confirm() {
    if [ "$DRY_RUN" = 1 ]; then info "[dry-run] 将在此确认：$1"; return 0; fi
    local reply
    printf '%s%s%s [y/N] ' "$BOLD" "$1" "$RST"
    read -r reply
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) die "已取消。" ;; esac
}

# ── 预检 ────────────────────────────────────────────────────────────────────
section "预检"
[ "$DRY_RUN" = 1 ] && warn "DRY-RUN 模式：只打印，不改动任何文件、不提交、不推送。"
command -v git >/dev/null || die "未找到 git。"
[ -f "$PLIST" ] || die "未找到 $PLIST。"
cd "$ROOT"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "当前目录不是 git 仓库。"

CUR_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo '(detached)')"
CUR_MARKETING="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
CUR_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
info "分支：$CUR_BRANCH"
info "当前版本：$CUR_MARKETING（构建号 $CUR_BUILD）"

if [ "$CUR_BRANCH" != "$DEFAULT_BRANCH" ]; then
    warn "当前不在 $DEFAULT_BRANCH 分支。"
    confirm "仍在 $CUR_BRANCH 上发版？"
fi

# ── 输入新版本 ──────────────────────────────────────────────────────────────
section "新版本号"
info "语义参考：PATCH=修 bug，MINOR=加功能，MAJOR=破坏旧用法。"
printf '%s展示版本%s（当前 %s）：' "$BOLD" "$RST" "$CUR_MARKETING"
read -r NEW_MARKETING
[ -n "$NEW_MARKETING" ] || die "未输入版本号。"
echo "$NEW_MARKETING" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}$' \
    || die "版本号格式应为 X.Y / X.Y.Z / X.Y.Z.W（注：Mac App Store 仅接受最多三段），收到：$NEW_MARKETING"

SUGGEST_BUILD=$((CUR_BUILD + 1))
printf '%s构建号%s（必须 > %s，回车用建议值 %s）：' "$BOLD" "$RST" "$CUR_BUILD" "$SUGGEST_BUILD"
read -r NEW_BUILD
[ -n "$NEW_BUILD" ] || NEW_BUILD="$SUGGEST_BUILD"
echo "$NEW_BUILD" | grep -Eq '^[0-9]+$' || die "构建号须为整数，收到：$NEW_BUILD"
[ "$NEW_BUILD" -gt "$CUR_BUILD" ] || die "构建号 $NEW_BUILD 未大于当前 $CUR_BUILD，用户将收不到更新。"

TAG="v$NEW_MARKETING"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "本地已存在 tag $TAG。"
git ls-remote --tags origin "$TAG" 2>/dev/null | grep -q "$TAG" && die "远端已存在 tag $TAG。"
ok "目标版本：$NEW_MARKETING（构建号 $NEW_BUILD），tag $TAG"

# ── 输入发行说明 ────────────────────────────────────────────────────────────
section "发行说明（即用户更新弹窗中的内容）"
NOTES_FILE="$(mktemp -t termo-release-notes)"
trap 'rm -f "$NOTES_FILE"' EXIT
{
    echo ""
    echo "# 在上方逐行输入本次更新内容，每行一条，会显示在用户的「软件更新」弹窗。"
    echo "# 以 # 开头的行会被忽略；内容为空将中止发布。"
    echo "# 版本 $NEW_MARKETING（构建号 $NEW_BUILD）"
} > "$NOTES_FILE"

if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] 将打开 ${EDITOR:-vi} 让你编辑发行说明。"
    NOTES="（dry-run 占位发行说明）"
else
    "${EDITOR:-vi}" "$NOTES_FILE"
    NOTES="$(grep -v '^#' "$NOTES_FILE" | sed '/^[[:space:]]*$/d')"
    [ -n "$NOTES" ] || die "发行说明为空，已中止。"
fi
echo "$DIM------ 发行说明预览 ------$RST"
printf '%s\n' "$NOTES"
echo "$DIM-------------------------$RST"

# ── 总览确认 ────────────────────────────────────────────────────────────────
section "即将执行"
info "写入 Info.plist：$CUR_MARKETING/$CUR_BUILD  →  $NEW_MARKETING/$NEW_BUILD"
info "提交全部改动（git add -A）并推送到 $CUR_BRANCH"
info "打带注释 tag $TAG 并推送 → 触发 GitHub Actions 自动发版"
echo
git status --short || true
echo
confirm "确认开始？"

# ── 写版本号 ────────────────────────────────────────────────────────────────
section "写入版本号"
run /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_MARKETING" "$PLIST"
run /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"
ok "Info.plist 已更新。"

# ── 提交 ────────────────────────────────────────────────────────────────────
section "提交改动"
run git add -A
[ "$DRY_RUN" = 1 ] || git --no-pager diff --cached --stat
confirm "以上改动将以「release: $NEW_MARKETING」提交，继续？"
COMMIT_MSG="$(printf 'release: %s（构建号 %s）\n\n%s\n' "$NEW_MARKETING" "$NEW_BUILD" "$NOTES")"
run git commit -m "$COMMIT_MSG"
ok "已提交。"

# ── 推送提交 ────────────────────────────────────────────────────────────────
section "推送提交"
confirm "推送到 origin/$CUR_BRANCH？"
run git push origin "$CUR_BRANCH"
ok "提交已推送。"

# ── 打 tag 并推送（触发发版）────────────────────────────────────────────────
section "打 tag 并推送"
run git tag -a "$TAG" -F "$NOTES_FILE"
ok "已创建 tag $TAG。"
confirm "推送 tag $TAG？（这一步会触发 CI 正式发版）"
run git push origin "$TAG"
ok "tag 已推送，CI 即将开始。"

# ── 收尾提示 ────────────────────────────────────────────────────────────────
REPO_SLUG="$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')"
section "完成"
ok "发版已触发。请关注并核对："
info "Actions： https://github.com/$REPO_SLUG/actions"
info "Releases：https://github.com/$REPO_SLUG/releases"
info "appcast：https://icloudza.github.io/termo/appcast.xml （应出现 $NEW_MARKETING / 构建号 $NEW_BUILD）"
echo
info "若 CI 失败：用户无感（不会发布 Release/appcast）。修复后改用更高版本重发，"
info "或删除 tag 重来：git tag -d $TAG && git push origin :refs/tags/$TAG"
