#!/usr/bin/env bash
# 从本地 JSON 配置构建或运行 App；其余参数原样交给 Flutter。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
CONFIG_FILE="${WO_APP_CONFIG_FILE:-$REPO_ROOT/config/app.local.json}"

case "${1:-}" in
    run|build) ;;
    *) echo "用法：bash tool/flutter.sh run|build [Flutter 参数]" >&2; exit 2 ;;
esac

# 构建前校验，避免产生未配置服务地址的安装包。
python3 - "$CONFIG_FILE" <<'PY'
import json
import sys
from urllib.parse import urlsplit

try:
    with open(sys.argv[1], encoding="utf-8") as source:
        config = json.load(source)
    url = config.get("WO_API_BASE_URL", "")
    if not isinstance(url, str) or not url or url != url.strip():
        raise ValueError("WO_API_BASE_URL 必须为非空地址")
    parsed = urlsplit(url)
    if (parsed.scheme not in ("http", "https") or not parsed.hostname
            or parsed.username is not None or parsed.password is not None
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment
            or parsed.hostname.endswith(".example.com")):
        raise ValueError("WO_API_BASE_URL 必须是实际 API 根地址，不含路径、凭据或查询参数")
    parsed.port  # 检查端口格式。
except (OSError, ValueError, AttributeError) as error:
    sys.exit(f"App 配置错误：{error}。请复制 config/app.example.json 为 config/app.local.json 并填写地址。")
PY

exec flutter "$@" "--dart-define-from-file=$CONFIG_FILE"
