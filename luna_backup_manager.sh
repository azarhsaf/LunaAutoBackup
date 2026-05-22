#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.0"
DEFAULT_CONFIG="/etc/luna-backup/luna_backup.conf"
CONFIG_FILE="${LUNA_BACKUP_CONFIG:-$DEFAULT_CONFIG}"
MANAGED_CRON_BEGIN="# BEGIN LUNA-BACKUP MANAGED"
MANAGED_CRON_END="# END LUNA-BACKUP MANAGED"
EXIT_GENERAL=1
EXIT_PRECHECK=2
EXIT_CONFIG=3
EXIT_LUNACM=4
EXIT_LOCKED=5
EXIT_SCHEDULE=6
EXIT_PERMS=7
EXIT_STM_OR_INIT=8
EXIT_PED_TIMEOUT=9

# Default values overwritten by config
LUNACM_BIN="/usr/safenet/lunaclient/bin/lunacm"
MODE="client_usb"
MIN_CLIENT_VERSION="10.3.0"
SOURCE_TYPE="partition"
SOURCE_PARTITION_LABEL=""
SOURCE_SLOT=""
SOURCE_HA_GROUP_LABEL=""
SOURCE_HSM_HOST=""
BACKUP_HSM_SLOT=""
BACKUP_ARCHIVE_NAME=""
BACKUP_DOMAIN_REFERENCE=""
RETENTION_COUNT="7"
COMMAND_TIMEOUT_SECONDS="300"
LOG_DIR="/var/log/luna-backup"
STATE_DIR="/var/lib/luna-backup"
LOCK_FILE="/var/lock/luna-backup.lock"
EMAIL_ENABLED="false"
EMAIL_TO=""
SCHEDULE_TYPE="cron"
CRON_EXPRESSION="0 2 * * *"
REQUIRE_PED="true"
DRY_RUN_DEFAULT="false"
BACKUP_WINDOW=""
REPORT_HOOK=""
SYSTEMD_TIMER_NAME="luna-backup.timer"
SERVICE_USER="luna-backup"

RUNTIME_WARNINGS=()

usage() {
  cat <<USAGE
Usage: $0 <command> [options]
Commands:
  setup
  precheck
  backup [--dry-run] [--skip-precheck] [--non-interactive]
  schedule
  status
  list
  verify
  restore-guide
  stm-guide
  init-guide [--dangerous-allow-init]
  validate-config
USAGE
}

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log_msg() {
  local level="$1"; shift
  local msg="$*"
  mkdir -p "$LOG_DIR" "$STATE_DIR" "$STATE_DIR/reports"
  local line="$(ts) level=$level user=$(id -un) host=$(hostname -s) msg=$(printf '%s' "$msg" | tr '\n' ' ' )"
  echo "$line" | tee -a "$LOG_DIR/luna-backup.log" >/dev/null
  logger -t luna-backup "[$level] $msg" || true
}

sanitize_output() {
  sed -E 's/([Pp][Ii][Nn]|[Pp]assword|[Ss]ecret|[Tt]oken)[^[:space:]]*/\1=***REDACTED***/g'
}

version_ge() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  fi
}

validate_config() {
  load_config
  local missing=0
  local required=(LUNACM_BIN MODE MIN_CLIENT_VERSION SOURCE_TYPE BACKUP_HSM_SLOT BACKUP_ARCHIVE_NAME LOG_DIR STATE_DIR LOCK_FILE COMMAND_TIMEOUT_SECONDS)
  for key in "${required[@]}"; do
    if [ -z "${!key:-}" ]; then
      echo "Missing required config: $key"
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then exit "$EXIT_CONFIG"; fi
  if [ -f "$CONFIG_FILE" ]; then
    local perms
    perms=$(stat -c '%a' "$CONFIG_FILE")
    if [ "$perms" != "600" ]; then
      echo "Unsafe config permissions ($perms), expected 600"
      exit "$EXIT_PERMS"
    fi
  fi
  echo "Config validation successful for $CONFIG_FILE"
}

