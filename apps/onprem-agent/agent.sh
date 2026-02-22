#!/bin/bash
# ETL-onprem pull agent v3
# Pull-based GitOps for bare-metal RHEL
# - Refresh: sjekker for ny release (hvert 30 sek)
# - Sync: deployer ved ny tag
# - Token: leses fra fil, ikke URL

REPO="${REPO:-https://github.com/calamondino/etl-lab-gitops.git}"
BRANCH="${BRANCH:-main}"
TOKEN_FILE="${TOKEN_FILE:-/etc/etl-agent/token}"
CONFIG_PATH="${CONFIG_PATH:-apps/onprem-agent/rsyslog}"
WORK_DIR="/opt/etl-agent"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
RSYSLOG_CONF_DIR="${RSYSLOG_CONF_DIR:-/etc/rsyslog_etl}"
STATUS_FILE="/var/run/etl-agent-status.json"

mkdir -p "$WORK_DIR" "$RSYSLOG_CONF_DIR" "$(dirname $STATUS_FILE)"

log() { echo "[etl-agent $(hostname)] $1"; }

update_status() {
  cat > "$STATUS_FILE" << JSON
{
  "hostname": "$(hostname)",
  "deployed_version": "${1:-ukjent}",
  "last_refresh": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_sync": "${2:-aldri}",
  "status": "${3:-unknown}"
}
JSON
}

# Les token fra fil
if [ ! -f "$TOKEN_FILE" ]; then
  log "FEIL: Token-fil ikke funnet: $TOKEN_FILE"
  log "Opprett med: echo 'TOKEN' > $TOKEN_FILE && chmod 600 $TOKEN_FILE"
  exit 1
fi
TOKEN=$(cat "$TOKEN_FILE")
REPO_WITH_AUTH=$(echo "$REPO" | sed "s|https://|https://x-token:${TOKEN}@|")

log "Starter ETL pull-agent v3"
log "Repo: $REPO"
log "Poll-intervall: ${POLL_INTERVAL}s"

# Initial klone
if [ ! -d "$WORK_DIR/.git" ]; then
  log "Kloner repo..."
  git clone "$REPO_WITH_AUTH" "$WORK_DIR" || { log "FEIL: Kloning feilet"; exit 1; }
fi

# Sett remote URL med auth (ikke synlig i git log)
cd "$WORK_DIR"
git remote set-url origin "$REPO_WITH_AUTH"

LAST_TAG=""
LAST_SYNC="aldri"

while true; do
  # === REFRESH ===
  log "Refresh: sjekker for ny release..."
  git fetch --tags origin 2>/dev/null
  CURRENT_TAG=$(git tag --sort=-version:refname | head -1)

  if [ -z "$CURRENT_TAG" ]; then
    log "Ingen tags funnet"
    update_status "ukjent" "$LAST_SYNC" "no_releases"
    sleep "$POLL_INTERVAL"
    continue
  fi

  update_status "$CURRENT_TAG" "$LAST_SYNC" "synced"

  if [ "$CURRENT_TAG" == "$LAST_TAG" ]; then
    log "Ingen ny release (siste: $CURRENT_TAG)"
    sleep "$POLL_INTERVAL"
    continue
  fi

  # === SYNC ===
  log "Sync: ny release funnet: $CURRENT_TAG (forrige: ${LAST_TAG:-ingen})"
  git checkout "$CURRENT_TAG" 2>/dev/null

  # Finn endrede config-filer
  if [ -z "$LAST_TAG" ]; then
    CHANGED=$(find "$WORK_DIR/$CONFIG_PATH" -name "*.conf" 2>/dev/null)
  else
    CHANGED=$(git diff --name-only "$LAST_TAG" "$CURRENT_TAG" -- "$CONFIG_PATH/" | grep "\.conf$" | sed "s|^|$WORK_DIR/|")
  fi

  if [ -z "$CHANGED" ]; then
    log "Ingen config-endringer i $CURRENT_TAG"
    LAST_TAG="$CURRENT_TAG"
    sleep "$POLL_INTERVAL"
    continue
  fi

  SYNC_OK=true
  for conf_file in $CHANGED; do
    filename=$(basename "$conf_file")
    log "Validerer $filename..."

    rsyslogd -N1 -f "$conf_file" 2>/dev/null
    if [ $? -ne 0 ]; then
      log "FEIL: $filename feiler validering - skipper"
      SYNC_OK=false
      continue
    fi

    cp "$conf_file" "$RSYSLOG_CONF_DIR/$filename"
    log "Deployet $filename"

    service_name="${filename%.conf}"
    if systemctl is-active --quiet "${service_name}.service" 2>/dev/null; then
      systemctl restart "${service_name}.service" && log "Restartet ${service_name}.service" || log "FEIL ved restart"
    else
      log "Ingen aktiv service for $service_name"
    fi
  done

  LAST_SYNC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if $SYNC_OK; then
    update_status "$CURRENT_TAG" "$LAST_SYNC" "synced"
    log "Sync OK: $CURRENT_TAG"
  else
    update_status "$CURRENT_TAG" "$LAST_SYNC" "sync_failed"
    log "Sync FEIL: en eller flere configs feilet validering"
  fi

  LAST_TAG="$CURRENT_TAG"
  log "Ferdig - venter ${POLL_INTERVAL}s"
  sleep "$POLL_INTERVAL"
done
