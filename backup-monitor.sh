#!/usr/bin/env bash
# ==============================================================================
#  cPanel Backup Monitor v1.1
#  Author : Eng. Samir Abou El Khair
#
#  Checks, by itself and without manual steps:
#    1. cPanel internal backup  (latest dated folder, age, accounts, disk use)
#    2. JetBackup 5             (runs in the last N hours: completed/partial/failed)
#    3. External copy           (connects over SSH to the remote server and checks
#                                that the newest file is recent - real proof that
#                                the offsite copy arrived)
#  Then sends ONE report to Email (SMTP/sendmail) + Telegram + Slack.
#
#  Usage:
#    backup-monitor.sh              run the checks and send the report
#    backup-monitor.sh --dry-run    run the checks, print the report, send nothing
#    backup-monitor.sh --test       send a test message to all enabled channels
#    backup-monitor.sh --debug-jb   print raw JetBackup API output (for tuning)
#    backup-monitor.sh --help
#
#  Secrets live in backup-monitor.conf (never commit it - see .gitignore).
#  Exit code: 0 = OK, 1 = WARN, 2 = FAIL
# ==============================================================================

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/cpanel/bin:$PATH

VERSION="1.1"
AUTHOR="Eng. Samir Abou El Khair"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${BM_CONF:-${SCRIPT_DIR}/backup-monitor.conf}"
HOSTNAME_FQDN="$(/usr/bin/hostname -f 2>/dev/null || /usr/bin/hostname)"

# ----------------------------- defaults ---------------------------------------
LOG_FILE="/var/log/cpanel-backup-monitor.log"
NOTIFY_ON="always"                 # always | problem (send only on WARN/FAIL)

CPANEL_BACKUP_DIR="/backup"
CPANEL_USERS_DIR="/var/cpanel/users"
CP_MAX_AGE_H=30                    # older than this -> WARN (2x -> FAIL)
DISK_WARN_PCT=85
DISK_FAIL_PCT=95

JB_ENABLED="yes"
JB_WINDOW_H=26
JB_QUEUE_TYPE=1                    # JetBackup queue type 1 = backups
# JetBackup queue status codes (100 = completed, 101 = partially completed: confirmed).
# The failed codes are a guess; verify on your server with: --debug-jb
# Any code not listed here is reported as WARN ("unknown status"), never as OK.
JB_ST_COMPLETED="100"
JB_ST_PARTIAL="101"
JB_ST_RUNNING="1 2 3"
JB_ST_FAILED="102 200 201"

EXT_VERIFY="no"
EXT_SSH_HOST=""
EXT_SSH_USER=""
EXT_SSH_PORT=22
EXT_SSH_KEY="/root/.ssh/id_rsa"
EXT_PATH=""                        # backup directory of the destination (remote path)
EXT_MAX_AGE_H=30                   # newest remote file older than this -> WARN (2x -> FAIL)

EMAIL_ENABLED="no"
EMAIL_METHOD="smtp"                # smtp | sendmail
EMAIL_TO=""
EMAIL_FROM="backup-monitor@${HOSTNAME_FQDN}"   # sendmail mode only
SMTP_HOST="smtp.gmail.com"; SMTP_PORT=465
SMTP_USER=""; SMTP_PASS=""

TELEGRAM_ENABLED="no"
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""                # empty = auto-detected after pressing Start on the bot

SLACK_ENABLED="no"
SLACK_WEBHOOK_URL=""

# ----------------------------- load config ------------------------------------
if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi

touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/cpanel-backup-monitor.log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

if [[ -f "$CONF" ]]; then
  perm="$(stat -c %a "$CONF" 2>/dev/null)"
  [[ "$perm" == "600" || "$perm" == "400" ]] || log "WARNING: ${CONF} permissions are ${perm}, run: chmod 600 ${CONF}"
else
  log "WARNING: config file not found (${CONF}) - using defaults, notifications are disabled"
fi

