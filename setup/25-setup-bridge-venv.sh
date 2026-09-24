#!/usr/bin/env bash
# 25-setup-bridge-venv.sh - creates (or repairs) the Python virtualenv used by the SMS bridge.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$SETUP_DIR/bridge"

# A venv that was moved/copied from another directory has stale shebangs - detect and rebuild it.
if [[ -x venv/bin/python ]] && venv/bin/python -c 'import flask, requests' >/dev/null 2>&1 \
   && grep -q "^VIRTUAL_ENV=.*$SETUP_DIR/bridge/venv" venv/bin/activate 2>/dev/null; then
  log "Existing virtualenv is healthy"
else
  log "Creating virtualenv in $SETUP_DIR/bridge/venv"
  rm -rf venv
  python3 -m venv venv
fi

venv/bin/pip install -q --upgrade pip
venv/bin/pip install -q -r requirements.txt
log "Bridge dependencies installed. Next: ./30-install-bridge-service.sh"
