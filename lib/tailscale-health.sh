# Tailscale daemon health for steps/03-tailscaled.sh and units/tailscale-watchdog.sh.
# Healthy means BackendState=Running, this node has an IPv4, and Self.Online=true.
# Online=false is only unhealthy if a second read agrees. TS_ONLINE_CONFIRM_SECS
# is that gap (default 30). Not Running and a missing IPv4 fail on the first read.
# No apt, no secrets, no daemons. On failure TS_HEALTH_REASON is one of:
# "not Running", "no IPv4", "offline".

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
    sleep "$secs"
    _tailscale_health_sample && rc=0 || rc=$?
    if [[ "$rc" -eq 2 ]]; then
      TS_HEALTH_REASON="offline"
      return 1
    fi
    return "$rc"
  }
fi