# ----------------------------- helpers ----------------------------------------
LEVEL=0; REPORT=""; SUBJECT=""; BODY=""
raise() { (( $1 > LEVEL )) && LEVEL=$1; }
add()   { REPORT+="$*"$'\n'; }
icon()  { case "$1" in 0) echo "✅";; 1) echo "⚠️";; *) echo "❌";; esac; }
lname() { case "$1" in 0) echo "OK";; 1) echo "WARN";; *) echo "FAIL";; esac; }

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g' \
    | awk '{printf "%s\\n", $0}'
}

# ----------------------------- check 1: cPanel --------------------------------
cp_count()  { find "$1/accounts" -mindepth 1 -maxdepth 1 \( -name '*.tar.gz' -o -name '*.tar' -o -type d \) 2>/dev/null | wc -l; }
cp_newest() { local n; n=$(find "$1" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1); echo "${n%.*}"; }

check_cpanel() {
  local lvl=0 sec="" now age_h total backed=0 pct use dests newest="" latest="" inprog="" d b n
  local dirs=()
  now=$(date +%s)

  if [[ ! -d "$CPANEL_BACKUP_DIR" ]]; then
    add "$(icon 2) cPanel internal backup : FAIL"
    add "Problem   : ${CPANEL_BACKUP_DIR} not found"; add ""; raise 2; return
  fi

  total=$(ls -1 "$CPANEL_USERS_DIR" 2>/dev/null | grep -Evc '^(root|nobody|cpanel|system|cpanelphpmyadmin|cpanelphppgadmin|cpanelroundcube|cpses)$')

  mapfile -t dirs < <(find "$CPANEL_BACKUP_DIR" -maxdepth 1 -type d -name '20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]' 2>/dev/null | sort -r)
  for d in "${dirs[@]}"; do
    b=$(cp_count "$d"); n=$(cp_newest "$d")
    # newest folder still being written (files changed < 1h ago, not all accounts yet) = backup running now
    if [[ -z "$latest" && -z "$inprog" && -n "$n" ]] && (( b < total && now - n < 3600 )); then
      inprog="${d##*/} : ${b}/${total} accounts so far (backup is running now)"
      continue
    fi
    latest="$d"; backed=$b; newest=$n; break
  done

  if [[ -z "$latest" ]]; then
    lvl=2; [[ -n "$inprog" ]] && lvl=1
    add "$(icon $lvl) cPanel internal backup : $(lname $lvl)"
    add "Problem   : no completed backup folder found in ${CPANEL_BACKUP_DIR}"
    [[ -n "$inprog" ]] && add "Running   : ${inprog}"
    add ""; raise $lvl; return
  fi

  sec+="Folder    : ${latest}"$'\n'
  if [[ -z "$newest" ]]; then
    lvl=2; sec+="Problem   : backup folder is empty"$'\n'
  else
    age_h=$(( (now - newest) / 3600 ))
    sec+="Last file : ${age_h}h ago"$'\n'
    if   (( age_h > CP_MAX_AGE_H * 2 )); then lvl=2; sec+="Problem   : last backup file is older than $((CP_MAX_AGE_H*2))h"$'\n'
    elif (( age_h > CP_MAX_AGE_H ));     then (( lvl < 1 )) && lvl=1; sec+="Warning   : last backup file is older than ${CP_MAX_AGE_H}h"$'\n'
    fi
  fi

  if (( total > 0 )); then pct=$(( backed * 100 / total )); else pct=100; fi
  sec+="Accounts  : ${backed} backed up / ${total} on server (${pct}%)"$'\n'
  if   (( pct < 90 )); then lvl=2; sec+="Problem   : less than 90% of accounts were backed up"$'\n'
  elif (( backed < total )); then (( lvl < 1 )) && lvl=1; sec+="Warning   : $((total - backed)) account(s) missing from the backup"$'\n'
  fi
  [[ -n "$inprog" ]] && sec+="Running   : ${inprog}"$'\n'

  use=$(df --output=pcent "$CPANEL_BACKUP_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [[ -n "$use" ]]; then
    sec+="Disk use  : ${use}% on the backup partition"$'\n'
    if   (( use >= DISK_FAIL_PCT )); then lvl=2; sec+="Problem   : backup partition almost full"$'\n'
    elif (( use >= DISK_WARN_PCT )); then (( lvl < 1 )) && lvl=1; sec+="Warning   : backup partition above ${DISK_WARN_PCT}%"$'\n'
    fi
  fi

  dests=$(whmapi1 backup_destination_list 2>/dev/null | grep -c 'disabled: 0')
  sec+="Remote destinations (cPanel) : ${dests} enabled"$'\n'

  add "$(icon $lvl) cPanel internal backup : $(lname $lvl)"
  add "${sec%$'\n'}"; add ""; raise $lvl
}

# ----------------------------- check 2: JetBackup -----------------------------
# Output: first line  S|jobs|completed|partial|running|failed|other|lastend|unknown-codes
#         then one line per job (latest run inside the window):
#         G|class|job name|status|items done|items|ended-ts|log file
jb_parse() {
python3 -c '
import sys, json, time, calendar
win, c, p, r, f = sys.argv[1:6]
sets = [("C", set(c.split())), ("P", set(p.split())), ("R", set(r.split())), ("F", set(f.split()))]
def ts(v):
    if v in (None, ""): return 0
    try: return float(v)
    except Exception: pass
    s = str(v); off = 0
    try:
        if len(s) >= 25 and s[-6] in "+-" and s[-3] == ":":
            off = (int(s[-5:-3]) * 3600 + int(s[-2:]) * 60) * (1 if s[-6] == "+" else -1); s = s[:-6]
        elif s.endswith("Z"): s = s[:-1]
        return calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S")) - off
    except Exception: return 0
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("ERR not-json"); sys.exit(0)
if d.get("success") not in (1, True, "1"):
    print("ERR api: " + str(d.get("message", ""))[:80].replace("|", "/")); sys.exit(0)
groups = (d.get("data") or {}).get("groups") or []
if isinstance(groups, dict): groups = list(groups.values())
lim = time.time() - int(win) * 3600
latest = {}; last = 0; unk = set()
for g in groups:
    if not isinstance(g, dict): continue
    t = max(ts(g.get(k)) for k in ("created", "started", "ended", "updated"))
    if t < lim: continue
    gd = g.get("data") if isinstance(g.get("data"), dict) else {}
    nm = str(gd.get("name") or g.get("description") or "job").replace("|", "/")
    st = str(g.get("status")); cls = "O"
    for k, s in sets:
        if st in s: cls = k; break
    e = ts(g.get("ended")); last = max(last, e)
    if nm not in latest or t >= latest[nm][0]:
        latest[nm] = (t, cls, st, g.get("items_completed", 0), g.get("items", 0), int(e), str(g.get("log_file", "")).replace("|", "/"))
cnt = {"C": 0, "P": 0, "R": 0, "F": 0, "O": 0}
for nm, v in latest.items():
    cnt[v[1]] += 1
    if v[1] == "O": unk.add(v[2])
print("S|%d|%d|%d|%d|%d|%d|%d|%s" % (len(latest), cnt["C"], cnt["P"], cnt["R"], cnt["F"], cnt["O"], int(last), ",".join(sorted(unk)) or "-"))
for nm, v in sorted(latest.items(), key=lambda x: x[1][0]):
    print("G|%s|%s|%s|%s|%s|%d|%s" % (v[1], nm, v[2], v[3], v[4], v[5], v[6]))
' "$@"
}

check_jetbackup() {
  [[ "$JB_ENABLED" == "yes" ]] || return 0
  local api raw out first lvl=0 sec="" now age_h label when logs
  local total completed partial running failed other lastend unk
  local cls name st dn items endts lf
  api="$(command -v jetbackup5api || true)"
  if [[ -z "$api" ]]; then
    add "$(icon 1) JetBackup : WARN"; add "Warning   : jetbackup5api not found"; add ""; raise 1; return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    add "$(icon 1) JetBackup : WARN"; add "Warning   : python3 not found (needed to read the API output)"; add ""; raise 1; return
  fi

  raw="$("$api" -F listQueueGroups -O json -D "type=${JB_QUEUE_TYPE}" 2>&1)"
  out="$(printf '%s' "$raw" | jb_parse "$JB_WINDOW_H" "$JB_ST_COMPLETED" "$JB_ST_PARTIAL" "$JB_ST_RUNNING" "$JB_ST_FAILED" 2>&1)"
  first="$(printf '%s\n' "$out" | head -1)"
  if [[ "$first" != S\|* ]]; then
    add "$(icon 1) JetBackup : WARN"
    add "Warning   : could not read JetBackup status (${first}) - run: $0 --debug-jb"
    add ""; raise 1; return
  fi
  IFS='|' read -r _ total completed partial running failed other lastend unk <<< "$first"

  now=$(date +%s)
  sec+="Backup jobs : last ${JB_WINDOW_H}h -> ${total} job(s) | ${completed} completed | ${partial} partial | ${running} running | ${failed} failed"$'\n'
  while IFS='|' read -r _ cls name st dn items endts lf; do
    case "$cls" in C) label="completed";; P) label="partial";; R) label="running";; F) label="FAILED";; *) label="unknown status ${st}";; esac
    if (( endts > 0 )); then when="finished $(( (now - endts) / 3600 ))h ago"; else when="not finished yet"; fi
    sec+="  ${name} : ${label} (${dn}/${items} items) - ${when}"$'\n'
    if [[ "$cls" == "P" || "$cls" == "F" || "$cls" == "O" ]] && [[ -r "$lf" ]]; then
      logs="$(grep -iE 'warn|error|fail|partial' "$lf" 2>/dev/null | tail -3 | cut -c1-160)"
      [[ -n "$logs" ]] && sec+="$(printf '%s\n' "$logs" | sed 's/^/      log: /')"$'\n'
    fi
  done < <(printf '%s\n' "$out" | grep '^G|')
  if (( lastend > 0 )); then age_h=$(( (now - lastend) / 3600 )); sec+="Last finish : ${age_h}h ago"$'\n'; fi

  if   (( total == 0 )); then lvl=1; sec+="Warning   : no JetBackup runs in the last ${JB_WINDOW_H}h"$'\n'
  elif (( failed > 0 )); then lvl=2; sec+="Problem   : ${failed} failed job(s)"$'\n'
  fi
  if (( partial > 0 )); then (( lvl < 1 )) && lvl=1; sec+="Warning   : ${partial} partially completed job(s)"$'\n'; fi
  if (( other > 0 ));   then (( lvl < 1 )) && lvl=1; sec+="Warning   : ${other} job(s) with unknown status code(s): ${unk} (adjust JB_ST_* in the config)"$'\n'; fi

  add "$(icon $lvl) JetBackup : $(lname $lvl)"
  add "${sec%$'\n'}"; add ""; raise $lvl
}