run_lunacm_commands() {
  local cmd_text="$1"
  local out_file
  out_file=$(mktemp)
  local cmd_file
  cmd_file=$(mktemp)
  chmod 600 "$cmd_file" "$out_file"
  printf "%s\n" "$cmd_text" > "$cmd_file"

  set +e
  timeout "$COMMAND_TIMEOUT_SECONDS" "$LUNACM_BIN" < "$cmd_file" > "$out_file" 2>&1
  local rc=$?
  set -e

  sanitize_output < "$out_file"
  rm -f "$cmd_file" "$out_file"

  if [ "$rc" -eq 124 ]; then
    RUNTIME_WARNINGS+=("LunaCM command timeout (possible PED wait)")
    return "$EXIT_PED_TIMEOUT"
  fi
  return "$rc"
}

get_lunacm_version() {
  local out
  out=$(run_lunacm_commands "version" || true)
  echo "$out" | awk '/Client Version|LunaCM/{print $NF; exit}'
}

precheck() {
  load_config
  log_msg INFO "Starting precheck"
  [ "$(uname -s)" = "Linux" ] || { echo "Linux required"; exit "$EXIT_PRECHECK"; }
  [ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "Bash >=4 required"; exit "$EXIT_PRECHECK"; }

  for t in awk sed grep timeout logger date flock; do
    command -v "$t" >/dev/null || { echo "Missing tool: $t"; exit "$EXIT_PRECHECK"; }
  done

  [ -x "$LUNACM_BIN" ] || { echo "LunaCM binary not executable: $LUNACM_BIN"; exit "$EXIT_PRECHECK"; }

  mkdir -p "$LOG_DIR" "$STATE_DIR" "$STATE_DIR/reports"
  touch "$LOG_DIR/luna-backup.log" "$STATE_DIR/status.env"

  if [ -f "$CONFIG_FILE" ]; then
    local perms
    perms=$(stat -c '%a' "$CONFIG_FILE")
    [ "$perms" = "600" ] || { echo "Config must be 600"; exit "$EXIT_PERMS"; }
  fi

  local v
  v=$(get_lunacm_version)
  if [ -n "$v" ] && ! version_ge "$v" "$MIN_CLIENT_VERSION"; then
    RUNTIME_WARNINGS+=("Luna client version $v below minimum $MIN_CLIENT_VERSION")
  fi

  if ! run_lunacm_commands "slot list" | grep -Eq "slot|Slot"; then
    echo "Could not enumerate slots"
    exit "$EXIT_PRECHECK"
  fi

  if [ -n "$BACKUP_HSM_SLOT" ]; then
    local slot_out
    slot_out=$(run_lunacm_commands "slot list" || true)
    echo "$slot_out" | grep -q "$BACKUP_HSM_SLOT" || RUNTIME_WARNINGS+=("Configured backup slot not found: $BACKUP_HSM_SLOT")
    echo "$slot_out" | grep -Eiq "transport|CKR_CMD_NOT_ALLOWED_HSM_IN_TRANSPORT" && exit "$EXIT_STM_OR_INIT"
  fi

  if command -v timedatectl >/dev/null; then
    timedatectl status | grep -qi "System clock synchronized: yes" || RUNTIME_WARNINGS+=("Time sync not confirmed")
  fi

  df -Pk "$LOG_DIR" | awk 'NR==2{if ($4<102400) exit 1}' || RUNTIME_WARNINGS+=("Low disk space in log filesystem")

  printf 'last_precheck_ts=%q\nlast_precheck_status=%q\n' "$(ts)" "PASS" > "$STATE_DIR/status.env"
  log_msg INFO "Precheck completed"
  printf '%s\n' "Precheck passed"
  for w in "${RUNTIME_WARNINGS[@]:-}"; do echo "WARNING: $w"; done
}

perform_partition_archive_backup() {
  local archive_name="$1"
  # NOTE: Command syntax can vary by Luna Client release; adjust with vendor guidance if needed.
  local cmd="slot set -slot $BACKUP_HSM_SLOT
partition archive backup -sourcepartitionlabel $SOURCE_PARTITION_LABEL -archive $archive_name
exit"
  run_lunacm_commands "$cmd"
}

write_summary() {
  local status="$1" start_ts="$2" end_ts="$3" duration="$4"
  local report="$STATE_DIR/reports/$(date -u +%Y%m%d-%H%M%S)-summary.txt"
  {
    echo "status=$status"
    echo "start=$start_ts"
    echo "end=$end_ts"
    echo "duration_seconds=$duration"
    echo "source_type=$SOURCE_TYPE"
    echo "source_partition=$SOURCE_PARTITION_LABEL"
    echo "source_slot=$SOURCE_SLOT"
    echo "source_ha_group=$SOURCE_HA_GROUP_LABEL"
    echo "source_hsm_host=$SOURCE_HSM_HOST"
    echo "backup_slot=$BACKUP_HSM_SLOT"
    echo "backup_archive_base=$BACKUP_ARCHIVE_NAME"
    echo "lunacm_version=$(get_lunacm_version)"
    echo "warnings=${RUNTIME_WARNINGS[*]:-none}"
    echo "next_schedule_hint=$(get_schedule_hint)"
  } > "$report"
  chmod 640 "$report"
  echo "$report"
}

