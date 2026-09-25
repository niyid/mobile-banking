#!/usr/bin/env bash
# check-phone-format.sh
#
# Tells you exactly what shape Cyclos has member mobile numbers stored in,
# so bridge.py's CYCLOS_PHONE_FORMAT can be pointed at the right target
# instead of guessed at. Fixes the "registered member reported as
# unregistered" bug, which is almost always a format mismatch between what
# the phone app reports as an SMS sender and what Cyclos has on file.
#
# Schema confirmed against a live Cyclos 4.16.20 install (not guessed):
#   contact_infos.mobile_phone   - member's stored mobile number
#   inbound_sms.phone_number     - what Cyclos actually logged as the sender
#                                   on real inbound messages (if any have
#                                   come through yet)
#   outbound_sms.phone_number    - what Cyclos actually sent to, outbound
#
# Usage: ./check-phone-format.sh
# Uses the same DB_ENV / pgsu access every other script in this repo uses
# (see lib.sh, 35-verify-sms-wiring.sh, 36-configure-cyclos-sms.sh) - no
# separate credentials to set up.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ -f "$DB_ENV" ]] || die "$DB_ENV not found - run ./10-install-cyclos.sh first"
DB_NAME="$(env_get "$DB_ENV" DB_NAME)"
[[ -n "$DB_NAME" ]] || die "Could not read DB_NAME from $DB_ENV"

echo "Database: $DB_NAME (via pgsu / sudo -u postgres, same as 35- and 36-)"

format_case() {   # format_case COLUMN -> SQL CASE expression as text, for interpolation
  local col="$1"
  echo "CASE
    WHEN $col LIKE '+%'  THEN 'e164'
    WHEN $col LIKE '0%'  THEN 'local0'
    WHEN $col ~ '^[1-9]' THEN 'plain'
    WHEN $col IS NULL OR $col = '' THEN 'empty'
    ELSE 'other'
  END"

}

# --------------------------------------------------------- 1. member numbers
echo
echo "=== [1/3] Member mobile numbers (contact_infos.mobile_phone) ==="
CASE_EXPR="$(format_case mobile_phone)"
pgsu -d "$DB_NAME" -Atc "
  SELECT
    left(mobile_phone, 4) || '...' || right(mobile_phone, 3) || '  (len ' || length(mobile_phone) || ', ' || $CASE_EXPR || ')'
  FROM contact_infos
  WHERE mobile_phone IS NOT NULL AND mobile_phone <> ''
  ORDER BY 1
  LIMIT 20
" 2>/dev/null | sed 's/^/  /'

echo
echo "--- Format breakdown across all members ---"
pgsu -d "$DB_NAME" -Atc "
  SELECT $CASE_EXPR AS format, count(*) AS how_many
  FROM contact_infos
  WHERE mobile_phone IS NOT NULL AND mobile_phone <> ''
  GROUP BY 1
  ORDER BY 2 DESC
" 2>/dev/null | sed 's/^/  /'

# --------------------------------------------------------- 2. actual traffic
order_col() {   # order_col TABLE -> "id" if it exists, else "" (unordered)
  local t="$1"
  local has_id
  has_id="$(pgsu -d "$DB_NAME" -Atc "SELECT 1 FROM information_schema.columns WHERE table_name='$t' AND column_name='id'" 2>/dev/null || true)"
  [[ "$has_id" == "1" ]] && echo "ORDER BY id DESC" || echo ""
}

echo
echo "=== [2/3] Real inbound SMS traffic (inbound_sms.phone_number) ==="
INBOUND_COUNT="$(pgsu -d "$DB_NAME" -Atc "SELECT count(*) FROM inbound_sms" 2>/dev/null || echo 0)"
if [[ "${INBOUND_COUNT:-0}" -gt 0 ]]; then
  CASE_EXPR2="$(format_case phone_number)"
  ORD="$(order_col inbound_sms)"
  pgsu -d "$DB_NAME" -Atc "
    SELECT
      left(phone_number, 4) || '...' || right(phone_number, 3) || '  (' || $CASE_EXPR2 || ')'
    FROM inbound_sms
    $ORD
    LIMIT 10
  " 2>/dev/null | sed 's/^/  /'
  [[ -n "$ORD" ]] && echo "  (most recent first - " || echo "  (unordered - no 'id' column found - "
  echo "   this is what Cyclos actually received as the sender on real messages)"
else
  echo "  No rows yet - no inbound SMS has reached Cyclos so far. Send a test message,"
  echo "  then re-run this script to compare it directly against the member format above."
fi

echo
echo "=== [3/3] Real outbound SMS traffic (outbound_sms.phone_number) ==="
OUTBOUND_COUNT="$(pgsu -d "$DB_NAME" -Atc "SELECT count(*) FROM outbound_sms" 2>/dev/null || echo 0)"
if [[ "${OUTBOUND_COUNT:-0}" -gt 0 ]]; then
  CASE_EXPR3="$(format_case phone_number)"
  ORD="$(order_col outbound_sms)"
  pgsu -d "$DB_NAME" -Atc "
    SELECT
      left(phone_number, 4) || '...' || right(phone_number, 3) || '  (' || $CASE_EXPR3 || ')'
    FROM outbound_sms
    $ORD
    LIMIT 10
  " 2>/dev/null | sed 's/^/  /'
else
  echo "  No rows yet."
fi

echo
echo "=== Verdict ==="
echo "Set CYCLOS_PHONE_FORMAT in ~/.cyclos/phone-gateway.env to whichever format"
echo "dominates '[1/3] Format breakdown' above (e164 | local0 | plain)."
echo "If [2/3] shows inbound traffic already, and its format DOESN'T match [1/3],"
echo "that confirms the mismatch directly - the bridge is sending one shape,"
echo "Cyclos's member records are in another, and that's the whole bug."
