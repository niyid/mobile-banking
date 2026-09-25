#!/usr/bin/env bash
# 38-finish-and-test-sms.sh
#
# Ties together the remaining steps for tonight in one pass:
#   1. sanity-check bridge.py and check-phone-format.sh (catch typos before restarting)
#   2. show current CYCLOS_PHONE_FORMAT / PHONE_COUNTRY_CODE
#   3. run check-phone-format.sh against the live DB
#   4. restart the bridge service so it picks up any env changes
#   5. re-run 35-verify-sms-wiring.sh
#   6. tail the bridge log, filtered to the lines that matter, so a real
#      test SMS is easy to read against
#
# This does NOT send a test SMS for you - that has to come from a real
# phone to the gateway number. Run this, then send the text, and watch
# step 6's output.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== [1/6] Syntax-checking scripts ==="
for f in "$SETUP_DIR"/*.sh; do
  bash -n "$f" || die "Syntax error in $f - fix before continuing."
done
python3 -m py_compile "$SETUP_DIR/bridge/bridge.py" \
  || die "bridge.py has a syntax error - fix before continuing."
echo "All scripts OK."

echo
echo "=== [2/6] Current phone-number settings in $GATEWAY_ENV ==="
CUR_FORMAT="$(env_get "$GATEWAY_ENV" CYCLOS_PHONE_FORMAT)"
CUR_CC="$(env_get "$GATEWAY_ENV" PHONE_COUNTRY_CODE)"
echo "  CYCLOS_PHONE_FORMAT = ${CUR_FORMAT:-<not set, bridge defaults to e164>}"
echo "  PHONE_COUNTRY_CODE  = ${CUR_CC:-<not set, bridge defaults to 234>}"

echo
echo "=== [3/6] Checking Cyclos's actual stored phone-number format ==="
"$SETUP_DIR/check-phone-format.sh" || warn "check-phone-format.sh reported a problem - read its output above before trusting CYCLOS_PHONE_FORMAT."

echo
echo "If the format above doesn't match CYCLOS_PHONE_FORMAT, fix it now:"
echo "  nano $GATEWAY_ENV   # edit CYCLOS_PHONE_FORMAT, save, then re-run this script"
read -rp "Press Enter once CYCLOS_PHONE_FORMAT is correct (or already was) to continue... " _

echo
echo "=== [4/6] Restarting cyclos-bridge ==="
sudo systemctl restart cyclos-bridge
sleep 2
if ! sudo systemctl is-active --quiet cyclos-bridge; then
  die "cyclos-bridge failed to start - check: sudo journalctl -u cyclos-bridge -n 50 --no-pager"
fi
HEALTH="$(curl -fs -m 5 http://127.0.0.1:5000/health || true)"
[[ -n "$HEALTH" ]] || die "Bridge restarted but /health is not answering."
echo "  $HEALTH"

echo
echo "=== [5/6] Re-checking SMS wiring ==="
"$SETUP_DIR/35-verify-sms-wiring.sh"

echo
echo "=== [6/6] Watching the bridge log ==="
echo "Send a real text message to the gateway phone number NOW."
echo "Showing: webhook events, forwarding results, and normalization lines."
echo "Press Ctrl+C once you've seen the result of your test message."
echo
sudo journalctl -u cyclos-bridge -f --no-pager \
  | grep --line-buffered -E 'Webhook event|Forwarded inbound|Forwarding inbound|normalized|unregistered|ERROR|Unregistered'
