#!/usr/bin/env bash
# Per-deploy script. Run on your laptop.
#
# Pipeline:
#   1. Sanity: tests must pass locally (you can skip with --skip-tests).
#   2. rsync code into /opt/wo-backend on the server.
#   3. SSH in, run `uv sync`, `alembic upgrade head`, restart systemd.
#   4. Healthcheck via curl.
#
# Configurable via env vars:
#   WO_SSH_HOST   default 122.51.81.235
#   WO_SSH_USER   default ubuntu
#   WO_APP_DIR    default /opt/wo-backend
#   UV_MIRROR     default https://mirrors.cloud.tencent.com/pypi/simple/
#
# Override at the call site, e.g.: WO_SSH_USER=root bash deploy.sh
#                              or: UV_MIRROR=https://pypi.org/simple bash deploy.sh

set -euo pipefail

WO_SSH_HOST="${WO_SSH_HOST:-122.51.81.235}"
WO_SSH_USER="${WO_SSH_USER:-ubuntu}"
WO_APP_DIR="${WO_APP_DIR:-/opt/wo-backend}"
# The server lives on Tencent Cloud, so its PyPI mirror is same-vendor (often
# intranet) and avoids public-egress charges. Override for a different mirror.
UV_MIRROR="${UV_MIRROR:-https://mirrors.cloud.tencent.com/pypi/simple/}"

SKIP_TESTS=false
for arg in "$@"; do
    case "$arg" in
        --skip-tests) SKIP_TESTS=true ;;
        *) echo "unknown flag: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

# ---- 1. Run tests locally ---------------------------------------------------
if [[ "$SKIP_TESTS" == "false" ]]; then
    log "Running tests locally (use --skip-tests to bypass)"
    (cd "$BACKEND_DIR" && uv run pytest -q)
fi

# ---- 2. Rsync code ----------------------------------------------------------
log "rsync → $WO_SSH_USER@$WO_SSH_HOST:$WO_APP_DIR"
# We sync into a staging dir first so the unit doesn't see a half-written tree.
# Then on the server we atomically swap with rsync --delete from staging.
STAGING="/tmp/wo-backend-deploy.$$"

rsync -avz --delete \
    --exclude '.venv' \
    --exclude '__pycache__' \
    --exclude '.pytest_cache' \
    --exclude '.ruff_cache' \
    --exclude '.mypy_cache' \
    --exclude 'storage' \
    --exclude '.env' \
    --exclude '.env.example' \
    --exclude '*.pyc' \
    "$BACKEND_DIR/" "$WO_SSH_USER@$WO_SSH_HOST:$STAGING/"

# ---- 3. Remote install + migrate + restart ----------------------------------
log "Remote: sync deps, run migrations, restart service"
ssh "$WO_SSH_USER@$WO_SSH_HOST" "STAGING=$STAGING WO_APP_DIR=$WO_APP_DIR UV_MIRROR=$UV_MIRROR bash -s" <<'REMOTE'
set -euo pipefail

# Move staged code into place. We sync rather than swap directories so the
# .venv (large, slow to rebuild) survives across deploys.
sudo rsync -a --delete \
    --exclude '.venv' \
    "$STAGING/" "$WO_APP_DIR/"
sudo chown -R wo:wo "$WO_APP_DIR"
rm -rf "$STAGING"

# Install/sync deps as the wo user so the venv ends up owned correctly.
# UV_MIRROR is forwarded from the local shell over the ssh env above so it
# points at a fast mirror and we don't hang on the Great Firewall.
sudo -u wo bash -lc "
    export UV_DEFAULT_INDEX=$UV_MIRROR
    export UV_INDEX_URL=$UV_MIRROR
    cd $WO_APP_DIR && uv sync --frozen
"

# Migrate. Loads DB url from /etc/wo/db.env via the systemd unit; for one-shot
# alembic we source it inline.
sudo -u wo bash -lc "
    set -a; source /etc/wo/db.env; source /etc/wo/app.env; set +a
    cd $WO_APP_DIR && uv run alembic upgrade head
"

# Restart (or start) the service.
sudo systemctl enable --now wo-backend
sudo systemctl restart wo-backend

# Install the nginx site config from the synced repo. setup-server.sh only runs
# once at bootstrap, so without this any nginx config change (e.g. TLS) would
# never reach /etc/nginx on a normal deploy. Only reload if the test passes, so
# a bad config can't take nginx down.
sudo install -m 0644 "$WO_APP_DIR/deploy/nginx/wo-backend.conf" \
    /etc/nginx/sites-available/wo-backend
sudo ln -sf /etc/nginx/sites-available/wo-backend \
    /etc/nginx/sites-enabled/wo-backend
sudo nginx -t
sudo systemctl reload nginx
REMOTE

# ---- 4. Healthcheck ---------------------------------------------------------
log "Healthcheck → https://$WO_SSH_HOST/api/v1/health"
# -k: this is just a liveness probe, not the app's security boundary. The cert
# is our self-signed one; skipping verification here avoids depending on the
# CA file being present on whoever runs the deploy. The app itself pins the CA.
for i in 1 2 3 4 5; do
    if curl -sfk "https://$WO_SSH_HOST/api/v1/health" \
            | grep -q '"success":true'; then
        log "Deploy OK 🎉"
        exit 0
    fi
    sleep 2
done
echo "Healthcheck failed after 5 attempts — check 'sudo journalctl -u wo-backend -n 100' on the server." >&2
exit 1