send_report_if_configured() {
  local report_file="$1"
  if [ "$EMAIL_ENABLED" = "true" ] && [ -n "$EMAIL_TO" ]; then
    if command -v mailx >/dev/null; then
      mailx -s "Luna backup report $(hostname -s)" "$EMAIL_TO" < "$report_file" || true
    elif command -v sendmail >/dev/null; then
      { echo "To: $EMAIL_TO"; echo "Subject: Luna backup report"; echo; cat "$report_file"; } | sendmail -t || true
    else
      RUNTIME_WARNINGS+=("EMAIL_ENABLED=true but no mailx/sendmail")
    fi
  fi
}

backup_cmd() {
  load_config
  local dry_run="${DRY_RUN_DEFAULT}"
  local skip_precheck="false"
  local non_interactive="false"
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run="true" ;;
      --skip-precheck) skip_precheck="true" ;;
      --non-interactive) non_interactive="true" ;;
    esac
    shift
  done

  exec 9>"$LOCK_FILE" || exit "$EXIT_GENERAL"
  flock -n 9 || { echo "Backup already running"; exit "$EXIT_LOCKED"; }

  [ "$skip_precheck" = "true" ] || precheck
  local start_epoch start_ts
  start_epoch=$(date +%s); start_ts=$(ts)
  local archive_name="${BACKUP_ARCHIVE_NAME}-$(date -u +%Y%m%d-%H%M%S)"

  if [ "$REQUIRE_PED" = "true" ] && [ "$non_interactive" = "true" ]; then
    RUNTIME_WARNINGS+=("PED required in non-interactive mode; operation may timeout if no operator present")
  fi

  local status="PASS"
  if [ "$dry_run" = "true" ]; then
    log_msg INFO "Dry-run backup complete for archive=$archive_name"
  else
    if ! perform_partition_archive_backup "$archive_name" >> "$LOG_DIR/luna-backup.log" 2>&1; then
      status="FAIL"
      log_msg ERROR "Backup failed for archive=$archive_name"
      printf 'last_backup_ts=%q\nlast_backup_status=%q\n' "$(ts)" "$status" >> "$STATE_DIR/status.env"
      exit "$EXIT_LUNACM"
    fi
  fi

  local end_epoch end_ts duration
  end_epoch=$(date +%s); end_ts=$(ts); duration=$((end_epoch-start_epoch))
  local report
  report=$(write_summary "$status" "$start_ts" "$end_ts" "$duration")
  send_report_if_configured "$report"

  printf 'last_backup_ts=%q\nlast_backup_status=%q\nlast_report=%q\n' "$(ts)" "$status" "$report" >> "$STATE_DIR/status.env"
  log_msg INFO "Backup status=$status archive=$archive_name duration=${duration}s"
  echo "Backup status: $status"
  echo "Report: $report"
}

get_schedule_hint() {
  if [ "$SCHEDULE_TYPE" = "cron" ]; then
    echo "cron:$CRON_EXPRESSION"
  else
    echo "systemd:$SYSTEMD_TIMER_NAME"
  fi
}

list_cmd() { load_config; run_lunacm_commands "slot list\npartition list\nhagroup list" || exit "$EXIT_LUNACM"; }

verify_cmd() {
  load_config
  local out
  out=$(run_lunacm_commands "slot set -slot $BACKUP_HSM_SLOT\npartition archive list\nexit" || true)
  echo "$out"
  local report="$STATE_DIR/reports/$(date -u +%Y%m%d-%H%M%S)-verify.txt"
  {
    echo "verification_ts=$(ts)"
    echo "$out" | tail -n 80
  } > "$report"
  chmod 640 "$report"
  echo "Verification report: $report"
}

