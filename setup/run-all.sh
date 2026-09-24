#!/usr/bin/env bash
# run-all.sh - runs the Cyclos 4 + phone-SMS-gateway setup, stage by stage.
#
#   00  prerequisites (Java 17, PostgreSQL + PostGIS, Tomcat 9, adb, ...)
#   10  Cyclos 4.16 (database, deploy, Tomcat config, start)
#   20  pair the phone as SMS gateway   (interactive: needs the phone plugged in)
#   25  bridge Python virtualenv
#   30  bridge as a systemd service
#   40  Kannel                          (optional, only with --with-kannel)
#   50  commit the non-secret config to ~/git/mobile-banking
#
# Usage:
#   ./run-all.sh --until 10          # recommended first run: prerequisites + Cyclos only
#   ./run-all.sh --from 20           # later: phone gateway, bridge, service, git
#   ./run-all.sh                     # everything
#   ./run-all.sh --skip-phone        # everything except stage 20
#   ./run-all.sh --with-kannel       # also stage 40
# Any stage can also be run on its own, e.g. ./10-install-cyclos.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_FILE="$SCRIPT_DIR/run-all.log"
FROM=0
UNTIL=99
SKIP_PHONE=0
WITH_KANNEL=0

log()  { echo -e "\n\033[1;32m==>\033[0m $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "\033[1;33m!!\033[0m $*" | tee -a "$LOG_FILE" >&2; }
die()  { echo -e "\033[1;31mFATAL:\033[0m $*" | tee -a "$LOG_FILE" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)        [[ $# -ge 2 ]] || die "--from needs a stage number"; FROM="$2"; shift 2 ;;
    --until)       [[ $# -ge 2 ]] || die "--until needs a stage number"; UNTIL="$2"; shift 2 ;;
    --skip-phone)  SKIP_PHONE=1; shift ;;
    --with-kannel) WITH_KANNEL=1; shift ;;
    -h|--help)     sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done
[[ "$FROM" =~ ^[0-9]+$ && "$UNTIL" =~ ^[0-9]+$ ]] || die "--from/--until take numbers such as 10 or 25"

[[ $EUID -ne 0 ]] || die "Don't run this as root - the stage scripts call sudo themselves where needed."
chmod +x ./*.sh

echo "=== run-all $(date '+%F %T')  from=$FROM until=$UNTIL ===" >> "$LOG_FILE"
trap 'warn "Stopped early. Fix the problem, then resume with:  ./run-all.sh --from <stage>   (log: $LOG_FILE)"' ERR
sudo -v

in_range() { (( 10#$1 >= 10#$FROM && 10#$1 <= 10#$UNTIL )); }

run_stage() {   # run_stage ID "description" script
  in_range "$1" || return 0
  log "[$1] $2"
  "./$3" 2>&1 | tee -a "$LOG_FILE"
}

run_stage 00 "Installing prerequisites"                    00-install-prereqs.sh
run_stage 10 "Installing Cyclos 4.16 and starting Tomcat"  10-install-cyclos.sh
if in_range 20 && [[ "$SKIP_PHONE" -eq 0 ]]; then
  log "[20] Pairing the phone as SMS gateway (interactive)"
  ./20-setup-phone-gateway.sh        # not piped through tee: it prompts for input
fi

run_stage 25 "Setting up the bridge virtualenv"            25-setup-bridge-venv.sh
run_stage 30 "Installing the bridge as a systemd service"  30-install-bridge-service.sh
if [[ "$WITH_KANNEL" -eq 1 ]]; then run_stage 40 "Installing Kannel (optional)" 40-install-kannel.sh; fi
run_stage 50 "Committing config to git"                    git-init-commit.sh

log "Finished stages $FROM..$UNTIL."
cat <<EOF | tee -a "$LOG_FILE"

Cyclos:         http://localhost:8080/        (control: ./cyclosctl.sh start|stop|restart|status|logs)
Bridge health:  http://127.0.0.1:5000/health
Secrets:        ~/.cyclos/   (db.env, phone-gateway.env - never committed)
SMS wiring:     see README.md, "Wiring SMS into Cyclos"
EOF
