#!/usr/bin/env bash
# cyclosctl.sh - start / stop / restart / status / logs for the Tomcat that runs Cyclos.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_tomcat

case "${1:-status}" in
  start)
    if [[ -n "$(port_pids 8080)" ]]; then die "Something already listens on :8080 - try: $0 status"; fi
    OFFSET="$(stat -c %s "$TOMCAT_HOME/logs/catalina.out" 2>/dev/null || echo 0)"
    tomcat_start
    wait_for_cyclos "$OFFSET" 600
    ;;
  stop)
    tomcat_stop
    echo "Tomcat stopped."
    ;;
  restart)
    tomcat_stop
    OFFSET="$(stat -c %s "$TOMCAT_HOME/logs/catalina.out" 2>/dev/null || echo 0)"
    tomcat_start
    wait_for_cyclos "$OFFSET" 600
    ;;
  status)
    echo "TOMCAT_HOME=$TOMCAT_HOME"
    echo "listening on :8080 -> pid(s): $(port_pids 8080 | tr '\n' ' ')"
    echo "HTTP: $(curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:8080/ || true)"
    ;;
  logs)
    tail -n 100 -f "$TOMCAT_HOME/logs/catalina.out"
    ;;
  *)
    echo "usage: $0 start|stop|restart|status|logs" >&2
    exit 2
    ;;
esac
