#!/usr/bin/env bash
# phone-tunnel.sh - (re)creates the two adb tunnels between laptop and phone. Safe to re-run
# any time the phone was unplugged / adb restarted:
#   adb forward  laptop:18080 -> phone:8080   the bridge calls the phone app's HTTP API
#   adb reverse  phone:8081  -> laptop:5000   the phone app calls the bridge's /webhook
# Only these two mappings are touched; your other adb forwards/reverses are left alone.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PHONE_APP_PORT="${PHONE_APP_PORT:-8080}"
LOCAL_FORWARD_PORT="${LOCAL_FORWARD_PORT:-18080}"
WEBHOOK_PHONE_SIDE_PORT="${WEBHOOK_PHONE_SIDE_PORT:-8081}"
BRIDGE_PORT="${BRIDGE_PORT:-5000}"

command -v adb >/dev/null || die "adb is not installed - run ./00-install-prereqs.sh"
adb start-server >/dev/null 2>&1

COUNT="$(adb devices | awk 'NR>1 && $2=="device"' | wc -l)"
if [[ "$COUNT" -eq 0 ]]; then
  cat >&2 <<'EOF'
No authorised device found. On the phone:
  1. Settings -> About phone -> tap "Build number" 7 times to enable Developer options.
  2. Settings -> Developer options -> enable "USB debugging".
  3. Plug the phone in with a USB *data* cable (not charge-only).
  4. Accept the "Allow USB debugging?" prompt on the phone screen.
Then re-run this script.
EOF
  exit 1
fi
if [[ "$COUNT" -gt 1 && -z "${ANDROID_SERIAL:-}" ]]; then
  adb devices >&2
  die "More than one device is attached. Set ANDROID_SERIAL=<serial> (see the list above) and re-run."
fi

adb forward --remove "tcp:${LOCAL_FORWARD_PORT}" >/dev/null 2>&1 || true
adb forward "tcp:${LOCAL_FORWARD_PORT}" "tcp:${PHONE_APP_PORT}"
adb reverse --remove "tcp:${WEBHOOK_PHONE_SIDE_PORT}" >/dev/null 2>&1 || true
adb reverse "tcp:${WEBHOOK_PHONE_SIDE_PORT}" "tcp:${BRIDGE_PORT}"

echo "adb forward: laptop 127.0.0.1:${LOCAL_FORWARD_PORT} -> phone :${PHONE_APP_PORT}"
echo "adb reverse: phone  localhost:${WEBHOOK_PHONE_SIDE_PORT} -> laptop :${BRIDGE_PORT}"
echo "Webhook URL to use inside the phone app: http://localhost:${WEBHOOK_PHONE_SIDE_PORT}/webhook"
