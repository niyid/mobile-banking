#!/usr/bin/env bash
# 40-install-kannel.sh - OPTIONAL. Installs Kannel and points it at the bridge.
# Cyclos 4 does not need Kannel (it can call the bridge directly); run this only if you want it.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SENDSMS_PASS="$(env_get "$GATEWAY_ENV" SENDSMS_PASS)"
[[ -n "$SENDSMS_PASS" ]] || die "SENDSMS_PASS not found in $GATEWAY_ENV - run ./20-setup-phone-gateway.sh first"

apt-cache show kannel >/dev/null 2>&1 || { warn "The 'kannel' package is not available in this Ubuntu release's apt archive - skipping Kannel."; exit 0; }
log "Installing Kannel"
sudo apt-get install -y kannel

ADMIN_PASS="$(rand_token 24)"
sudo mkdir -p /etc/kannel /var/log/kannel
sed -e "s|<CHANGE_ME_ADMIN_PASSWORD>|$ADMIN_PASS|g" -e "s|<CHANGE_ME_SENDSMS_PASSWORD>|$SENDSMS_PASS|g" \
  "$SETUP_DIR/kannel/kannel.conf" | sudo tee /etc/kannel/kannel.conf >/dev/null
sudo chmod 640 /etc/kannel/kannel.conf
log "Installed /etc/kannel/kannel.conf (passwords generated; not stored in this repo)"
echo "Start it with: sudo systemctl restart kannel   (or run bearerbox/smsbox manually if your package has no unit)"
