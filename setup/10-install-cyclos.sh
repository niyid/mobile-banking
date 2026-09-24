#!/usr/bin/env bash
# 10-install-cyclos.sh
# Installs Cyclos 4.16.x from the official distribution (the zip you download from
# https://license.cyclos.org after logging in - it cannot be fetched with curl).
#
# What it does:
#   1. finds the distribution (extracted folder or zip)
#   2. creates the PostgreSQL role + database and the required extensions
#   3. deploys web/ as Tomcat's ROOT webapp and writes cyclos.properties
#   4. writes Tomcat's bin/setenv.sh (Java 17, heap size)
#   5. (re)starts Tomcat and waits until Cyclos answers
#
# Re-runnable. Useful environment variables:
#   CYCLOS_VERSION=4.16.20   CYCLOS_DIR=/path/to/cyclos-4.16.20   CYCLOS_ZIP=/path/to/cyclos-4.16.20.zip
#   CYCLOS_DB_NAME=cyclos4   RESET_DB=1 (drop and recreate the database - DESTROYS Cyclos data)
#   CYCLOS_XMX_MB=1536
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $EUID -ne 0 ]] || die "Don't run this as root - it uses sudo itself where needed."

CYCLOS_VERSION="${CYCLOS_VERSION:-4.16.20}"
CYCLOS_DB_NAME="${CYCLOS_DB_NAME:-cyclos4}"
CYCLOS_DB_USER="${CYCLOS_DB_USER:-cyclos}"
RESET_DB="${RESET_DB:-0}"

require_tomcat
[[ "$(JAVA_HOME="${CYCLOS_JAVA_HOME:-${JAVA_HOME:-}}" tomcat_major "$TOMCAT_HOME")" == "9" ]] \
  || die "$TOMCAT_HOME is not Tomcat 9.x (Cyclos 4.16 does not work on Tomcat 10+). Re-run ./00-install-prereqs.sh"
sudo -v || die "sudo access is needed"

# ------------------------------------------------------------ 1. distribution
log "Locating the Cyclos $CYCLOS_VERSION distribution"
WEB=""
for c in "${CYCLOS_DIR:-}" "$HOME/cyclos-$CYCLOS_VERSION"; do
  if [[ -n "$c" && -f "$c/web/WEB-INF/web.xml" ]]; then WEB="$c/web"; break; fi
done

if [[ -z "$WEB" ]]; then
  ZIP=""
  for c in "${CYCLOS_ZIP:-}" "$HOME/cyclos-$CYCLOS_VERSION.zip" "$HOME/Downloads/cyclos-$CYCLOS_VERSION.zip" \
           "$HOME/build/cyclos-$CYCLOS_VERSION.zip" "$PWD/cyclos-$CYCLOS_VERSION.zip"; do
    if [[ -n "$c" && -s "$c" ]]; then ZIP="$c"; break; fi
  done
  if [[ -z "$ZIP" ]]; then
    ZIP="$(find "$HOME" -maxdepth 2 -name "cyclos-${CYCLOS_VERSION}.zip" -print -quit 2>/dev/null || true)"
  fi
  [[ -n "$ZIP" ]] || die "Cyclos $CYCLOS_VERSION not found. Download cyclos-$CYCLOS_VERSION.zip from https://license.cyclos.org (login required) and either extract it to ~/cyclos-$CYCLOS_VERSION or set CYCLOS_ZIP=/path/to/the.zip"
  log "Extracting $ZIP"
  unzip -tq "$ZIP" >/dev/null || die "$ZIP is corrupt or incomplete - download it again"
  DEST="$HOME/cyclos-$CYCLOS_VERSION"
  mkdir -p "$DEST"
  unzip -q -o "$ZIP" -d "$DEST"
  WEBXML="$(find "$DEST" -maxdepth 3 -path '*/web/WEB-INF/web.xml' -print -quit)"
  [[ -n "$WEBXML" ]] || die "No web/WEB-INF/web.xml inside $ZIP - is this the Cyclos distribution?"
  WEB="$(dirname "$(dirname "$WEBXML")")"
