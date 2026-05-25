#!/usr/bin/env bash
# Upload the server cert + key to the box and place them at /etc/wo/tls/.
# Run on your laptop AFTER generate-certs.sh. The CA key never leaves your
# machine — only the leaf cert + its key go to the server.
#
# Config (same env vars as deploy.sh):
#   WO_SSH_HOST  default 122.51.81.235
#   WO_SSH_USER  default ubuntu

set -euo pipefail

WO_SSH_HOST="${WO_SSH_HOST:-122.51.81.235}"
WO_SSH_USER="${WO_SSH_USER:-ubuntu}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"

if [[ ! -f "$OUT_DIR/server.crt" || ! -f "$OUT_DIR/server.key" ]]; then
    echo "Missing $OUT_DIR/server.crt or server.key — run generate-certs.sh first." >&2
    exit 1
fi

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# Stage in a temp dir we can scp into without sudo, then move into place.
STAGING="/tmp/wo-tls-deploy.$$"

log "Uploading server cert + key → $WO_SSH_USER@$WO_SSH_HOST"
ssh "$WO_SSH_USER@$WO_SSH_HOST" "mkdir -p $STAGING"
scp "$OUT_DIR/server.crt" "$OUT_DIR/server.key" \
    "$WO_SSH_USER@$WO_SSH_HOST:$STAGING/"

log "Placing certs at /etc/wo/tls and reloading nginx"
ssh "$WO_SSH_USER@$WO_SSH_HOST" "STAGING=$STAGING bash -s" <<'REMOTE'
set -euo pipefail
sudo mkdir -p /etc/wo/tls
sudo mv "$STAGING/server.crt" /etc/wo/tls/server.crt
sudo mv "$STAGING/server.key" /etc/wo/tls/server.key
# Cert is public (0644); key is secret. nginx master runs as root so root-only
# read on the key is fine and keeps it away from everyone else.
sudo chown root:root /etc/wo/tls/server.crt /etc/wo/tls/server.key
sudo chmod 0644 /etc/wo/tls/server.crt
sudo chmod 0600 /etc/wo/tls/server.key
rm -rf "$STAGING"
# Validate config before reload so a bad cert path can't take nginx down.
sudo nginx -t
sudo systemctl reload nginx
REMOTE

log "Done. Test from your laptop:"
echo "  curl --cacert $OUT_DIR/ca.crt https://$WO_SSH_HOST/api/v1/health"
