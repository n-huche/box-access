# Tailscale daemon health for steps/03-tailscaled.sh and units/tailscale-watchdog.sh.
# Healthy means BackendState=Running, this node has an IPv4, and Self.Online=true.
# Online=false is only unhealthy if a second read agrees. TS_ONLINE_CONFIRM_SECS
# is that gap (default 30). Not Running and a missing IPv4 fail on the first read.
# No apt, no secrets, no daemons. On failure TS_HEALTH_REASON is one of:
# "not Running", "no IPv4", "offline".
# A VM pause freezes /proc/uptime while the wall clock jumps. tailscale_resume_from_pause
# reports that skew. TS_WALL_CLOCK_FILE and TS_UPTIME_FILE override the sources.

if [[ -z "${BOX_ACCESS_HEALTH_LOADED:-}" ]]; then
  BOX_ACCESS_HEALTH_LOADED=1
  _ts_health_lib=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  # shellcheck source=listen.sh
  source "$_ts_health_lib/listen.sh"
  unset _ts_health_lib

  tailscale_read_status() {
    local line
    line=$(sudo tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.stdout.write("\t\n")
    raise SystemExit(0)
backend = data.get("BackendState") or ""
node = data.get("Self")
if not isinstance(node, dict):
    node = {}
online = node.get("Online", None)
if online is True:
    flag = "true"
elif online is False:
    flag = "false"
else:
    flag = ""
sys.stdout.write("%s\t%s\n" % (backend, flag))
' 2>/dev/null || true)
    if [[ "$line" == *$'\t'* ]]; then
      TS_STATUS_BACKEND=${line%%$'\t'*}
      TS_STATUS_ONLINE=${line#*$'\t'}
    else
      TS_STATUS_BACKEND=""
      TS_STATUS_ONLINE=""
    fi
  }

  # 0 healthy, 1 hard failure (reason set), 2 Running with an IPv4 but not online.
  _tailscale_health_sample() {
    local backend online
    tailscale_read_status
    backend=$TS_STATUS_BACKEND
    online=$TS_STATUS_ONLINE
    if [[ "$backend" != "Running" ]]; then
      TS_HEALTH_REASON="not Running"
      return 1
    fi
    if ! tailscale_ip >/dev/null 2>&1; then
      TS_HEALTH_REASON="no IPv4"
      return 1
    fi
    if [[ "$online" == "true" ]]; then
      TS_HEALTH_REASON=""
      return 0
    fi
    return 2
  }

  # 0 when the daemon is healthy, 1 when it should be restarted.
  tailscale_healthy() {
    local secs rc
    TS_HEALTH_REASON=""
    _tailscale_health_sample && rc=0 || rc=$?
    if [[ "$rc" -ne 2 ]]; then
      return "$rc"
    fi
    secs=${TS_ONLINE_CONFIRM_SECS:-30}
    # The watchdog calls this while holding fd 9. sleep must not inherit it.
    sleep "$secs" 9>&-
    _tailscale_health_sample && rc=0 || rc=$?
    if [[ "$rc" -eq 2 ]]; then
      TS_HEALTH_REASON="offline"
      return 1
    fi
    return "$rc"
  }

  # Seconds. Tests point TS_WALL_CLOCK_FILE at a file containing an integer.
  tailscale_wall_secs() {
    local raw
    if [[ -n "${TS_WALL_CLOCK_FILE:-}" ]]; then
      raw=$(tr -cd '0-9' <"$TS_WALL_CLOCK_FILE" || true)
      printf '%s\n' "${raw:-0}"
      return
    fi
    date +%s
  }

  # Whole seconds from /proc/uptime. Tests point TS_UPTIME_FILE elsewhere.
  tailscale_uptime_secs() {
    local file raw
    file=${TS_UPTIME_FILE:-/proc/uptime}
    raw=$(awk '{print $1}' "$file" 2>/dev/null || true)
    raw=${raw%%.*}
    printf '%s\n' "${raw:-0}"
  }

  # 0 when wall clock advanced more than uptime by more than TS_RESUME_SKEW_SECS
  # (default 20) since the previous sample. The first sample only records a baseline.
  # Sets TS_RESUME_PAUSED to that difference in seconds.
  tailscale_resume_from_pause() {
    local wall up paused skew
    wall=$(tailscale_wall_secs)
    up=$(tailscale_uptime_secs)
    skew=${TS_RESUME_SKEW_SECS:-20}
    if [[ -z "${TS_RESUME_PREV_WALL:-}" || -z "${TS_RESUME_PREV_UP:-}" ]]; then
      TS_RESUME_PREV_WALL=$wall
      TS_RESUME_PREV_UP=$up
      TS_RESUME_PAUSED=0
      return 1
    fi
    paused=$(( (wall - TS_RESUME_PREV_WALL) - (up - TS_RESUME_PREV_UP) ))
    TS_RESUME_PREV_WALL=$wall
    TS_RESUME_PREV_UP=$up
    TS_RESUME_PAUSED=$paused
    if (( paused > skew )); then
      return 0
    fi
    return 1
  }

  # One daemon log for up.sh and the watchdog. Not the watchdog's own log.
  tailscaled_daemon_log() {
    if [[ -n "${TS_DAEMON_LOG:-}" ]]; then
      printf '%s\n' "$TS_DAEMON_LOG"
      return
    fi
    if [[ -n "${REPO:-}" ]]; then
      printf '%s\n' "$REPO/units/tailscaled.log"
      return
    fi
    local root
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    printf '%s\n' "$root/units/tailscaled.log"
  }

  # Rotate to .1 when the log is above TS_DAEMON_LOG_MAX_BYTES (default 10 MB).
  # Prints the path to append to.
  tailscaled_prepare_daemon_log() {
    local log max size
    log=$(tailscaled_daemon_log)
    mkdir -p -- "$(dirname "$log")"
    max=${TS_DAEMON_LOG_MAX_BYTES:-10485760}
    if [[ -f "$log" ]]; then
      size=$(wc -c <"$log" | tr -d '[:space:]')
      if [[ -n "$size" ]] && (( size > max )); then
        mv -f -- "$log" "${log}.1"
      fi
    fi
    printf '%s\n' "$log"
  }
fi
