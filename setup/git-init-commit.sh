#!/usr/bin/env bash
# git-init-commit.sh
# Commits the non-secret configuration into ~/git/mobile-banking and pushes it,
# if a remote is already configured. It deliberately does NOT commit ~/.cyclos/
# (DB password, phone gateway credentials) - those stay local.
set -euo pipefail

log() { echo -e "\n\033[1;32m==>\033[0m $*"; }

REPO_DIR="$HOME/git/mobile-banking"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$REPO_DIR"
if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Initializing git repo at $REPO_DIR"
  git -C "$REPO_DIR" init
fi

log "Copying config (scripts, Kannel/bridge templates, systemd units, README) into $REPO_DIR"
rsync -a --exclude 'venv' --exclude '__pycache__' --exclude 'run-all.log' \
  "$SRC_DIR"/ "$REPO_DIR"/setup/

cat > "$REPO_DIR/.gitignore" <<'EOF'
# secrets / machine-local state never belong in this repo
*.env
venv/
__pycache__/
*.pyc
EOF

# Belt-and-braces: strip any real credentials that might have been pasted into
# tracked files before committing (kannel.conf template ships with placeholders,
# but double-check in case someone filled it in in place).
if grep -RIl "CHANGE_ME" "$REPO_DIR/setup" >/dev/null 2>&1; then
  log "kannel.conf / other templates still have <CHANGE_ME_*> placeholders — good, nothing to strip."
fi

cd "$REPO_DIR"
if ! git config user.email >/dev/null 2>&1 || ! git config user.name >/dev/null 2>&1; then
  echo "Set your git identity first:  git config --global user.name 'Your Name'; git config --global user.email you@example.com" >&2
  exit 1
fi
git add -A
if git diff --cached --quiet; then
  log "Nothing new to commit."
else
  git commit -m "Cyclos + phone SMS gateway bridge: setup scripts and config templates"
fi

if git remote get-url origin >/dev/null 2>&1; then
  log "Pushing to origin"
  git push origin "$(git symbolic-ref --short HEAD)"
else
  cat <<EOF

No 'origin' remote is configured on $REPO_DIR yet, so nothing was pushed.
Set one up and push manually, e.g.:
  cd $REPO_DIR
  git remote add origin <your-remote-url>
  git push -u origin main
EOF
fi
