#!/usr/bin/env bash
# One-time server bootstrap. Run as root on 122.51.81.235.
#
# Idempotent: every step checks for an existing state before changing things,
# so re-running is safe (and is the recovery path if a step fails).
#
# What it does:
#   1. Install system packages: nginx, build deps for psycopg/Pillow.
#   2. Install `uv` system-wide.
#   3. Create the `wo` system user (no login shell, owns the app dir).
#   4. Create PG role `wo` + database `wo` (uses the existing system PG).
#   5. Write /etc/wo/db.env with the generated PG password (mode 0640).
#   6. Lay down /opt/wo-backend and /var/lib/wo/storage with correct ownership.
#   7. Install the systemd unit + nginx site config (not enabled until first deploy).
#   8. Open UFW ports 80 + SSH if UFW is active.
#
# Cloud-vendor security groups (e.g. 腾讯云安全组) must be opened separately.

set -euo pipefail

APP_USER=wo
APP_DIR=/opt/wo-backend
STORAGE_DIR=/var/lib/wo/storage
ENV_DIR=/etc/wo
DB_NAME=wo
DB_ROLE=wo

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m!!\033[0m %s\n' "$*" >&2; }

if [[ $EUID -ne 0 ]]; then
    echo "Run me as root: sudo bash setup-server.sh" >&2
    exit 1
fi

# ---- 1. System packages ----------------------------------------------------
log "Installing system packages"
export DEBIAN_FRONTEND=noninteractive
# Some Ubuntu boxes ship with a broken `cnf-update-db` apt hook (missing
# apt_pkg, usually after a system Python swap). It's a typo-suggestion helper
# we don't need, so disable the file rather than fight the hook on every run.
CNF_HOOK=/etc/apt/apt.conf.d/50command-not-found
if [[ -f "$CNF_HOOK" ]] && ! python3 -c "import apt_pkg" 2>/dev/null; then
    log "Disabling broken apt hook: $CNF_HOOK"
    mv "$CNF_HOOK" "$CNF_HOOK.disabled"
fi
apt-get update -qq
apt-get install -y --no-install-recommends \
    curl ca-certificates \
    nginx \
    libpq-dev \
    libjpeg-dev libpng-dev libwebp-dev \
    ufw

# ---- 2. uv (Astral) ---------------------------------------------------------
if ! command -v uv >/dev/null 2>&1; then
    log "Installing uv"
    # Install to /usr/local/bin so the wo user can find it.
    curl -LsSf https://astral.sh/uv/install.sh \
        | UV_INSTALL_DIR=/usr/local/bin sh
fi
log "uv: $(uv --version)"

# ---- 3. App user ------------------------------------------------------------
if ! id "$APP_USER" >/dev/null 2>&1; then
    log "Creating system user '$APP_USER'"
    useradd --system --create-home --home-dir /home/$APP_USER \
        --shell /usr/sbin/nologin "$APP_USER"
fi

# ---- 4. PostgreSQL role + DB ------------------------------------------------
log "Configuring PostgreSQL role + database"
if ! pg_isready >/dev/null 2>&1; then
    echo "pg_isready failed — is PG running?" >&2
    exit 1
fi

# Generate password once and persist; subsequent runs reuse it.
mkdir -p "$ENV_DIR"
# Group-own by the app user so deploy.sh's one-shot alembic (run as `wo`) can
# traverse here and `source` the env files. Without the chown the dir is
# root:root 0750 and `wo` is "other" → can't enter → migrations fail.
chown root:"$APP_USER" "$ENV_DIR"
chmod 0750 "$ENV_DIR"
DB_ENV_FILE="$ENV_DIR/db.env"

if [[ ! -f "$DB_ENV_FILE" ]]; then
    # NOTE: `tr -dc ... </dev/urandom | head -c 32` would die under pipefail
    # because head closes the pipe early → SIGPIPE on tr. openssl rand is
    # closed-loop (writes a known length) and 128 bits of entropy is plenty.
    DB_PASSWORD=$(openssl rand -hex 16)
    cat > "$DB_ENV_FILE" <<EOF
# Generated $(date -u +%FT%TZ) by setup-server.sh
DATABASE_URL=postgresql+asyncpg://$DB_ROLE:$DB_PASSWORD@localhost:5432/$DB_NAME
DATABASE_URL_SYNC=postgresql+psycopg://$DB_ROLE:$DB_PASSWORD@localhost:5432/$DB_NAME
EOF
    chown root:$APP_USER "$DB_ENV_FILE"
    chmod 0640 "$DB_ENV_FILE"
else
    # Reuse existing password — extract from the file we wrote earlier.
    DB_PASSWORD=$(grep -oE 'asyncpg://[^:]+:[^@]+@' "$DB_ENV_FILE" \
        | head -1 | sed 's|.*:||; s|@$||')
fi

# Create role if missing; always update password to match the env file.
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_ROLE'" \
        | grep -q 1; then
    sudo -u postgres psql -c \
        "ALTER ROLE $DB_ROLE WITH LOGIN PASSWORD '$DB_PASSWORD';" >/dev/null
else
    sudo -u postgres psql -c \
        "CREATE ROLE $DB_ROLE LOGIN PASSWORD '$DB_PASSWORD';" >/dev/null
fi

# Create database if missing.
if ! sudo -u postgres psql -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
    sudo -u postgres createdb -O "$DB_ROLE" "$DB_NAME"
fi

# ---- 5. App env file --------------------------------------------------------
APP_ENV_FILE="$ENV_DIR/app.env"
if [[ ! -f "$APP_ENV_FILE" ]]; then
    log "Writing $APP_ENV_FILE"
    cat > "$APP_ENV_FILE" <<EOF
# Generated $(date -u +%FT%TZ) by setup-server.sh — edit and 'systemctl restart wo-backend' after changes.
DEBUG=false
STORAGE_ROOT=$STORAGE_DIR
WEB_BASE_URL=http://122.51.81.235
MAX_UPLOAD_BYTES=20971520
EOF
    chown root:$APP_USER "$APP_ENV_FILE"
    chmod 0640 "$APP_ENV_FILE"
fi

# ---- 6. Directories ---------------------------------------------------------
log "Preparing $APP_DIR and $STORAGE_DIR"
mkdir -p "$APP_DIR" "$STORAGE_DIR"
chown -R "$APP_USER:$APP_USER" "$APP_DIR" "$STORAGE_DIR"
# Storage must be writable by the app, readable by no one else (private files).
chmod 0750 "$STORAGE_DIR"

# ---- 7. systemd unit + nginx site ------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "Installing systemd unit"
install -m 0644 "$SCRIPT_DIR/systemd/wo-backend.service" \
    /etc/systemd/system/wo-backend.service
systemctl daemon-reload

log "Installing nginx site"
install -m 0644 "$SCRIPT_DIR/nginx/wo-backend.conf" \
    /etc/nginx/sites-available/wo-backend
ln -sf /etc/nginx/sites-available/wo-backend \
    /etc/nginx/sites-enabled/wo-backend
# Drop the default Ubuntu welcome page if it's still around, so our
# server_name catch-all behavior isn't shadowed.
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

# ---- 8. Firewall ------------------------------------------------------------
if ufw status | grep -q "Status: active"; then
    log "UFW is active — opening 80/tcp"
    ufw allow 22/tcp >/dev/null
    ufw allow 80/tcp >/dev/null
else
    warn "UFW is not active. Make sure 腾讯云 security group allows port 80."
fi

log "Server bootstrap complete."
echo
echo "Next steps:"
echo "  1. From your local machine, run: bash backend/deploy/deploy.sh"
echo "  2. Curl http://122.51.81.235/api/v1/health to verify."
echo
echo "Env files (review for secrets):"
echo "  $DB_ENV_FILE"
echo "  $APP_ENV_FILE"