# ----------------------------- check 3: external copy over SSH ----------------
check_external() {
  [[ "$EXT_VERIFY" == "yes" ]] || return 0
  local lvl=0 sec="" out errf newest recent now age_h
  if [[ -z "$EXT_SSH_HOST" || -z "$EXT_SSH_USER" || -z "$EXT_PATH" ]]; then
    add "$(icon 1) External copy : WARN"; add "Warning   : EXT_SSH_HOST / EXT_SSH_USER / EXT_PATH not set"; add ""; raise 1; return
  fi

  errf="$(mktemp)"
  out="$(ssh -i "$EXT_SSH_KEY" -p "$EXT_SSH_PORT" \
        -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new \
        "${EXT_SSH_USER}@${EXT_SSH_HOST}" 'bash -s' 2>"$errf" <<EOF
[ -d "$EXT_PATH" ] || { echo NODIR; exit 0; }
echo "NEWEST \$(find "$EXT_PATH" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
echo "RECENT \$(find "$EXT_PATH" -type f -mmin -$((EXT_MAX_AGE_H * 60)) 2>/dev/null | wc -l)"
EOF
  )"

  if [[ -z "$out" ]]; then
    lvl=2; sec+="Problem   : SSH to ${EXT_SSH_HOST} failed - $(head -c 160 "$errf" | tr '\n' ' ')"$'\n'
  elif [[ "$out" == *NODIR* ]]; then
    lvl=2; sec+="Problem   : remote path ${EXT_PATH} does not exist on ${EXT_SSH_HOST}"$'\n'
  else
    newest="$(printf '%s\n' "$out" | awk '$1=="NEWEST"{print $2}')"; newest="${newest%.*}"
    recent="$(printf '%s\n' "$out" | awk '$1=="RECENT"{print $2}')"
    if [[ ! "$newest" =~ ^[0-9]+$ ]]; then
      lvl=2; sec+="Problem   : connected to ${EXT_SSH_HOST} but no files found in ${EXT_PATH}"$'\n'
    else
      now=$(date +%s); age_h=$(( (now - newest) / 3600 ))
      sec+="Verified over SSH on ${EXT_SSH_HOST}:${EXT_PATH}"$'\n'
      sec+="Newest file : ${age_h}h old | files written in the last ${EXT_MAX_AGE_H}h : ${recent:-0}"$'\n'
      if   (( age_h > EXT_MAX_AGE_H * 2 )); then lvl=2; sec+="Problem   : external copy is stale (older than $((EXT_MAX_AGE_H*2))h)"$'\n'
      elif (( age_h > EXT_MAX_AGE_H ));     then lvl=1; sec+="Warning   : external copy is older than ${EXT_MAX_AGE_H}h"$'\n'
      fi
    fi
  fi
  rm -f "$errf"

  add "$(icon $lvl) External copy (direct check) : $(lname $lvl)"
  add "${sec%$'\n'}"; add ""; raise $lvl
}

