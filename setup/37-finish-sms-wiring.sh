#!/usr/bin/env bash
# 37-finish-sms-wiring.sh
#
# Combines steps [2] and [3] of "Wiring SMS into Cyclos" into one run:
#   1. ./36-configure-cyclos-sms.sh   - outbound (DB write + Tomcat restart)
#   2. PAUSE - you copy the Inbound SMS URL from the Cyclos admin UI by hand
#      (System management > System configuration > Configurations > your
#      configuration > Channels > SMS). There is no API/DB shortcut for this
#      half - see the header comment in 36-configure-cyclos-sms.sh.
#   3. Writes CYCLOS_SMS_RECEIVE_URL into phone-gateway.env, restarts the
#      bridge, and re-runs 35-verify-sms-wiring.sh to confirm.
#
# Run this from the setup/ directory: ./37-finish-sms-wiring.sh
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== Step 1/3: outbound (./36-configure-cyclos-sms.sh) ==="
"$SETUP_DIR/36-configure-cyclos-sms.sh" || die "36-configure-cyclos-sms.sh failed - fix that before continuing."

echo
echo "=== Step 2/3: inbound (manual - admin UI) ==="
echo "Open Cyclos, then go to:"
echo "  System management > System configuration > Configurations > <your configuration> > Channels > SMS"
echo "Also double-check the outbound URL field there now shows the {phoneNumber}/{message}"
echo "placeholders correctly - 36-configure-cyclos-sms.sh's syntax was a best guess."
echo
read -rp "Paste the 'Inbound SMS URL' shown on that page: " RECEIVE_URL
[[ -n "$RECEIVE_URL" ]] || die "No URL entered - aborting. Re-run this script when you have it."

env_set "$GATEWAY_ENV" CYCLOS_SMS_RECEIVE_URL "$RECEIVE_URL"
log "Wrote CYCLOS_SMS_RECEIVE_URL to $GATEWAY_ENV"

echo
echo "=== Step 3/3: restart bridge + verify ==="
sudo systemctl restart cyclos-bridge
sleep 1
"$SETUP_DIR/35-verify-sms-wiring.sh"