status_cmd() {
  load_config
  [ -f "$STATE_DIR/status.env" ] && source "$STATE_DIR/status.env" || true
  echo "Last backup status: ${last_backup_status:-unknown}"
  echo "Last backup timestamp: ${last_backup_ts:-unknown}"
  echo "Last precheck status: ${last_precheck_status:-unknown}"
  echo "Source: type=$SOURCE_TYPE partition=$SOURCE_PARTITION_LABEL ha=$SOURCE_HA_GROUP_LABEL"
  echo "Destination: slot=$BACKUP_HSM_SLOT archive_base=$BACKUP_ARCHIVE_NAME"
  echo "Schedule: $(get_schedule_hint)"
  echo "--- Last 10 log lines ---"
  tail -n 10 "$LOG_DIR/luna-backup.log" 2>/dev/null || true
}

setup_cmd() {
  mkdir -p "$(dirname "$CONFIG_FILE")"
  touch "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  read -r -p "Mode (1 client_usb / 2 appliance_usb) [1]: " m; m=${m:-1}
  [ "$m" = "2" ] && MODE="appliance_usb" || MODE="client_usb"
  read -r -p "LunaCM path [$LUNACM_BIN]: " in; LUNACM_BIN=${in:-$LUNACM_BIN}
  read -r -p "Min client version [$MIN_CLIENT_VERSION]: " in; MIN_CLIENT_VERSION=${in:-$MIN_CLIENT_VERSION}
  read -r -p "Source Network HSM host/IP: " SOURCE_HSM_HOST
  read -r -p "Source type (partition/slot/ha) [$SOURCE_TYPE]: " in; SOURCE_TYPE=${in:-$SOURCE_TYPE}
  read -r -p "Source partition label: " SOURCE_PARTITION_LABEL
  read -r -p "Source slot (optional): " SOURCE_SLOT
  read -r -p "HA group label (optional): " SOURCE_HA_GROUP_LABEL
  read -r -p "Backup HSM slot: " BACKUP_HSM_SLOT
  read -r -p "Backup archive base name: " BACKUP_ARCHIVE_NAME
  read -r -p "Retention count [$RETENTION_COUNT]: " in; RETENTION_COUNT=${in:-$RETENTION_COUNT}
  read -r -p "Backup frequency (hourly/daily/weekly/monthly/custom) [daily]: " freq; freq=${freq:-daily}
  case "$freq" in
    hourly) CRON_EXPRESSION="0 * * * *";; daily) CRON_EXPRESSION="0 2 * * *";; weekly) CRON_EXPRESSION="0 2 * * 0";; monthly) CRON_EXPRESSION="0 2 1 * *";;
    custom) read -r -p "Enter cron expression: " CRON_EXPRESSION;;
  esac
  read -r -p "Backup window note (e.g. 01:00-03:00): " BACKUP_WINDOW
  read -r -p "Log directory [$LOG_DIR]: " in; LOG_DIR=${in:-$LOG_DIR}
  read -r -p "Enable email reports? (true/false) [$EMAIL_ENABLED]: " in; EMAIL_ENABLED=${in:-$EMAIL_ENABLED}
  if [ "$EMAIL_ENABLED" = "true" ]; then read -r -p "Email recipient: " EMAIL_TO; fi
  read -r -p "Use systemd timer instead of cron? (true/false) [false]: " in; [ "${in:-false}" = "true" ] && SCHEDULE_TYPE="systemd" || SCHEDULE_TYPE="cron"
  read -r -p "PED required? (true/false) [$REQUIRE_PED]: " in; REQUIRE_PED=${in:-$REQUIRE_PED}
  read -r -p "Command timeout seconds [$COMMAND_TIMEOUT_SECONDS]: " in; COMMAND_TIMEOUT_SECONDS=${in:-$COMMAND_TIMEOUT_SECONDS}
  cat > "$CONFIG_FILE" <<CFG
