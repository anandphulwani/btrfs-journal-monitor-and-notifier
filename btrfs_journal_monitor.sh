#!/bin/bash
#
# BTRFS kernel alert script (journalctl) with lookback window + email/webhook
#
# - Uses main(), heartbeat(), notify_webhook(), send_notification_email()
# - Looks back N hours + M minutes (configurable flags)
# - Reads kernel log from journald, filters BTRFS lines excluding "info" and excluding
#   mount scan noise lines like:
#     kernel: BTRFS: device ... scanned by mount (123)
# - If any remaining lines exist, bundles them into one text blob and:
#     * sends INSTANT email
#     * POSTs to --notification-url (if provided)
#
# Example cron (check last 1 hour):
#   */5 * * * * /path/to/btrfs_journal_monitor.sh --mode=production --email=you@x --lookback=1h30m
#
set -euo pipefail
ORIGINAL_CMDLINE=("$0" "$@")

usage() {
	cat <<'EOF'
Usage:
  btrfs_journal_monitor.sh --mode=production|development --email=EMAIL [options]

Required:
  --mode=production|development
  --email=EMAIL
  --lookback=NhNm   (e.g. 2h, 45m, 1h30m)

Optional:
  --debug
  --log=PATH
  --heartbeat-url=URL
  --notification-url=URL
  -h|--help

Notes:
  - lookback default: 1 hour, 0 minutes
  - In production, reads from journalctl -k --since "<window>"
EOF
}

die() {
	echo "ERROR: $*" >&2
	usage >&2
	exit 2
}

# Defaults, (but allow override via flags, if flag option is available)
DEBUG=0
LOG="/var/log/btrfs_journal_monitor.log"
EMAIL=""
MODE=""
HEARTBEAT_URL=""
NOTIFICATION_URL=""
LOOKBACK_HOURS=""
LOOKBACK_MINUTES=""
LOOKBACK_RAW=""

# --- Arg parsing ---
for arg in "$@"; do
	case "$arg" in
	--debug)
		DEBUG=1
		;;
	--log=*)
		LOG="${arg#*=}"
		;;
	--email=*)
		EMAIL="${arg#*=}"
		;;
	--mode=*)
		MODE="${arg#*=}"
		;;
	--lookback=*)
		LOOKBACK_RAW="${arg#*=}"
		;;
	--heartbeat-url=*)
		HEARTBEAT_URL="${arg#*=}"
		;;
	--notification-url=*)
		NOTIFICATION_URL="${arg#*=}"
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "Unknown argument: $arg"
		;;
	esac
done

[[ -n "$EMAIL" ]] || die "--email is required"
[[ -n "$MODE" ]] || die "--mode is required"
[[ -n "$LOOKBACK_RAW" ]] || die "--lookback is required (e.g. --lookback=1h30m)"

case "$MODE" in
production | development) ;;
*) die "--mode must be production or development (got: $MODE)" ;;
esac

# basic sanity checks for values
if [[ ! "$LOOKBACK_RAW" =~ ^([0-9]+h)?([0-9]+m)?$ ]]; then
	die "--lookback must be in format NhNm (e.g. 2h, 45m, 1h30m)"
fi

LOOKBACK_HOURS=0
LOOKBACK_MINUTES=0

if [[ "$LOOKBACK_RAW" =~ ([0-9]+)h ]]; then
	LOOKBACK_HOURS="${BASH_REMATCH[1]}"
fi

if [[ "$LOOKBACK_RAW" =~ ([0-9]+)m ]]; then
	LOOKBACK_MINUTES="${BASH_REMATCH[1]}"
fi

if (( LOOKBACK_HOURS == 0 && LOOKBACK_MINUTES == 0 )); then
	die "--lookback cannot be 0h0m"
fi

timestamp() {
	date '+%Y-%m-%d %H:%M:%S'
}

log() {
	# Usage:
	#   log "message"
	#   log info "message"
	#   log debug "message"
	local level="info"
	local msg

	if [[ "${1:-}" == "debug" || "${1:-}" == "info" ]]; then
		level="$1"
		shift
	fi

	msg="$*"

	if [[ "$level" == "debug" && "${DEBUG:-0}" -ne 1 ]]; then
		return 0
	fi

	echo "[$(timestamp)] [$level] $msg" >>"$LOG"
}

log debug "Config: MODE=$MODE EMAIL=$EMAIL DEBUG=$DEBUG LOG=$LOG"
log debug "Config: LOOKBACK_RAW=$LOOKBACK_RAW"
log debug "Config: NOTIFICATION_URL=$NOTIFICATION_URL"
log debug "Config: HEARTBEAT_URL=$HEARTBEAT_URL"

