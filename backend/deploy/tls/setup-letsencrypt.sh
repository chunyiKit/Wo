#!/usr/bin/env bash
# 为微信小程序签发域名证书（Let's Encrypt，HTTP-01 + webroot）。
#
# 为什么需要：微信小程序的合法域名必须是「已备案域名 + 受信任 CA 证书」。
# 现有 App 走的是裸 IP + 自签 CA（generate-certs.sh），小程序完全连不上，
# 所以这里单独给域名签一张公共证书 —— 两套并存，互不影响。
#
# 前置条件（缺一项都会失败）：
#   1. 域名已备案，且 A 记录指向 Wo 后端服务器（当前 122.51.81.235）
#   2. 服务器 80 端口对外可达（HTTP-01 验证需要；被封就改 DNS-01，见下）
#   3. nginx 已在跑，且 wo-backend.conf 的 :80 块带了 /.well-known/acme-challenge/
#      这个 location（已加，否则验证请求会被 301 到 https 而失败）
#
# 用法（在服务器上执行，或 ssh 过去跑）：
#   sudo bash backend/deploy/tls/setup-letsencrypt.sh
#
# 证书 90 天过期。certbot 装好后会自动加 systemd timer / cron 续期；
# 续期同样走 HTTP-01，所以 :80 的 ACME location 不能删。

set -euo pipefail

DOMAIN="${WO_DOMAIN:-wo.chunyi-work.online}"
# 与服务器上已有 webroot 保持一致（trek 站点也用它），续期脚本共用一份。
WEBROOT="${WO_WEBROOT:-/var/www/letsencrypt}"
EMAIL="${WO_LETSENCRYPT_EMAIL:-}"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

if [[ "$(id -u)" -ne 0 ]]; then
    echo "请以 root 运行：sudo bash $0" >&2
    exit 1
fi

log "检查域名解析是否指向本机"
SERVER_IP="$(curl -sS https://api.ipify.org || true)"
DOMAIN_IP="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
echo "  域名解析到：${DOMAIN_IP:-（解析失败）}"
echo "  本机公网 IP：${SERVER_IP:-（获取失败）}"
if [[ -n "$DOMAIN_IP" && -n "$SERVER_IP" && "$DOMAIN_IP" != "$SERVER_IP" ]]; then
    echo
    echo "⚠️  域名没有解析到本机。Let's Encrypt 会连 $DOMAIN_IP 做验证，"
    echo "    而请求不会到达这台机器，签发必然失败。请先改 A 记录并等生效。"
    read -r -p "仍要继续？(y/N) " yn
    [[ "$yn" == "y" || "$yn" == "Y" ]] || exit 1
fi

log "安装 certbot"
if ! command -v certbot >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq certbot
else
    echo "  已安装，跳过"
fi

log "准备 webroot：$WEBROOT"
mkdir -p "$WEBROOT/.well-known/acme-challenge"
# 让 nginx（www-data / nginx）读得到验证文件
chmod -R 0755 "$WEBROOT"

if [[ -f /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem ]]; then
    log "证书已存在，直接续期（renew 在未到期时会安全地跳过）"
    certbot renew --webroot -w "$WEBROOT" --quiet || true
else
    log "签发证书：$DOMAIN"
    CERTBOT_ARGS=(certonly --webroot -w "$WEBROOT" -d "$DOMAIN" --agree-tos --keep-until-expiring)
    if [[ -n "$EMAIL" ]]; then
        CERTBOT_ARGS+=(--email "$EMAIL")
    else
        # 不提供邮箱时用 --register-unsafely-without-email，避免交互式卡住
        CERTBOT_ARGS+=(--register-unsafely-without-email)
    fi
    certbot "${CERTBOT_ARGS[@]}"
fi

log "校验证书"
ls -l /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem
openssl x509 -in /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem -noout -subject -dates

log "启用域名 server 块"
if [[ -f /etc/nginx/sites-available/wo-backend-domain ]]; then
    echo "  /etc/nginx/sites-available/wo-backend-domain 已存在"
else
    echo "  请把 backend/deploy/nginx/wo-backend-domain.conf 放到"
    echo "  /etc/nginx/sites-available/wo-backend-domain 后继续执行 nginx -t"
fi

log "完成。接下来："
cat <<EOF
  1. 确认 snippets 已就位：
       cp backend/deploy/nginx/snippets/wo-backend-locations.conf /etc/nginx/snippets/
  2. 确认域名 server 块已就位（放 sites-enabled，不能放 conf.d —— 详见该文件注释）：
       cp backend/deploy/nginx/wo-backend-domain.conf \\
          /etc/nginx/sites-available/wo-backend-domain
       ln -sf /etc/nginx/sites-available/wo-backend-domain \\
          /etc/nginx/sites-enabled/wo-backend-domain
  3. nginx -t && systemctl reload nginx
  4. 从外网验证（必须是受信任证书，不带 --cacert）：
       curl -sS https://${DOMAIN}/api/v1/health
  5. 微信小程序后台把 ${DOMAIN} 加进 request / uploadFile / downloadFile
     三类合法域名白名单
EOF