LUNACM_BIN="$LUNACM_BIN"
MODE="$MODE"
MIN_CLIENT_VERSION="$MIN_CLIENT_VERSION"
SOURCE_TYPE="$SOURCE_TYPE"
SOURCE_PARTITION_LABEL="$SOURCE_PARTITION_LABEL"
SOURCE_SLOT="$SOURCE_SLOT"
SOURCE_HA_GROUP_LABEL="$SOURCE_HA_GROUP_LABEL"
SOURCE_HSM_HOST="$SOURCE_HSM_HOST"
BACKUP_HSM_SLOT="$BACKUP_HSM_SLOT"
BACKUP_ARCHIVE_NAME="$BACKUP_ARCHIVE_NAME"
BACKUP_DOMAIN_REFERENCE="$BACKUP_DOMAIN_REFERENCE"
RETENTION_COUNT="$RETENTION_COUNT"
COMMAND_TIMEOUT_SECONDS="$COMMAND_TIMEOUT_SECONDS"
LOG_DIR="$LOG_DIR"
STATE_DIR="$STATE_DIR"
LOCK_FILE="$LOCK_FILE"
EMAIL_ENABLED="$EMAIL_ENABLED"
EMAIL_TO="$EMAIL_TO"
SCHEDULE_TYPE="$SCHEDULE_TYPE"
CRON_EXPRESSION="$CRON_EXPRESSION"
REQUIRE_PED="$REQUIRE_PED"
DRY_RUN_DEFAULT="$DRY_RUN_DEFAULT"
BACKUP_WINDOW="$BACKUP_WINDOW"
REPORT_HOOK="$REPORT_HOOK"
CFG
  chmod 600 "$CONFIG_FILE"
  echo "Wrote config to $CONFIG_FILE"
  read -r -p "Run dry-run validation now? (y/N): " in
  [ "${in:-N}" = "y" ] && backup_cmd --dry-run || true
}

schedule_cmd() {
  load_config
  echo "Schedule type in config: $SCHEDULE_TYPE"
  if [ "$SCHEDULE_TYPE" = "cron" ]; then
    local script_path
    script_path=$(readlink -f "$0")
    local current
    current=$(crontab -l 2>/dev/null || true)
    current=$(printf '%s\n' "$current" | awk "/$MANAGED_CRON_BEGIN/{f=1;next}/$MANAGED_CRON_END/{f=0;next}!f")
    {
      printf '%s\n' "$current"
      echo "$MANAGED_CRON_BEGIN"
      echo "$CRON_EXPRESSION $script_path backup --non-interactive >> $LOG_DIR/scheduler.log 2>&1"
      echo "$MANAGED_CRON_END"
    } | crontab -
    echo "Cron schedule installed"
  else
    echo "Use install.sh to place systemd unit files, then run:"
    echo "systemctl daemon-reload && systemctl enable --now luna-backup.timer"
  fi
}

stm_guide() { cat <<'EOT'
STM Recovery Guide (manual, dual-control recommended):
1) Connect Luna Backup USB HSM 7 to approved Linux client workstation.
2) Launch LunaCM and confirm slot number.
3) Select slot: slot set -slot <backup_slot>
4) Recover STM: stm recover -randomuserstring <string>
5) If required, initialize Backup HSM SO using approved secure procedure.
6) Re-run precheck before backup.
Never run STM recovery unattended from scheduler.
EOT
}

init_guide() {
  cat <<'EOT'
Initialization Guide (safe mode):
- Verify serial number and custody paperwork.
- Confirm change ticket and dual-authorization.
- Confirm device is not production-active.
- Initialize SO only via approved ceremony.
- Set policies explicitly; do not use defaults blindly.
- Record policy 55 (Restricted Restore) status for audit.
EOT
  if [ "${1:-}" = "--dangerous-allow-init" ]; then
    read -r -p "Type I_UNDERSTAND to continue with manual init helper: " x
    [ "$x" = "I_UNDERSTAND" ] || exit "$EXIT_GENERAL"
    echo "Dangerous init automation is intentionally not implemented. Use guided manual ceremony."
  fi
}

restore_guide_cmd() {
  cat <<'EOT'
Restore Drill Guide:
- Restore is MANUAL and requires explicit approval.
- Use non-production target partition only.
- Validate domain compatibility and custody of PED/domain material.
- Verify target slot/partition twice (four-eyes control).
- Capture full command transcript and change ticket.
- Do NOT run restore in this automation script.
EOT
  read -r -p "Confirm target is non-production (yes/no): " y
  [ "$y" = "yes" ] && echo "Proceed with documented manual drill in restore_drill.md" || echo "Aborted"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  setup) setup_cmd ;;
  precheck) precheck ;;
  backup) backup_cmd "$@" ;;
  schedule) schedule_cmd ;;
  status) status_cmd ;;
  list) list_cmd ;;
  verify) verify_cmd ;;
  restore-guide) restore_guide_cmd ;;
  stm-guide) stm_guide ;;
  init-guide) init_guide "$@" ;;
  validate-config) validate_config ;;
  *) usage; exit 1 ;;
esac