fi

ls "$WEB"/WEB-INF/lib/*.jar >/dev/null 2>&1 \
  || die "$WEB/WEB-INF/lib has no jars - this looks like a source tree, not the compiled Cyclos distribution."
echo "Cyclos web application: $WEB"

# --------------------------------------------------------------- 2. database
if [[ -f "$DB_ENV" ]]; then
  DB_USER="$(env_get "$DB_ENV" DB_USER)"; DB_PASS="$(env_get "$DB_ENV" DB_PASS)"
fi
DB_USER="${DB_USER:-$CYCLOS_DB_USER}"
DB_PASS="${DB_PASS:-$(rand_token 24)}"
DB_NAME="$CYCLOS_DB_NAME"
: > "$DB_ENV.tmp" && chmod 600 "$DB_ENV.tmp"
{ echo "DB_NAME=$DB_NAME"; echo "DB_USER=$DB_USER"; echo "DB_PASS=$DB_PASS"; } > "$DB_ENV.tmp"
mv "$DB_ENV.tmp" "$DB_ENV"
log "Database settings saved to $DB_ENV (database '$DB_NAME', role '$DB_USER')"

log "Creating / updating the PostgreSQL role"
if [[ "$(pgsu -Atc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")" == "1" ]]; then
  pgsu -c "ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';" >/dev/null
else
  pgsu -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';" >/dev/null
fi

if [[ "$RESET_DB" == "1" ]]; then
  warn "RESET_DB=1 - dropping database '$DB_NAME'"
  pgsu -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}';" >/dev/null || true
  pgsu -c "DROP DATABASE IF EXISTS ${DB_NAME};" >/dev/null
fi

log "Creating database '$DB_NAME' and extensions"
if [[ "$(pgsu -Atc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")" != "1" ]]; then
  pgsu -c "CREATE DATABASE ${DB_NAME} ENCODING 'UTF8' TEMPLATE template0 OWNER ${DB_USER};" >/dev/null
fi
for ext in cube earthdistance postgis unaccent pgcrypto; do
  pgsu -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS ${ext};" >/dev/null \
    || die "Could not create PostgreSQL extension '$ext' in '$DB_NAME'. For 'postgis' install the postgresql-<version>-postgis-3 package (00-install-prereqs.sh does this)."
done
echo "Extensions ready: $(pgsu -d "$DB_NAME" -Atc "SELECT string_agg(extname, ', ' ORDER BY extname) FROM pg_extension WHERE extname IN ('cube','earthdistance','postgis','unaccent','pgcrypto')")"

# ------------------------------------------------------------------ 3. deploy
log "Stopping Tomcat and freeing ports 8080/8005"
tomcat_stop

APP="$TOMCAT_HOME/webapps/ROOT"
log "Deploying Cyclos into $APP"
rm -rf "$TOMCAT_HOME/webapps/cyclos" "$TOMCAT_HOME/webapps/cyclos.war" \
       "$TOMCAT_HOME/webapps/ROOT" "$TOMCAT_HOME/webapps/ROOT.war" \
       "$TOMCAT_HOME"/work/Catalina/localhost/* "$TOMCAT_HOME"/temp/*
# Tomcat also keeps persistent context descriptors under conf/Catalina/localhost/
# independent of the webapps/ directory - a leftover ROOT.xml or cyclos.xml from an
# earlier (e.g. Cyclos 3) deployment gets reprocessed on every startup regardless of
# what we just did to webapps/, and can bring up a stale/incomplete context before
# the fresh directory is even deployed. Clear them so webapps/ is the only source of
# truth for what gets deployed.
rm -f "$TOMCAT_HOME"/conf/Catalina/localhost/ROOT.xml \
      "$TOMCAT_HOME"/conf/Catalina/localhost/cyclos.xml
cp -r "$WEB" "$APP" || die "copying the web application into Tomcat failed"

CLASSES="$APP/WEB-INF/classes"
mkdir -p "$CLASSES"
PROPS="$CLASSES/cyclos.properties"
if [[ ! -f "$PROPS" ]]; then
  if [[ -f "$CLASSES/cyclos-release.properties" ]]; then
    cp "$CLASSES/cyclos-release.properties" "$PROPS"
  else
    : > "$PROPS"
  fi
fi

log "Writing database settings into cyclos.properties"
CYC_PROPS="$PROPS" CYC_URL="jdbc:postgresql://localhost:5432/${DB_NAME}" CYC_USER="$DB_USER" CYC_PASS="$DB_PASS" \
python3 - <<'PY'
import os, re, sys
path = os.environ["CYC_PROPS"]
vals = {"url": os.environ["CYC_URL"], "user": os.environ["CYC_USER"], "pass": os.environ["CYC_PASS"]}
defaults = {"url": "cyclos.datasource.jdbcUrl", "user": "cyclos.datasource.username", "pass": "cyclos.datasource.password"}
keyre = re.compile(r'^\s*#?\s*(cyclos\.datasource\.[A-Za-z0-9_.]+)\s*[=:]')
lines = open(path, encoding="utf-8").read().splitlines()
out, done = [], set()
for line in lines:
    m = keyre.match(line)
    if m:
        key = m.group(1); k = key.lower()
        kind = "pass" if "password" in k else "user" if "user" in k else "url" if k.endswith("url") else None
        if kind and kind not in done:
            out.append(f"{key} = {vals[kind]}"); done.add(kind); continue
    out.append(line)
missing = [k for k in vals if k not in done]
if missing:
    out.append("")
    out.append("# added by 10-install-cyclos.sh (these keys were not present in the template)")
    for k in missing:
        out.append(f"{defaults[k]} = {vals[k]}")
    print("WARNING: no datasource key for %s in the template; appended %s - verify the key names against cyclos-release.properties"
          % (", ".join(missing), ", ".join(defaults[k] for k in missing)), file=sys.stderr)
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
chmod 600 "$PROPS"
echo "cyclos.properties datasource lines:"
grep -nE '^\s*cyclos\.datasource\.' "$PROPS" | sed -E 's/(password[^=]*=).*/\1 ****/I' || true

