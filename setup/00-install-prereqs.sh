#!/usr/bin/env bash
# 00-install-prereqs.sh
# Installs what Cyclos 4.16 and the phone-SMS bridge need on Ubuntu:
#   - OpenJDK 17          (Cyclos 4.16 needs Java 11+; Tomcat is pinned to 17 in 10-install-cyclos.sh)
#   - PostgreSQL + PostGIS (Cyclos needs PostGIS and the cube/earthdistance/unaccent/pgcrypto extensions)
#   - Tomcat 9.x          (Tomcat 10+ uses jakarta.* and is NOT compatible with Cyclos 4.16)
#   - adb, git, python3 + venv, rsync, curl, unzip
#
# Tomcat lives in your home directory (no root-owned files, no separate system user):
# an existing ~/tomcat is reused if it is Tomcat 9.x, otherwise Tomcat 9 is installed to ~/tomcat9.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $EUID -ne 0 ]] || die "Don't run this as root - it uses sudo itself where needed."

log "Updating apt"
sudo apt-get update -y

log "Installing packages"
sudo apt-get install -y \
  openjdk-17-jdk \
  postgresql postgresql-contrib \
  git curl wget unzip rsync openssl iproute2 \
  python3 python3-venv python3-pip \
  android-tools-adb

log "Enabling PostgreSQL"
sudo systemctl enable --now postgresql

# ------------------------------------------------------------------ PostGIS
PGNUM="$(cd /tmp && sudo -u postgres psql -Atc 'SHOW server_version_num')"
PGMAJ=$(( PGNUM / 10000 ))
log "PostgreSQL major version: $PGMAJ - installing PostGIS"
if ! sudo apt-get install -y "postgresql-${PGMAJ}-postgis-3"; then
  warn "Package postgresql-${PGMAJ}-postgis-3 not found - trying the generic 'postgis' package"
  sudo apt-get install -y postgis \
    || die "Could not install PostGIS for PostgreSQL $PGMAJ. Add the PGDG apt repository (https://www.postgresql.org/download/linux/ubuntu/) and install postgresql-${PGMAJ}-postgis-3, then re-run."
fi

# --------------------------------------------------------------------- Java
CYCLOS_JAVA_HOME=""
cand="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)"
if [[ -x "$cand/bin/java" ]]; then
  CYCLOS_JAVA_HOME="$cand"
else
  CYCLOS_JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
  warn "OpenJDK 17 not found at $cand - falling back to $CYCLOS_JAVA_HOME"
fi
env_set "$SETUP_ENV" CYCLOS_JAVA_HOME "$CYCLOS_JAVA_HOME"
log "Java for Tomcat: $CYCLOS_JAVA_HOME"
"$CYCLOS_JAVA_HOME/bin/java" -version 2>&1 | head -n1 || true

# ------------------------------------------------------------------- Tomcat
FOUND=""
for c in "${TOMCAT_HOME:-}" "$HOME/tomcat" "$HOME/tomcat9"; do
  [[ -n "$c" && -f "$c/bin/catalina.sh" ]] || continue
  maj="$(JAVA_HOME="$CYCLOS_JAVA_HOME" tomcat_major "$c")"
  if [[ "$maj" == "9" ]]; then FOUND="$c"; break; fi
  warn "$c is Tomcat '${maj:-unknown}' - Cyclos 4.16 needs Tomcat 9, skipping it"
done

if [[ -n "$FOUND" ]]; then
  log "Using existing Tomcat 9 at $FOUND"
  TOMCAT_HOME="$FOUND"
else
  TOMCAT_HOME="$HOME/tomcat9"
  FALLBACK_VERSION="9.0.122"
  log "Detecting latest Tomcat 9.x release"
  TOMCAT_VERSION="$(curl -fsSL https://dlcdn.apache.org/tomcat/tomcat-9/ 2>/dev/null \
    | grep -oE 'v9\.0\.[0-9]+' | sed 's/^v//' | sort -t. -k3 -n | tail -n1)" || true
  if [[ -z "${TOMCAT_VERSION:-}" ]]; then
    warn "Could not detect the latest version - using $FALLBACK_VERSION"
    TOMCAT_VERSION="$FALLBACK_VERSION"
  fi
  log "Installing Tomcat $TOMCAT_VERSION to $TOMCAT_HOME"

  TARBALL="apache-tomcat-${TOMCAT_VERSION}.tar.gz"
  TMP_DIR="$(mktemp -d)"
  DL="https://dlcdn.apache.org/tomcat/tomcat-9/v${TOMCAT_VERSION}/bin/${TARBALL}"
  AR="https://archive.apache.org/dist/tomcat/tomcat-9/v${TOMCAT_VERSION}/bin/${TARBALL}"
  if ! curl -fsSL -o "$TMP_DIR/$TARBALL" "$DL"; then
    warn "Not on dlcdn.apache.org (it only keeps recent releases) - trying the archive"
    curl -fsSL -o "$TMP_DIR/$TARBALL" "$AR" || die "Could not download Tomcat $TOMCAT_VERSION"
    DL="$AR"
  fi
  curl -fsSL -o "$TMP_DIR/$TARBALL.sha512" "${DL}.sha512" || die "Could not download the Tomcat checksum"
  ( cd "$TMP_DIR" && echo "$(awk '{print $1}' "$TARBALL.sha512")  $TARBALL" | sha512sum -c - ) \
    || die "Tomcat checksum verification failed"

  rm -rf "$TOMCAT_HOME"
  mkdir -p "$TOMCAT_HOME"
  tar xzf "$TMP_DIR/$TARBALL" -C "$TOMCAT_HOME" --strip-components=1
  chmod +x "$TOMCAT_HOME"/bin/*.sh
  rm -rf "$TMP_DIR"
  [[ -f "$TOMCAT_HOME/bin/catalina.sh" ]] || die "Tomcat extraction did not produce $TOMCAT_HOME/bin/catalina.sh"
fi

env_set "$SETUP_ENV" TOMCAT_HOME "$TOMCAT_HOME"

log "Versions"
JAVA_HOME="$CYCLOS_JAVA_HOME" bash "$TOMCAT_HOME/bin/version.sh" 2>/dev/null | grep -E 'Server number|JVM Version' || true
psql --version
adb --version | head -n1
git --version

log "Prereqs done (TOMCAT_HOME=$TOMCAT_HOME, saved in $SETUP_ENV). Next: ./10-install-cyclos.sh"
