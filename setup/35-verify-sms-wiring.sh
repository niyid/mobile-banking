#!/usr/bin/env bash
# 35-verify-sms-wiring.sh
#
# Cyclos 4 has no REST *API* for configuring the SMS channel (system-management settings
# aren't part of the REST API - see the web-services reference) - normally done in the admin
# UI (System management > System configuration > Configurations > Channels > SMS). But nothing
# ever checked whether that had actually been done: run-all.sh could finish "successfully"
# while Cyclos was still not wired to the bridge at all. This script closes that gap: it
# checks the bridge's own state, and - if it can reach the Cyclos database (same read-only
# access ./36-configure-cyclos-sms.sh uses to write) - reads the actual sms_enabled /
# sms_gateway_url columns from the `configurations` table directly, rather than just printing
# a reminder. It never fails the pipeline - it only reports - because the admin-UI/DB step is
# expected to still be pending on a first run.
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
DB_CHECKED=0
if [[ -f "$DB_ENV" ]]; then
  DB_NAME="$(env_get "$DB_ENV" DB_NAME)"
  ROW="$(pgsu -d "$DB_NAME" -Atc "SELECT sms_enabled, coalesce(sms_gateway_url,'') FROM configurations LIMIT 1" 2>/dev/null || true)"
  if [[ -n "$ROW" ]]; then
    DB_CHECKED=1
    SMS_ENABLED="${ROW%%|*}"
    SMS_URL="${ROW#*|}"
    if [[ "$SMS_ENABLED" == t && -n "$SMS_URL" ]]; then
      echo "OK (sms_enabled=true, sms_gateway_url=$SMS_URL)"
    else
      echo "NOT SET (sms_enabled=$SMS_ENABLED, sms_gateway_url='$SMS_URL')"
      OK=0
      echo "        -> Run ./36-configure-cyclos-sms.sh to set this from the command line, or use the"
      echo "           admin UI: System configuration > your configuration > Channels > SMS."
    fi
  fi
fi
if [[ "$DB_CHECKED" -eq 0 ]]; then
  echo "COULD NOT CHECK ($DB_ENV missing or DB unreachable - run ./10-install-cyclos.sh first)"
  OK=0
  echo "        -> Admin UI: System configuration > your configuration > Channels > SMS > enable it,"
  echo "           then set the outbound gateway URL to:"
  echo "           $BRIDGE_URL/cgi-bin/sendsms?to=<recipient var>&text=<message var>  (auth: HTTP Basic, see README)"
fi

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
  warn "SMS is NOT fully wired into Cyclos yet - step [2] and/or [3] above still need doing (36-configure-cyclos-sms.sh handles [2]; [3] is admin-UI only)."
  echo "Re-run this script (./35-verify-sms-wiring.sh) after completing them."
fi
exit 0
