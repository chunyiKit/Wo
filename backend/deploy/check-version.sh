#!/usr/bin/env bash
# 从部署配置读取地址，查询当前线上版本。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
wo_load_config
wo_require_config WO_API_BASE_URL

if [[ -n "${WO_CA_CERT:-}" ]]; then
    TLS=(--cacert "$WO_CA_CERT")
else
    TLS=(-k)
fi
curl -fsS --connect-timeout 5 --max-time 15 "${TLS[@]}" "${WO_API_BASE_URL%/}/api/v1/app/version"
echo
