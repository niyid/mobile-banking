#!/usr/bin/env bash
# 36-configure-cyclos-sms.sh
#
# Automates the OUTBOUND half of "Wiring SMS into Cyclos" by writing straight to Cyclos's
# own `configurations` table, instead of the admin UI. This is not a documented/public API -
# it is the *opposite* of a snippet in cyclos-reference.html ("1.4.7 Setup a test environment")
# that NULLs these same columns to scrub secrets before sharing a DB dump:
#
#   update configurations set
#       sms_enabled = false, sms_gateway_url = null,
#       sms_username = null, sms_password = null, sms_headers = null, ...
#
# That confirms the column names below exist on a real 4.16.x install. It does NOT confirm:
#   - the exact placeholder syntax Cyclos substitutes into sms_gateway_url for the phone
#     number / message (this script uses {phoneNumber} and {message} as a best guess -
#     Groovy/Spring-style curly braces - based on the scripting reference's bound variable
#     names `phoneNumber` and `message`, but the admin UI is the source of truth: open
#     Channels > SMS on the config and check what it shows next to the URL field before
#     trusting this)
#   - whether per-user "channel access" or per-phone "enabled for SMS" flags also need
#     setting (confirmed to exist for the separate "Web services" channel and are plausible
#     here too, but not confirmed for SMS specifically in this document)
#   - the Inbound SMS URL: there is no matching column in `configurations` in the reference
#     doc, so it's likely a fixed/computed endpoint rather than something to write - this
#     script does not attempt it. Get it from the admin UI's Channels > SMS page as before,
#     put it in phone-gateway.env, and use ./35-verify-sms-wiring.sh to confirm that half.
#
# Cyclos also likely caches configuration rows in memory, so this script restarts Tomcat
# afterwards via cyclosctl.sh for the change to take effect.
#
# Confirmed separately (also from the scripting reference): Cyclos's built-in sender
# authenticates via HTTP Basic Auth (see GatewaySmsSender / the outbound-SMS example scripts),
# not Kannel-style ?username=..&password=.. query params - bridge.py now accepts both.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ -f "$DB_ENV" ]] || die "$DB_ENV not found - run ./10-install-cyclos.sh first"
[[ -f "$GATEWAY_ENV" ]] || die "$GATEWAY_ENV not found - run ./20-setup-phone-gateway.sh first"

DB_NAME="$(env_get "$DB_ENV" DB_NAME)"
SENDSMS_USER="$(env_get "$GATEWAY_ENV" SENDSMS_USER)"
SENDSMS_PASS="$(env_get "$GATEWAY_ENV" SENDSMS_PASS)"
[[ -n "$SENDSMS_USER" && -n "$SENDSMS_PASS" ]] || die "SENDSMS_USER/SENDSMS_PASS missing in $GATEWAY_ENV"

BRIDGE_URL="${BRIDGE_URL:-http://127.0.0.1:${BRIDGE_PORT:-5000}}"
# NOTE: the literal { } placeholders must NOT live inside a ${VAR:-...} default -
# bash's brace-matcher for parameter expansion gets confused by unquoted { } in the
# default word and truncates it (to=`{phoneNumber` , dropping the rest). Build the
# default separately instead.
DEFAULT_GATEWAY_URL="$BRIDGE_URL/cgi-bin/sendsms?to={phoneNumber}&text={message}"
GATEWAY_URL="${GATEWAY_URL:-$DEFAULT_GATEWAY_URL}"

log "Checking how many configurations exist in '$DB_NAME'"
COUNT="$(pgsu -d "$DB_NAME" -Atc "SELECT count(*) FROM configurations")"
[[ "$COUNT" =~ ^[0-9]+$ ]] || die "Could not read the configurations table - is Cyclos's DB reachable?"
if [[ "$COUNT" -ne 1 ]]; then
  echo "Found $COUNT rows in 'configurations':"
  pgsu -d "$DB_NAME" -c "SELECT id, name FROM configurations ORDER BY id"
  ask CONFIG_ID "Which configuration id should get the SMS gateway?" "${CONFIG_ID:-}"
  [[ "$CONFIG_ID" =~ ^[0-9]+$ ]] || die "Not a valid id: '$CONFIG_ID'"
else
  CONFIG_ID="$(pgsu -d "$DB_NAME" -Atc "SELECT id FROM configurations")"
  log "Single configuration found (id=$CONFIG_ID)"
fi

cat <<EOF

About to run, against database '$DB_NAME', configuration id $CONFIG_ID:

  UPDATE configurations SET
      sms_enabled     = true,
      sms_gateway_url = '$GATEWAY_URL',
      sms_username    = '$SENDSMS_USER',
      sms_password    = '***masked***'
  WHERE id = $CONFIG_ID;

Then: sudo systemctl is-active tomcat9 >/dev/null && sudo systemctl restart tomcat9 (or ./cyclosctl.sh restart)
so Cyclos picks up the change.

This is an undocumented write to Cyclos's own tables, not a supported API - double-check the
result in the admin UI (Channels > SMS) afterwards.
EOF
if [[ -t 0 ]]; then read -rp "Proceed? [y/N] " CONFIRM; [[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Aborted."; fi

# NOTE: `psql -c "..."` does NOT perform :'var' interpolation - only -f/stdin do
# (verified against a live 16.x server: -c leaves the literal colons in the SQL,
# which Postgres then rejects as a syntax error). Feed the UPDATE via stdin instead.
pgsu -d "$DB_NAME" -v ON_ERROR_STOP=1 \
  -v gwurl="$GATEWAY_URL" -v gwuser="$SENDSMS_USER" -v gwpass="$SENDSMS_PASS" -v cfgid="$CONFIG_ID" \
  <<'SQL'
UPDATE configurations SET sms_enabled = true, sms_gateway_url = :'gwurl', sms_username = :'gwuser', sms_password = :'gwpass' WHERE id = :cfgid;
SQL

log "Restarting Tomcat so Cyclos reloads the configuration"
"$SETUP_DIR/cyclosctl.sh" restart

cat <<EOF

Done. This only covers the OUTBOUND side, and the placeholder syntax in the URL is an
educated guess (see the header comment). Next:
  1. Open the admin UI (Channels > SMS on this configuration) and confirm it shows the
     values above and that the phone/message placeholders match what's actually in the URL
     field - fix the URL by hand there if the syntax differs.
  2. Still get the Inbound SMS URL from that same page by hand (see README) and put it in
     $GATEWAY_ENV as CYCLOS_SMS_RECEIVE_URL, then: sudo systemctl restart cyclos-bridge
  3. ./35-verify-sms-wiring.sh to confirm both ends
EOF