# ----------------------------- notifications ----------------------------------
send_email() {
  [[ "$EMAIL_ENABLED" == "yes" && -n "$EMAIL_TO" ]] || return 0
  local msg from subj_b64 out a arr rcpt=() extra=() url
  msg="$(mktemp)"
  from="$EMAIL_FROM"; [[ "$EMAIL_METHOD" == "smtp" ]] && from="$SMTP_USER"
  subj_b64="$(printf '%s' "$SUBJECT" | base64 -w0)"
  {
    echo "From: Backup Monitor <${from}>"
    echo "To: ${EMAIL_TO}"
    echo "Subject: =?UTF-8?B?${subj_b64}?="
    echo "Date: $(date -R)"
    echo "MIME-Version: 1.0"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo "Content-Transfer-Encoding: 8bit"
    echo
    printf '%s\n' "$BODY"
  } > "$msg"

  if [[ "$EMAIL_METHOD" == "smtp" ]]; then
    if [[ -z "$SMTP_USER" || -z "$SMTP_PASS" ]]; then log "Email: SMTP_USER/SMTP_PASS not set - skipped"; rm -f "$msg"; return 0; fi
    url="smtps://${SMTP_HOST}:${SMTP_PORT}"
    if [[ "$SMTP_PORT" != "465" ]]; then url="smtp://${SMTP_HOST}:${SMTP_PORT}"; extra=(--ssl-reqd); fi
    IFS=',' read -ra arr <<< "$EMAIL_TO"
    for a in "${arr[@]}"; do a="${a// /}"; [[ -n "$a" ]] && rcpt+=(--mail-rcpt "$a"); done
    out=$(curl -sS -m 60 ${extra[@]+"${extra[@]}"} --url "$url" \
          --user "${SMTP_USER}:${SMTP_PASS}" --mail-from "$SMTP_USER" \
          "${rcpt[@]}" -T "$msg" 2>&1) \
      && log "Email(SMTP): sent to ${EMAIL_TO}" || log "Email(SMTP): FAILED - ${out}"
  else
    local sm; sm="$(command -v sendmail || echo /usr/sbin/sendmail)"
    if [[ ! -x "$sm" ]]; then log "Email: sendmail not found"; rm -f "$msg"; return 1; fi
    "$sm" -t -oi < "$msg" && log "Email: sent to ${EMAIL_TO}" || log "Email: FAILED"
  fi
  rm -f "$msg"
}

