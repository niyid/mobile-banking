#!/usr/bin/env bash
# 20-setup-phone-gateway.sh
# Pairs the phone (plugged in by USB) as an SMS gateway using the open-source
# "SMS Gateway for Android" app (https://github.com/capcom6/android-sms-gateway),
# reached over the USB cable via adb - no WiFi and no root required.
#
# Writes ~/.cyclos/phone-gateway.env (chmod 600). Existing values are kept, so it is safe to re-run.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCAL_FORWARD_PORT="${LOCAL_FORWARD_PORT:-18080}"
WEBHOOK_PHONE_SIDE_PORT="${WEBHOOK_PHONE_SIDE_PORT:-8081}"

log "Checking for a connected device"
"$SETUP_DIR/phone-tunnel.sh" >/dev/null   # only to validate the device; prints instructions on failure
log "Device detected: $(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')"

cat <<EOF

Now on the phone:
  1. Install "SMS Gateway for Android" (by capcom6) from Google Play, or side-load the APK from
     https://github.com/capcom6/android-sms-gateway/releases
  2. Open it and grant the SMS + notification permissions.
  3. Switch it to LOCAL SERVER mode (not the cloud relay) and start it. It shows a username and password
     - you will enter them below.
  4. Leave the app running (it keeps a foreground notification so Android won't kill it).
EOF
if [[ -t 0 ]]; then read -rp "Press Enter once the app is running in local-server mode... " _; fi

"$SETUP_DIR/phone-tunnel.sh"

log "Verifying the tunnel"
CODE="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://127.0.0.1:${LOCAL_FORWARD_PORT}/" || true)"
case "$CODE" in
  200|401|403|404) echo "Phone app reachable at http://127.0.0.1:${LOCAL_FORWARD_PORT}/ (HTTP $CODE)" ;;
  *) die "Could not reach the phone app (HTTP $CODE). Make sure it is running in local-server mode, then re-run." ;;
esac

log "Saving settings to $GATEWAY_ENV"
touch "$GATEWAY_ENV"; chmod 600 "$GATEWAY_ENV"
ask P_USER "Phone app username (shown in the app)" "$(env_get "$GATEWAY_ENV" PHONE_GATEWAY_USER)"
ask P_PASS "Phone app password (shown in the app)" "$(env_get "$GATEWAY_ENV" PHONE_GATEWAY_PASS)" secret
ask P_NUM  "This phone's own number, international format (e.g. +234...)" "$(env_get "$GATEWAY_ENV" GATEWAY_PHONE_NUMBER)"

env_set     "$GATEWAY_ENV" PHONE_GATEWAY_URL  "http://127.0.0.1:${LOCAL_FORWARD_PORT}"
env_set     "$GATEWAY_ENV" PHONE_GATEWAY_USER "$P_USER"
env_set     "$GATEWAY_ENV" PHONE_GATEWAY_PASS "$P_PASS"
env_set     "$GATEWAY_ENV" GATEWAY_PHONE_NUMBER "$P_NUM"
env_default "$GATEWAY_ENV" SENDSMS_USER "cyclos"
env_default "$GATEWAY_ENV" SENDSMS_PASS "$(rand_token 24)"
# Fill this in from Cyclos once it is running (see README, "Wiring SMS into Cyclos"):
env_default "$GATEWAY_ENV" CYCLOS_SMS_RECEIVE_URL ""
env_default "$GATEWAY_ENV" CYCLOS_SMS_METHOD "POST"
env_default "$GATEWAY_ENV" CYCLOS_SMS_FROM_PARAM "from"
env_default "$GATEWAY_ENV" CYCLOS_SMS_TEXT_PARAM "text"

if [[ -n "$P_USER" && -n "$P_PASS" ]]; then
  log "Trying to register the inbound-SMS webhook in the phone app (best effort)"
  HTTP="$(curl -s -o /dev/null -m 15 -w '%{http_code}' -u "$P_USER:$P_PASS" -X POST \
    "http://127.0.0.1:${LOCAL_FORWARD_PORT}/webhooks" -H 'Content-Type: application/json' \
    -d "{\"id\":\"cyclos-bridge\",\"url\":\"http://localhost:${WEBHOOK_PHONE_SIDE_PORT}/webhook\",\"event\":\"sms:received\"}" || true)"
  case "$HTTP" in
    2*) echo "Webhook registered." ;;
    *)  warn "Automatic registration returned HTTP $HTTP. In the app's webhook settings add:"
        warn "  event: sms:received   URL: http://localhost:${WEBHOOK_PHONE_SIDE_PORT}/webhook" ;;
  esac
else
  warn "Phone app credentials were not entered - edit $GATEWAY_ENV (PHONE_GATEWAY_USER / PHONE_GATEWAY_PASS)."
fi

cat <<EOF

Done. Notes:
  * The adb tunnels only last while the phone stays plugged in. Re-create them any time with ./phone-tunnel.sh
  * Turn off "sleep while charging"/aggressive battery optimisation for the SMS Gateway app on the phone.
  * Next: ./25-setup-bridge-venv.sh, then ./30-install-bridge-service.sh
EOF
