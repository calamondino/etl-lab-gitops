#!/bin/bash
# ETL-onprem pull agent
# Poller Gitea og oppdaterer rsyslog-config ved endringer

REPO_URL="${GITEA_REPO_URL:-http://gitea:3000/phong/etl-lab-gitops.git}"
BRANCH="${BRANCH:-main}"
CONFIG_PATH="${CONFIG_PATH:-apps/onprem-agent/rsyslog}"
WORK_DIR="/opt/etl-agent"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

mkdir -p "$WORK_DIR"

echo "[agent] Starter ETL pull-agent"
echo "[agent] Repo: $REPO_URL"
echo "[agent] Poll-intervall: ${POLL_INTERVAL}s"

# Initial klone
if [ ! -d "$WORK_DIR/.git" ]; then
  echo "[agent] Kloner repo..."
  git clone "$REPO_URL" "$WORK_DIR"
fi

LAST_COMMIT=""

while true; do
  echo "[agent] Sjekker for endringer..."
  cd "$WORK_DIR"

  git fetch origin "$BRANCH" 2>/dev/null
  CURRENT_COMMIT=$(git rev-parse "origin/$BRANCH")

  if [ "$CURRENT_COMMIT" != "$LAST_COMMIT" ]; then
    echo "[agent] Ny commit funnet: $CURRENT_COMMIT"
    git pull origin "$BRANCH"

    # Kopier rsyslog-config
    if [ -f "$WORK_DIR/$CONFIG_PATH/rsyslog.conf" ]; then
      echo "[agent] Oppdaterer rsyslog.conf..."
      cp "$WORK_DIR/$CONFIG_PATH/rsyslog.conf" /etc/rsyslog.conf

      # Restart rsyslog
      echo "[agent] Restarter rsyslog..."
      pkill rsyslogd && sleep 1 && rsyslogd
      echo "[agent] rsyslog restartet OK"
    fi

    LAST_COMMIT="$CURRENT_COMMIT"
    echo "[agent] Ferdig - venter ${POLL_INTERVAL}s"
  else
    echo "[agent] Ingen endringer"
  fi

  sleep "$POLL_INTERVAL"
done