resolve_telegram_chat_id() {
  local f="${SCRIPT_DIR}/.telegram_chat_id" id
  [[ -n "$TELEGRAM_CHAT_ID" ]] && return 0
  if [[ -s "$f" ]]; then TELEGRAM_CHAT_ID="$(cat "$f")"; return 0; fi
  id=$(curl -sS -m 30 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" 2>/dev/null \
       | grep -o '"chat":{"id":-\?[0-9]*' | head -1 | grep -o -- '-\?[0-9]*$')
  if [[ -n "$id" ]]; then
    TELEGRAM_CHAT_ID="$id"; echo "$id" > "$f" 2>/dev/null
    log "Telegram: chat id auto-detected ($id)"
  fi
}

send_telegram() {
  [[ "$TELEGRAM_ENABLED" == "yes" && -n "$TELEGRAM_BOT_TOKEN" ]] || return 0
  resolve_telegram_chat_id
  if [[ -z "$TELEGRAM_CHAT_ID" ]]; then
    log "Telegram: no chat id yet - open the bot in Telegram and press Start, then run again"; return 1
  fi
  local text resp
  text="${SUBJECT}"$'\n\n'"${BODY}"; text="${text:0:3900}"
  resp=$(curl -sS -m 30 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
         -d chat_id="$TELEGRAM_CHAT_ID" --data-urlencode "text=${text}" 2>&1)
  if echo "$resp" | grep -q '"ok":true'; then log "Telegram: sent"; else log "Telegram: FAILED - $resp"; fi
}

send_slack() {
  [[ "$SLACK_ENABLED" == "yes" && -n "$SLACK_WEBHOOK_URL" ]] || return 0
  local payload resp
  payload="{\"text\":\"$(json_escape "${SUBJECT}"$'\n\n'"${BODY}")\"}"
  resp=$(curl -sS -m 30 -X POST -H 'Content-Type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL" 2>&1)
  if [[ "$resp" == "ok" ]]; then log "Slack: sent"; else log "Slack: FAILED - $resp"; fi
}

notify_all() { send_email; send_telegram; send_slack; }

# ----------------------------- main -------------------------------------------
usage() { sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; }

LOCK="/var/run/backup-monitor.lock"
if ( : > "$LOCK" ) 2>/dev/null; then
  exec 9>"$LOCK"
  flock -n 9 || { echo "Another run is in progress - exiting"; exit 0; }
fi

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --test)
    SUBJECT="[TEST] Backup Monitor - ${HOSTNAME_FQDN}"
    BODY="This is a test notification from cPanel Backup Monitor v${VERSION} ✅"
    notify_all
    echo "Test notification sent. Check ${LOG_FILE} for details."
    exit 0 ;;
  --debug-jb)
    command -v jetbackup5api >/dev/null 2>&1 || { echo "jetbackup5api not found"; exit 1; }
    jetbackup5api -F listQueueGroups -O json -D "type=${JB_QUEUE_TYPE}" 2>&1 | head -c 6000; echo
    exit 0 ;;
  ""|--dry-run) ;;
  *) echo "Unknown option: $1"; usage; exit 1 ;;
esac

log "Run started (v${VERSION}) on ${HOSTNAME_FQDN}"
check_cpanel
check_jetbackup
check_external

SUBJECT="[$(lname $LEVEL)] Backup report - ${HOSTNAME_FQDN}"
BODY="$(icon $LEVEL) Backup Report - ${HOSTNAME_FQDN}"$'\n'
BODY+="Date    : $(date '+%F %T %Z')"$'\n'
BODY+="Overall : $(lname $LEVEL)"$'\n\n'
BODY+="${REPORT}"$'\n'
BODY+="-- cPanel Backup Monitor v${VERSION} | ${AUTHOR}"

log "Overall: $(lname $LEVEL)"

if [[ "${1:-}" == "--dry-run" ]]; then
  echo; echo "$SUBJECT"; echo "$BODY"; exit "$LEVEL"
fi

if [[ "$NOTIFY_ON" == "problem" && $LEVEL -eq 0 ]]; then
  log "Everything OK and NOTIFY_ON=problem - no notification sent"
else
  notify_all
fi
exit "$LEVEL"
