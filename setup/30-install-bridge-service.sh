#!/usr/bin/env bash
# 30-install-bridge-service.sh - installs and starts the bridge as a systemd service (cyclos-bridge).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ -x "$SETUP_DIR/bridge/venv/bin/python" ]] || die "Bridge virtualenv missing - run ./25-setup-bridge-venv.sh first"
[[ -f "$GATEWAY_ENV" ]] || warn "$GATEWAY_ENV does not exist yet - run ./20-setup-phone-gateway.sh (the bridge will refuse to send until then)"

log "Installing /etc/systemd/system/cyclos-bridge.service"
# retire the old template-style unit from earlier versions of this package, if present
sudo systemctl disable --now "cyclos-bridge@$USER" >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/cyclos-bridge@.service

sed -e "s|@USER@|$USER|g" -e "s|@SETUP_DIR@|$SETUP_DIR|g" -e "s|@GATEWAY_ENV@|$GATEWAY_ENV|g" \
  "$SETUP_DIR/systemd/cyclos-bridge.service.template" | sudo tee /etc/systemd/system/cyclos-bridge.service >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable cyclos-bridge >/dev/null
sudo systemctl restart cyclos-bridge

log "Checking bridge health"
for i in $(seq 1 10); do
  if curl -fs http://127.0.0.1:5000/health >/dev/null; then
    echo "Bridge is up: http://127.0.0.1:5000/health"
    exit 0
  fi
  sleep 1
done
warn "Bridge did not answer on :5000/health - check: sudo journalctl -u cyclos-bridge -n 50"
exit 1
