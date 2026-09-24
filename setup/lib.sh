#!/usr/bin/env bash
# lib.sh - shared helpers, sourced by the other scripts. Not meant to be run directly.

if [[ -n "${_MB_LIB_LOADED:-}" ]]; then
  return 0
fi
_MB_LIB_LOADED=1

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
warn() { echo -e "\033[1;33m!!\033[0m $*" >&2; }
die()  { echo -e "\n\033[1;31mFAILED:\033[0m $*" >&2; exit 1; }

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="$HOME/.cyclos"
SETUP_ENV="$STATE_DIR/setup.env"          # TOMCAT_HOME, CYCLOS_JAVA_HOME (written by 00)
DB_ENV="$STATE_DIR/db.env"                # DB_NAME / DB_USER / DB_PASS (written by 10)
GATEWAY_ENV="$STATE_DIR/phone-gateway.env" # phone app + bridge settings (written by 20)
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# shellcheck disable=SC1090
if [[ -f "$SETUP_ENV" ]]; then source "$SETUP_ENV"; fi

# ---------------------------------------------------------------- env files
env_get() {   # env_get FILE KEY -> prints value (empty if missing)
  [[ -f "$1" ]] || return 0
  grep -m1 "^$2=" "$1" | cut -d= -f2- || true
}

env_set() {   # env_set FILE KEY VALUE  (replace or append; file is chmod 600)
  local f="$1" tmp
  touch "$f"; chmod 600 "$f"
  tmp="$(mktemp)"
  K="$2" V="$3" awk 'BEGIN{FS=OFS="="; k=ENVIRON["K"]; v=ENVIRON["V"]}
    $1==k && !done {print k "=" v; done=1; next}
    {print}
    END{if(!done) print k "=" v}' "$f" > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
}

env_default() {   # env_default FILE KEY VALUE  (only if the key is absent)
  if ! grep -q "^$2=" "$1" 2>/dev/null; then env_set "$1" "$2" "$3"; fi
}

rand_token() {
  python3 -c "import secrets,string;print(''.join(secrets.choice(string.ascii_letters+string.digits) for _ in range(${1:-24})))"
}

ask() {   # ask VARNAME "prompt" [current] [secret]   (non-interactive: keeps current)
  local __v="$1" __p="$2" __cur="${3:-}" __secret="${4:-}" __in=""
  if [[ ! -t 0 ]]; then printf -v "$__v" '%s' "$__cur"; return 0; fi
  if [[ -n "$__secret" ]]; then
    read -rsp "$__p${__cur:+ [Enter = keep current]}: " __in; echo
  else
    read -rp "$__p${__cur:+ [$__cur]}: " __in
  fi
  printf -v "$__v" '%s' "${__in:-$__cur}"
}

# ---------------------------------------------------------------- postgres
pgsu() {      # run psql as the postgres superuser (from /tmp so sudo doesn't warn about cwd)
  ( cd /tmp && sudo -u postgres psql -v ON_ERROR_STOP=1 "$@" )
}

# ---------------------------------------------------------------- tomcat
tomcat_major() {   # tomcat_major DIR -> "9" / "10" / ...
  [[ -f "$1/bin/version.sh" ]] || return 0
  bash "$1/bin/version.sh" 2>/dev/null | awk -F': *' '/Server number/{split($2,a,"."); print a[1]; exit}' || true
}

port_pids() {      # PIDs listening on a TCP port (sudo so other users' processes are visible too)
  sudo ss -H -ltnp "sport = :$1" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u || true
}

require_tomcat() {
  [[ -n "${TOMCAT_HOME:-}" && -f "$TOMCAT_HOME/bin/catalina.sh" ]] \
    || die "TOMCAT_HOME is not set (or invalid). Run ./00-install-prereqs.sh first."
}

tomcat_stop() {
  require_tomcat
  if systemctl is-active --quiet tomcat9 2>/dev/null; then
    warn "A systemd 'tomcat9' service is running - stopping it"
    sudo systemctl stop tomcat9 || true
  fi
  bash "$TOMCAT_HOME/bin/shutdown.sh" >/dev/null 2>&1 || true

  local i p pid
  for i in $(seq 1 20); do
    if [[ -z "$(port_pids 8080)$(port_pids 8005)" ]]; then return 0; fi
    sleep 1
  done

  for p in 8080 8005; do
    for pid in $(port_pids "$p"); do
      if tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'org.apache.catalina'; then
        warn "Tomcat (pid $pid) did not stop cleanly - terminating it"
        sudo kill "$pid" 2>/dev/null || true
      else
        die "Port $p is held by pid $pid ($(ps -o comm= -p "$pid" 2>/dev/null)), which is not Tomcat. Free that port and re-run."
      fi
    done
  done
  for i in $(seq 1 10); do
    if [[ -z "$(port_pids 8080)$(port_pids 8005)" ]]; then return 0; fi
    sleep 1
  done
  for p in 8080 8005; do
    for pid in $(port_pids "$p"); do sudo kill -9 "$pid" 2>/dev/null || true; done
  done
  sleep 2
  [[ -z "$(port_pids 8080)$(port_pids 8005)" ]] || die "Ports 8080/8005 are still in use after stopping Tomcat. Check: sudo ss -ltnp | grep -E ':8080|:8005'"
}

tomcat_start() {
  require_tomcat
  rm -f "$TOMCAT_HOME/temp/tomcat.pid"
  bash "$TOMCAT_HOME/bin/startup.sh" >/dev/null 2>&1
}

# wait_for_cyclos OFFSET [TIMEOUT_SECONDS]
# OFFSET = size of catalina.out before Tomcat was started, so old log lines are ignored.
wait_for_cyclos() {
  local off="$1" timeout="${2:-600}" t=0 code="000"
  local out="$TOMCAT_HOME/logs/catalina.out" pidfile="$TOMCAT_HOME/temp/tomcat.pid"
  while (( t < timeout )); do
    if grep -q 'Server startup in' <(tail -c +"$((off + 1))" "$out" 2>/dev/null); then break; fi
    if [[ -f "$pidfile" ]] && ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
      warn "The Tomcat JVM exited during startup"; break
    fi
    sleep 5; t=$((t + 5))
  done

  code="$(curl -s -o /dev/null -m 20 -w '%{http_code}' http://127.0.0.1:8080/ || true)"
  echo "http://127.0.0.1:8080/ -> HTTP $code (after ~${t}s)"
  case "$code" in
    200|30[0-9]|401|403) return 0 ;;
  esac
  echo "--- errors logged since this start ($out) ---"
  tail -c +"$((off + 1))" "$out" 2>/dev/null | grep -E 'SEVERE|Exception|Caused by|Error' | tail -n 40 || true
  return 1
}
