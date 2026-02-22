#!/bin/bash
# ETL-onprem pull agent v2
# Pull-based GitOps agent for bare-metal RHEL
# Følger GitHub releases (tags) - ikke rå commits

REPO_URL="${REPO_URL:-https://github.com/calamondino/etl-lab-gitops.git}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
RSYSLOG_CONF_DIR="${RSYSLOG_CONF_DIR:-/etc/rsyslog_etl}"
WORK_DIR="/opt/etl-agent"
LOG_PREFIX="[etl-agent $(hostname)]"

mkdir -p "$WORK_DIR" "$RSYSLOG_CONF_DIR"

log() { echo "$LOG_PREFIX $1"; }

# Sett opp git credentials
if [ -n "$GITHUB_TOKEN" ]; then
  git config --global credential.helper store
  echo "https://x-token:${GITHUB_TOKEN}@github.com" > ~/.git-credentials
fi

log "Starter ETL pull-agent v2"
log "Repo: $REPO_URL"
log "Poll-intervall: ${POLL_INTERVAL}s"

# Initial klone
if [ ! -d "$WORK_DIR/.git" ]; then
  log "Kloner repo..."
  git clone "$REPO_URL" "$WORK_DIR" || { log "FEIL: Kloning feilet"; exit 1; }
fi

LAST_TAG=""

while true; do
  log "Sjekker for ny release..."
  cd "$WORK_DIR"

  git fetch --tags origin 2>/dev/null

  # Finn siste tag
  CURRENT_TAG=$(git tag --sort=-version:refname | head -1)

  if [ -z "$CURRENT_TAG" ]; then
    log "Ingen tags funnet - bruker main branch"
    CURRENT_TAG=$(git rev-parse origin/main)
  fi

  if [ "$CURRENT_TAG" != "$LAST_TAG" ]; then
    log "Ny release funnet: $CURRENT_TAG (forrige: ${LAST_TAG:-ingen})"

    # Checkout riktig tag
    git checkout "$CURRENT_TAG" 2>/dev/null

    # Finn endrede config-filer
    if [ -z "$LAST_TAG" ]; then
      CHANGED_CONFIGS=$(find "$WORK_DIR/apps/onprem-agent/rsyslog" -name "*.conf" 2>/dev/null)
    else
      CHANGED_CONFIGS=$(git diff --name-only "$LAST_TAG" "$CURRENT_TAG" -- "apps/onprem-agent/rsyslog/" | grep "\.conf$" | sed "s|^|$WORK_DIR/|")
    fi

    if [ -n "$CHANGED_CONFIGS" ]; then
      for conf_file in $CHANGED_CONFIGS; do
        filename=$(basename "$conf_file")
        log "Behandler $filename..."

        # Valider config før deploy
        rsyslogd -N1 -f "$conf_file" 2>/dev/null
        if [ $? -ne 0 ]; then
          log "ADVARSEL: $filename feiler validering - skipper"
          continue
        fi

        # Deploy config
        cp "$conf_file" "$RSYSLOG_CONF_DIR/$filename"
        log "Deployet $filename til $RSYSLOG_CONF_DIR"

        # Restart tilhørende service
        service_name="${filename%.conf}"
        if systemctl is-active --quiet "${service_name}.service" 2>/dev/null; then
          log "Restarter ${service_name}.service..."
          systemctl restart "${service_name}.service" && log "OK" || log "FEIL ved restart"
        else
          log "Ingen aktiv service for $service_name"
        fi
      done
    else
      log "Ingen config-endringer i denne releasen"
    fi

    LAST_TAG="$CURRENT_TAG"
    log "Deploy fullfort for $CURRENT_TAG - venter ${POLL_INTERVAL}s"
  else
    log "Ingen ny release (siste: $CURRENT_TAG)"
  fi

  sleep "$POLL_INTERVAL"
done
