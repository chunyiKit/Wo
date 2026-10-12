#!/usr/bin/env bash
# 部署脚本共用配置加载器。只 source 可信的本地 shell 配置。

wo_load_config() {
    local config_file="${WO_DEPLOY_CONFIG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env/deploy.env}"
    local key i
    local keys=(WO_SSH_HOST WO_SSH_USER WO_APP_DIR WO_API_BASE_URL WEB_BASE_URL WO_SERVER_IP WO_CA_CERT WO_CERT_DAYS WO_RELEASE_TOKEN_FILE UV_MIRROR)
    local override_keys=() override_values=()
    for key in "${keys[@]}"; do
        if [[ "${!key+x}" ]]; then
            override_keys+=("$key")
            override_values+=("${!key}")
        fi
    done

    if [[ -f "$config_file" ]]; then
        source "$config_file"
    elif [[ -n "${WO_DEPLOY_CONFIG_FILE:-}" ]]; then
        echo "部署配置文件不存在：$config_file" >&2
        return 1
    fi

    for ((i=0; i<${#override_keys[@]}; i++)); do
        printf -v "${override_keys[$i]}" '%s' "${override_values[$i]}"
    done
    # release.sh 会启动 publish-apk.sh，子进程需要继承本次配置。
    for key in "${keys[@]}"; do
        if [[ "${!key+x}" ]]; then export "$key"; fi
    done
}

wo_require_config() {
    local key
    for key in "$@"; do
        if [[ -z "${!key:-}" || "${!key}" == *example.com* ]]; then
            echo "请在 backend/deploy/env/deploy.env 中配置 ${key}（或设置 WO_DEPLOY_CONFIG_FILE / 对应环境变量）。" >&2
            return 1
        fi
    done
}
