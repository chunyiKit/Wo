#!/usr/bin/env bash
# Generate a private CA + server certificate for the Wo backend.
#
# We serve over a raw IP (no domain), so public CAs like Let's Encrypt won't
# issue a cert. Instead we run our own tiny PKI:
#   - A long-lived CA (the trust anchor). Its public cert is bundled into the
#     Flutter app; the app trusts ONLY this CA (see lib/data/wo_http_overrides
#     .dart). That makes it effectively certificate pinning — more MITM-proof
#     than trusting the public root store.
#   - A leaf cert for the server, signed by the CA, with the server IP in its
#     SubjectAltName (modern TLS validates SAN, not CN).
#
# Outputs (all under ./out/, which is gitignored):
#   ca.crt / ca.key       — the CA. ca.key is SECRET, never commit / upload.
#   server.crt/server.key — what nginx serves. Upload both to the server.
#
# It also copies ca.crt into the Flutter assets so a rebuild picks it up.
# ca.crt is a PUBLIC certificate (no private key) — safe to commit.
#
# Re-running regenerates everything. If you only need a fresh *leaf* (e.g. the
# old one expired) keep ca.crt/ca.key and re-sign — but with a 10y validity you
# shouldn't need to for a long time.

set -euo pipefail

# The IP (or, later, domain) the app connects to. Must match ApiConfig.baseUrl.
SERVER_IP="${WO_SERVER_IP:-122.51.81.235}"
DAYS="${WO_CERT_DAYS:-3650}"   # 10 years — self-managed PKI, no renewal pain.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/out"
# Flutter assets live at the repo root: <repo>/assets/certs/.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ASSET_DIR="$REPO_ROOT/assets/certs"

log() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }

mkdir -p "$OUT_DIR" "$ASSET_DIR"
cd "$OUT_DIR"

# ---- 1. CA ------------------------------------------------------------------
log "Generating CA (valid ${DAYS} days)"
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days "$DAYS" \
    -subj "/CN=Wo Private CA/O=Wo" \
    -out ca.crt

# ---- 2. Server leaf, signed by the CA --------------------------------------
log "Generating server cert for IP ${SERVER_IP} (valid ${DAYS} days)"
openssl genrsa -out server.key 2048
openssl req -new -key server.key \
    -subj "/CN=${SERVER_IP}/O=Wo" \
    -out server.csr

# SAN must carry the IP — Dart/Android validate the connection host against it.
cat > server.ext <<EOF
subjectAltName = IP:${SERVER_IP}
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -sha256 -days "$DAYS" -extfile server.ext \
    -out server.crt

rm -f server.csr server.ext

# ---- 3. Publish the CA cert to the Flutter app ------------------------------
log "Copying ca.crt → ${ASSET_DIR}/wo_ca.crt (bundled into the app)"
cp ca.crt "$ASSET_DIR/wo_ca.crt"

log "Done."
echo
echo "Generated in $OUT_DIR:"
echo "  ca.crt      (public — bundled in app, safe to commit)"
echo "  ca.key      (SECRET — keep offline, never upload/commit)"
echo "  server.crt  (upload to server: /etc/wo/tls/server.crt)"
echo "  server.key  (SECRET — upload to server: /etc/wo/tls/server.key)"
echo
echo "Next:"
echo "  1. Upload the server cert + key (see backend/deploy/tls/install-on-server.sh)."
echo "  2. Rebuild the app:  flutter build apk --release"
