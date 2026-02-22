#!/bin/bash
# ETL-onprem pull agent
# Poller GitHub og oppdaterer rsyslog-configs ved endringer

REPO_URL="${GITEA_REPO_URL:-https://github.com/calamondino/etl-lab-gitops.git}"
BRANCH="${BRANCH:-main}"
CONFIG_PATH="${CONFIG_PATH:-apps/onprem-agent/rsyslog}"
WORK_DIR="/opt/etl-agent"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
RSYSLOG_CONF_DIR="${RSYSLOG_CONF_DIR:-/etc/rsyslog_etl}"

mkdir -p "$WORK_DIR" "$RSYSLOG_CONF_DIR"

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

    # Finn endrede .conf-filer i CONFIG_PATH
    if [ -z "$LAST_COMMIT" ]; then
      CHANGED_FILES=$(ls "$WORK_DIR/$CONFIG_PATH"/*.conf 2>/dev/null)
    else
      CHANGED_FILES=$(git diff --name-only "$LAST_COMMIT" "$CURRENT_COMMIT" -- "$CONFIG_PATH/" | grep "\.conf$" | sed "s|^|$WORK_DIR/|")
    fi

    if [ -n "$CHANGED_FILES" ]; then
      for conf_file in $CHANGED_FILES; do
        filename=$(basename "$conf_file")
        echo "[agent] Oppdaterer $filename..."
        cp "$conf_file" "$RSYSLOG_CONF_DIR/$filename"

        # Finn og restart tilhørende service
        # Konvensjon: rsyslog_etl_dhcp.conf -> rsyslog_etl_dhcp.service
        service_name="${filename%.conf}"
        if systemctl is-active --quiet "${service_name}.service" 2>/dev/null; then
          echo "[agent] Restarter ${service_name}.service..."
          systemctl restart "${service_name}.service"
          echo "[agent] ${service_name}.service restartet OK"
        else
          echo "[agent] Ingen aktiv service for $filename, skipper restart"
        fi
      done
    else
      echo "[agent] Ingen config-endringer"
    fi

    LAST_COMMIT="$CURRENT_COMMIT"
    echo "[agent] Ferdig - venter ${POLL_INTERVAL}s"
  else
    echo "[agent] Ingen endringer"
  fi

  sleep "$POLL_INTERVAL"
done
