#!/usr/bin/env bash
# 一键发布：从 CHANGELOG.md 读版本与更新说明，读发布密钥，调用 publish-apk.sh
# 把最新 APK 发布到后端。
#
# 流程：
#   1. 解析 CHANGELOG.md 顶部第一个 `## x.y.z+N` 条目 → 版本名/versionCode/更新说明。
#   2. 校验该版本与 pubspec.yaml 的 version 一致（防止 APK 内版本与发布信息对不上）。
#   3. 读取发布密钥文件（默认 /Users/chunyi/wo_release_token.txt）。
#   4. 拼接并调用 backend/deploy/publish-apk.sh。
#   5. 回传发布状态。
#
# 用法：
#   bash backend/deploy/release.sh                 # 发布
#   bash backend/deploy/release.sh --dry-run       # 只打印将执行的命令，不发布
#   bash backend/deploy/release.sh --apk path.apk  # 指定 APK 路径
#
# 可选环境变量（透传给 publish-apk.sh）：
#   WO_API_BASE_URL  后端地址（默认 https://122.51.81.235）
#   WO_CA_CERT       自签 CA 证书路径
#   WO_RELEASE_TOKEN_FILE  发布密钥文件路径（默认见下方 TOKEN_FILE）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CHANGELOG="$REPO_ROOT/CHANGELOG.md"
PUBSPEC="$REPO_ROOT/pubspec.yaml"
TOKEN_FILE="${WO_RELEASE_TOKEN_FILE:-/Users/chunyi/wo_release_token.txt}"
APK="${WO_APK:-$REPO_ROOT/build/app/outputs/flutter-apk/app-release.apk}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --apk)       APK="$2"; shift 2 ;;
        --changelog) CHANGELOG="$2"; shift 2 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

die() { echo "错误：$*" >&2; exit 1; }

# ---- 1. 解析 CHANGELOG 顶部条目 --------------------------------------------
[[ -f "$CHANGELOG" ]] || die "找不到更新日志：$CHANGELOG"

version_line="$(grep -m1 '^## ' "$CHANGELOG" || true)"
[[ -n "$version_line" ]] || die "$CHANGELOG 里没有任何 '## 版本号' 条目"

# "## 0.2.0+2 (可选备注)" → 取第一个空白分隔的 token 作为版本号
VERSION="$(echo "${version_line#\#\# }" | awk '{print $1}')"
[[ "$VERSION" == *+* ]] || die "版本号格式应为 x.y.z+N，实际为：'$VERSION'"

NAME="${VERSION%%+*}"   # 0.2.0
CODE="${VERSION##*+}"   # 2

[[ "$NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本名格式非法：'$NAME'（应为 x.y.z）"
[[ "$CODE" =~ ^[0-9]+$ ]] || die "versionCode 非法：'$CODE'（应为正整数）"

# 顶部条目标题之后、下一个 '## ' 之前的所有行即本次更新说明（去掉首尾空行）。
NOTES="$(awk '
    /^## /{c++; next}
    c==1{lines[n++]=$0}
    c>=2{exit}
    END{
        s=0; while(s<n && lines[s] ~ /^[[:space:]]*$/) s++;
        e=n-1; while(e>=s && lines[e] ~ /^[[:space:]]*$/) e--;
        for(i=s;i<=e;i++) print lines[i];
    }' "$CHANGELOG")"

# ---- 2. 校验与 pubspec 一致 -------------------------------------------------
if [[ -f "$PUBSPEC" ]]; then
    PUBSPEC_VERSION="$(grep -m1 '^version:' "$PUBSPEC" | awk '{print $2}')"
    [[ "$PUBSPEC_VERSION" == "$VERSION" ]] || die \
        "CHANGELOG 顶部版本 ($VERSION) 与 pubspec.yaml version ($PUBSPEC_VERSION) 不一致；
   请先对齐两边版本号，并用该版本构建 APK，再发布。"
fi

# ---- 3. 读取发布密钥 --------------------------------------------------------
[[ -f "$TOKEN_FILE" ]] || die "找不到发布密钥文件：$TOKEN_FILE"
TOKEN="$(tr -d ' \t\r\n' < "$TOKEN_FILE")"
[[ -n "$TOKEN" ]] || die "发布密钥文件为空：$TOKEN_FILE"

# ---- 4. 检查 APK 并拼接发布命令 --------------------------------------------
if [[ ! -f "$APK" && "$DRY_RUN" == "false" ]]; then
    die "找不到 APK：$APK
   请先执行：flutter build apk --release（或用 --apk 指定路径）"
fi

echo "==> 准备发布"
echo "    版本名 (name) : $NAME"
echo "    版本号 (code) : $CODE"
echo "    APK           : $APK"
echo "    后端          : ${WO_API_BASE_URL:-https://122.51.81.235}"
echo "    更新说明："
echo "$NOTES" | sed 's/^/      /'

if [[ "$DRY_RUN" == "true" ]]; then
    echo
    echo "==> --dry-run：将执行（密钥已隐藏）"
    echo "    WO_RELEASE_TOKEN=*** bash $SCRIPT_DIR/publish-apk.sh \\"
    echo "        --apk \"$APK\" --name \"$NAME\" --code \"$CODE\" --notes \"<更新说明>\""
    exit 0
fi

# ---- 5. 执行发布并回传状态 --------------------------------------------------
echo
set +e
WO_RELEASE_TOKEN="$TOKEN" bash "$SCRIPT_DIR/publish-apk.sh" \
    --apk "$APK" \
    --name "$NAME" \
    --code "$CODE" \
    --notes "$NOTES"
status=$?
set -e

echo
if [[ $status -eq 0 ]]; then
    echo "==> 发布成功 🎉（版本 $VERSION 已上线）"
else
    echo "==> 发布失败（退出码 $status）；请检查上方输出。" >&2
fi
exit $status