notify_webhook() {
	local msg="$1"
	[[ -n "$NOTIFICATION_URL" ]] || return 0

	command -v curl >/dev/null 2>&1 || {
		log "ERROR: curl not found; cannot POST notification-url."
		return 0
	}

	# Same header pattern as your inspiration script
	curl -fsS -X POST \
		-H "Title: $(hostname): BTRFS kernel alert" \
		-H "Priority: urgent" \
		-H "Tags: rotating_light,skull" \
		-d "$msg" \
		"$NOTIFICATION_URL" >/dev/null || log "ERROR: notification-url POST failed"
}

heartbeat() {
	[[ -n "$HEARTBEAT_URL" ]] || return 0
	command -v curl >/dev/null 2>&1 || {
		log "ERROR: curl not found; cannot hit heartbeat-url."
		return 0
	}
	curl -fsS "$HEARTBEAT_URL" >/dev/null || log "ERROR: heartbeat-url failed"
}

require_cmd() {
	local cmd="$1"
	local msg

	if ! command -v "$cmd" >/dev/null 2>&1; then
		msg="ERROR: Command '$cmd' not found; skipping related checks."
		log "$msg"
		notify_webhook "$msg"
		return 1
	fi
	return 0
}

send_notification_email() {
	local stage="$1" # "INSTANT"
	local body="$2"

	local subject
	subject="$(hostname): BTRFS kernel alert (${stage} delivery)"

	{
		echo "$(timestamp) - BTRFS kernel ${stage} notification on $(hostname)"
		echo
		echo "Stage: ${stage}"
		echo "Lookback window: ${LOOKBACK_HOURS} hour(s) + ${LOOKBACK_MINUTES} minute(s)"
		echo "Invoked as: $(printf '%q ' "${ORIGINAL_CMDLINE[@]}")"
		echo
		echo "Matching lines (after exclusions):"
		echo
		printf '%s\n' "$body"
	} | mail -s "$subject" "$EMAIL"

	log "Successfully sent email to \`$EMAIL\` with subject \`$subject\` using mail command."
}

build_since_arg() {
	if ((LOOKBACK_HOURS > 0 && LOOKBACK_MINUTES > 0)); then
		echo "${LOOKBACK_HOURS} hour ago ${LOOKBACK_MINUTES} min ago"
	elif ((LOOKBACK_HOURS > 0)); then
		echo "${LOOKBACK_HOURS} hour ago"
	else
		echo "${LOOKBACK_MINUTES} min ago"
	fi
}

collect_btrfs_lines() {
	# Collect kernel lines that match BTRFS but NOT "BTRFS info"
	# then drop "device ... scanned by mount (PID)" noise.
	#
	# Regex used here:
	#   kernel: BTRFS:(?! info)
	#   kernel: BTRFS: device .* scanned by mount \([0-9]+\)$
	#
	local since
	since="$(build_since_arg)"

	if [[ "$MODE" == "production" ]]; then
		require_cmd journalctl || return 1
		require_cmd grep || return 1

		# Time-bounded kernel log;
		journalctl -k --since "$since" 2>/dev/null |
			grep -P 'kernel:\s+BTRFS(?!\s+info)' |
			grep -Pv 'kernel:\s+BTRFS:\s+device\s+.*\s+scanned by mount\s+\([0-9]+\)$'
	elif [[ "$MODE" == "development" ]]; then
		cat "./journalctl_output.txt" 2>/dev/null |
			grep -P 'kernel:\s+BTRFS(?!\s+info)' |
			grep -Pv 'kernel:\s+BTRFS:\s+device\s+.*\s+scanned by mount\s+\([0-9]+\)$'
	fi
}

main() {
	log "STARTING === BTRFS journal kernel check ==="
	log "Invoked as: $(printf '%q ' "${ORIGINAL_CMDLINE[@]}")"

	local lines
	lines="$(collect_btrfs_lines)"

	# Trim empty/whitespace
	if [[ -z "${lines//[[:space:]]/}" ]]; then
		log "No BTRFS kernel lines found (after exclusions) in lookback window."
		return 0
	fi

	# If anything remains, send INSTANT email + webhook with all lines in one text blob
	local msg
	msg=$(
		{
			echo "BTRFS kernel alert on $(hostname)"
			echo "Time: $(timestamp)"
			echo "Lookback: ${LOOKBACK_HOURS} hour(s) + ${LOOKBACK_MINUTES} minute(s)"
			echo
			echo "Lines:"
			echo
			printf '%s\n' "$lines"
		}
	)

	log "ERROR: BTRFS kernel lines detected; sending INSTANT notification."
	notify_webhook "$msg"
	send_notification_email "INSTANT" "$lines"
	log "ERROR: INSTANT notification dispatched."
}

main || exit $?
heartbeat