if ! ls "$APP"/WEB-INF/lib/postgresql*.jar >/dev/null 2>&1; then
  log "No PostgreSQL JDBC driver in the distribution - downloading one"
  JAR_TMP="$(mktemp)"
  curl -fL --retry 3 -o "$JAR_TMP" \
    "https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar" \
    && unzip -tq "$JAR_TMP" >/dev/null \
    || die "Could not download a complete PostgreSQL JDBC driver"
  mv "$JAR_TMP" "$APP/WEB-INF/lib/postgresql-42.7.4.jar"
fi

# Sanity-check the jar set we actually deployed. A NoClassDefFoundError for
# org.apache.logging.log4j.Logger at startup means log4j-api.jar (and usually
# log4j-core.jar) is missing or corrupt in WEB-INF/lib - this happens if the
# distribution zip was partially downloaded/extracted. We can't be certain
# which log4j2 version Cyclos 4.16.20 was built against, so this is a
# best-effort repair: only trips if the jars are truly absent, and downloads
# a recent patched 2.x release rather than guessing an exact pin.
JAR_COUNT="$(ls "$APP"/WEB-INF/lib/*.jar 2>/dev/null | wc -l)"
LOG4J_API="$(ls "$APP"/WEB-INF/lib/log4j-api*.jar 2>/dev/null | head -1)"
LOG4J_CORE="$(ls "$APP"/WEB-INF/lib/log4j-core*.jar 2>/dev/null | head -1)"
echo "Deployed WEB-INF/lib: $JAR_COUNT jars (log4j-api: ${LOG4J_API:-MISSING}, log4j-core: ${LOG4J_CORE:-MISSING})"

