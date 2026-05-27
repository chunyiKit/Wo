#!/usr/bin/env bash
# Publish a freshly built APK as the app's "latest release".
#
# Run on your laptop after `flutter build apk --release`. Uploads the APK to the
# backend's POST /app/release, which stores exactly one latest release. The app
# then sees it via 关于「窝」 → 检查更新.
#
# version_code MUST match the +N build number you built the APK with (pubspec
# `version: x.y.z+N`); the app compares it against its own build number.
#
# Usage:
#   WO_RELEASE_TOKEN=... bash publish-apk.sh \
#       --apk build/app/outputs/flutter-apk/app-release.apk \
#       --name 0.2.0 --code 2 --notes "新增应用内更新"
#
# Env:
#   WO_RELEASE_TOKEN  required — must equal backend `APP_RELEASE_TOKEN`
#   WO_API_BASE_URL   default https://122.51.81.235
#   WO_CA_CERT        optional CA cert path for curl (else uses -k)

set -euo pipefail

WO_API_BASE_URL="${WO_API_BASE_URL:-https://122.51.81.235}"
APK="" NAME="" CODE="" NOTES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apk)   APK="$2"; shift 2 ;;
        --name)  NAME="$2"; shift 2 ;;
        --code)  CODE="$2"; shift 2 ;;
        --notes) NOTES="$2"; shift 2 ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

: "${WO_RELEASE_TOKEN:?set WO_RELEASE_TOKEN (must match backend APP_RELEASE_TOKEN)}"
[[ -n "$APK"  ]] || { echo "missing --apk" >&2; exit 2; }
[[ -n "$NAME" ]] || { echo "missing --name (version_name, e.g. 0.2.0)" >&2; exit 2; }
[[ -n "$CODE" ]] || { echo "missing --code (version_code, the +N build number)" >&2; exit 2; }
[[ -f "$APK"  ]] || { echo "apk not found: $APK" >&2; exit 2; }

# Pin our CA when available, else skip verification (same rationale as deploy.sh
# healthcheck — the app itself pins the CA; this is just the publish channel).
if [[ -n "${WO_CA_CERT:-}" && -f "${WO_CA_CERT}" ]]; then
    TLS=(--cacert "$WO_CA_CERT")
else
    TLS=(-k)
fi

echo "==> Publishing $APK as $NAME (code $CODE) → $WO_API_BASE_URL"
curl -fsS "${TLS[@]}" \
    -H "X-Release-Token: $WO_RELEASE_TOKEN" \
    -F "file=@${APK};type=application/vnd.android.package-archive" \
    -F "version_name=${NAME}" \
    -F "version_code=${CODE}" \
    -F "notes=${NOTES}" \
    "$WO_API_BASE_URL/api/v1/app/release"
echo
echo "==> Done."
