#!/usr/bin/env bash
# 35-verify-sms-wiring.sh
#
# Cyclos 4 has no REST/API endpoint for configuring the SMS channel itself - that part is
# admin-UI-only (System management > System configuration > Configurations > Channels > SMS),
# so it can't be scripted. That also means nothing else in this package ever checked whether
# it was actually done: run-all.sh could finish "successfully" while Cyclos was still not
# wired to the bridge at all. This script closes that gap by checking the bridge's own state
# and telling you exactly what, if anything, is still missing. It never fails the pipeline -
# it only reports - because the admin-UI step is expected to still be pending on a first run.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE_URL="http://127.0.0.1:${BRIDGE_PORT:-5000}"
OK=1

echo "Checking $GATEWAY_ENV ..."
if [[ ! -f "$GATEWAY_ENV" ]]; then
  warn "Not found - run ./20-setup-phone-gateway.sh first."
  exit 0
fi

SENDSMS_PASS_SET="$([[ -n "$(env_get "$GATEWAY_ENV" SENDSMS_PASS)" ]] && echo yes || echo no)"
RECEIVE_URL="$(env_get "$GATEWAY_ENV" CYCLOS_SMS_RECEIVE_URL)"

echo "Checking bridge health at $BRIDGE_URL/health ..."
HEALTH="$(curl -fs -m 5 "$BRIDGE_URL/health" 2>/dev/null || true)"
if [[ -z "$HEALTH" ]]; then
  warn "Bridge is not answering. Is it running? sudo systemctl status cyclos-bridge"
  OK=0
else
  echo "  $HEALTH"
fi

echo
echo "=== SMS wiring status ==="

echo -n "[1/3] Bridge has a send password (SENDSMS_PASS) ......... "
if [[ "$SENDSMS_PASS_SET" == yes ]]; then echo "OK"; else echo "MISSING"; OK=0; fi

echo -n "[2/3] Cyclos SMS channel enabled + outbound URL set ...... "
cat <<'EOF'
CANNOT BE CHECKED AUTOMATICALLY (Cyclos exposes no API for this - admin UI only)
EOF
echo "        -> Admin UI: System configuration > your configuration > Channels > SMS > enable it,"
echo "           then set the outbound gateway URL to:"
echo "           $BRIDGE_URL/cgi-bin/sendsms?username=cyclos&password=<SENDSMS_PASS from $GATEWAY_ENV>&to=<recipient var>&text=<message var>"

echo -n "[3/3] Inbound SMS URL copied back into $GATEWAY_ENV ...... "
if [[ -n "$RECEIVE_URL" ]]; then
  echo "OK ($RECEIVE_URL)"
else
  echo "MISSING"
  echo "        -> Copy the 'Inbound SMS URL' Cyclos shows on that same Channels > SMS page into:"
  echo "           CYCLOS_SMS_RECEIVE_URL=... in $GATEWAY_ENV, then: sudo systemctl restart cyclos-bridge"
  OK=0
fi

echo
if [[ "$OK" -eq 1 && -n "$HEALTH" && "$HEALTH" == *'"cyclos_inbound_url_configured": true'* ]]; then
  echo "SMS channel appears fully wired: bridge is configured on both ends."
  echo "Send a real test message to the gateway phone number and watch: sudo journalctl -u cyclos-bridge -f"
else
  warn "SMS is NOT fully wired into Cyclos yet - step [2] and/or [3] above still need doing in the admin UI."
  echo "Re-run this script (./35-verify-sms-wiring.sh) after completing them."
fi
exit 0