if [[ -z "$LOG4J_API" || -z "$LOG4J_CORE" ]]; then
  warn "log4j2 jar(s) missing from the deployed webapp - Tomcat will fail with NoClassDefFoundError: org.apache.logging.log4j.Logger"
  warn "Checking whether the source distribution actually has them..."
  if ls "$WEB"/WEB-INF/lib/log4j-api*.jar "$WEB"/WEB-INF/lib/log4j-core*.jar >/dev/null 2>&1; then
    die "log4j jars exist in $WEB/WEB-INF/lib but did not make it into $APP/WEB-INF/lib - the 'cp -r' copy above is incomplete or the source jars are corrupt. Check disk space and re-run with RESET_DB left at 0 (no data loss on re-copy)."
  fi
  warn "log4j jars are absent from the distribution itself ($WEB/WEB-INF/lib). This most likely means $HOME/cyclos-$CYCLOS_VERSION was extracted from a partial/corrupt download."
  warn "Downloading log4j-api/log4j-core 2.24.3 as a stopgap - if Cyclos needs a different exact version this may not resolve it, but it's a safe, currently-patched release to try first."
  for spec in "log4j-api" "log4j-core"; do
    JAR_TMP="$(mktemp)"
    curl -fL --retry 3 -o "$JAR_TMP" \
      "https://repo1.maven.org/maven2/org/apache/logging/log4j/${spec}/2.24.3/${spec}-2.24.3.jar" \
      && unzip -tq "$JAR_TMP" >/dev/null \
      || die "Could not download $spec - check your internet connection, or download cyclos-$CYCLOS_VERSION.zip again from https://license.cyclos.org (the current copy is likely corrupt)"
    mv "$JAR_TMP" "$APP/WEB-INF/lib/${spec}-2.24.3.jar"
  done
  warn "log4j jars added. Re-download cyclos-$CYCLOS_VERSION.zip from https://license.cyclos.org when convenient and re-run this script (RESET_DB=0) to get the exact jars Cyclos shipped with, rather than relying on this stopgap."
fi

# --------------------------------------------------------------- 4. setenv.sh
MEM_MB="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
if (( MEM_MB >= 4096 )); then DEF_XMX=1536; else DEF_XMX=1024; fi
XMX="${CYCLOS_XMX_MB:-$DEF_XMX}"
mkdir -p "$TOMCAT_HOME/bin"
{
  echo '#!/usr/bin/env bash'
  echo '# generated by 10-install-cyclos.sh'
  [[ -n "${CYCLOS_JAVA_HOME:-}" ]] && echo "export JAVA_HOME=\"$CYCLOS_JAVA_HOME\""
  echo "export CATALINA_PID=\"$TOMCAT_HOME/temp/tomcat.pid\""
  echo "export CATALINA_OPTS=\"-Xms512m -Xmx${XMX}m -Djava.awt.headless=true -Dfile.encoding=UTF-8\""
} > "$TOMCAT_HOME/bin/setenv.sh"
chmod +x "$TOMCAT_HOME/bin/setenv.sh"
mkdir -p "$TOMCAT_HOME/temp"

# ------------------------------------------------------------------ 5. start
LOGFILE="$TOMCAT_HOME/logs/catalina.out"
OFFSET="$(stat -c %s "$LOGFILE" 2>/dev/null || echo 0)"
log "Starting Tomcat (first start creates the Cyclos schema - allow several minutes)"
tomcat_start
if wait_for_cyclos "$OFFSET" 900; then
  cat <<EOF

Cyclos is up:  http://localhost:8080/
  Log in / activate the licence in the browser: on first start Cyclos asks for your
  license.cyclos.org user ID and password (free licence, up to 300 users).
  Enter them there - do not put them in any script or file.

  Database:   $DB_NAME  (credentials in $DB_ENV)
  Tomcat:     $TOMCAT_HOME   (control with ./cyclosctl.sh start|stop|restart|status|logs)
  Next:       phone gateway -> ./20-setup-phone-gateway.sh   (or see README.md)
EOF
else
  die "Cyclos did not come up. Full log: $LOGFILE   (send me the errors above and the last 40 lines of that file)"
fi
