#!/usr/bin/env bash
# ==============================================================================
#  cPanel Backup Monitor - installer + auto-updater (pulls everything from GitHub)
#  Author : Eng. Samir Abou El Khair
#
#  First time on a server (one command):
#     GH_TOKEN=github_pat_xxx bash install.sh
#  After that the server updates itself daily (cron) using the saved token.
#
#  Repo layout (private repo):
#     backup-monitor.sh
#     install.sh
#     config/<fqdn-of-server>.conf    (optional, per server)
#     config/default.conf             (used when there is no per-server file)
# ==============================================================================
REPO="Samirlinux/whm"
BRANCH="main"
DIR="/opt/backup-monitor"
TOKEN_FILE="/root/.backup-monitor-token"
LOG="/var/log/backup-monitor-update.log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

if [[ -z "${GH_TOKEN:-}" && -s "$TOKEN_FILE" ]]; then GH_TOKEN="$(cat "$TOKEN_FILE")"; fi
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN is required: GH_TOKEN=xxx bash install.sh"; exit 1; }

mkdir -p "$DIR"

get() {   # get <repo path> <local file>
  curl -fsSL -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github.raw" \
       -o "$2.new" "https://api.github.com/repos/${REPO}/contents/$1?ref=${BRANCH}" 2>/dev/null \
    && [[ -s "$2.new" ]] && mv -f "$2.new" "$2" || { rm -f "$2.new"; return 1; }
}

# save the token for the daily self-update (readable by root only)
umask 077
printf '%s' "$GH_TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"

get backup-monitor.sh "$DIR/backup-monitor.sh" || { log "FAILED to download backup-monitor.sh (check token/repo path)"; exit 1; }
chmod +x "$DIR/backup-monitor.sh"
get install.sh "$DIR/install.sh" && chmod +x "$DIR/install.sh"

FQDN="$(hostname -f 2>/dev/null || hostname)"
if get "config/${FQDN}.conf" "$DIR/backup-monitor.conf"; then
  log "Config: config/${FQDN}.conf"
elif get "config/default.conf" "$DIR/backup-monitor.conf"; then
  log "Config: config/default.conf"
else
  log "WARNING: no config found in the repo (config/${FQDN}.conf or config/default.conf)"
fi
[[ -f "$DIR/backup-monitor.conf" ]] && chmod 600 "$DIR/backup-monitor.conf"

# cron: report at 08:00, self-update at 07:50. Old backup-monitor lines are replaced.
( crontab -l 2>/dev/null | grep -v 'backup-monitor'
  echo "50 7 * * * bash ${DIR}/install.sh >> ${LOG} 2>&1"
  echo "0 8 * * * ${DIR}/backup-monitor.sh >> /var/log/backup-monitor-cron.log 2>&1"
) | crontab -

log "Installed/updated OK on ${FQDN}"
head -4 "$DIR/backup-monitor.sh" | tail -2
