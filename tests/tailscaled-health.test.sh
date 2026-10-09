#!/usr/bin/env bash
# A live tailscaled that is not healthy is restarted on the same state file.
# Healthy is Running, an own IPv4, and Self.Online=true. Online=false must
# repeat before it counts. The bounce does not use an authkey.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../steps/03-tailscaled.sh
source "$ROOT/steps/03-tailscaled.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export FAKE_TS_LOG="$TMP/tailscale.log"
export FAKE_TAILSCALED_DOWN="$TMP/down"
export FAKE_TS_ONLINE_READS="$TMP/online-reads"
export FAKE_TS_ONLINE_IDX="$TMP/online-idx"
export FAKE_TS_BACKEND=Running
export FAKE_TS_IP=100.64.0.8
export FAKE_TS_ONLINE=true
export FAKE_TS_ONLINE_LIST=
export STATE="$TMP/tailscaled.state"
export STATEDIR="$TMP/lib"
export SOCKET="$TMP/run/tailscaled.sock"
export TAILSCALED="$TMP/bin/tailscaled"
export TS_DAEMON_LOG="$TMP/tailscaled-daemon.log"
: > "$TS_DAEMON_LOG"
IDENTITY='existing-node-identity'
printf '%s\n' "$IDENTITY" > "$STATE"

mkdir -p "$TMP/bin"

cat > "$TMP/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ -f "${FAKE_TAILSCALED_DOWN:?}" ]]; then
  exit 1
fi
if [[ "${1:-}" == "-x" && "${2:-}" == "tailscaled" ]]; then
  printf '%s\n' "4242"
  exit 0
fi
exit 1
EOF

cat > "$TMP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [[ "${1:-}" == *=* ]]; do
  export "$1"
  shift
done
if [[ "${1:-}" == "mkdir" ]]; then
  shift
  args=()
  for a in "$@"; do
    [[ "$a" == "/run/tailscale" ]] && continue
    args+=("$a")
  done
  if ((${#args[@]})); then
    command mkdir "${args[@]}"
  fi
  exit 0
fi
if [[ "${1:-}" == "kill" ]]; then
  printf '%s\n' "$*" >> "${FAKE_TS_LOG:?}"
  : > "${FAKE_TAILSCALED_DOWN:?}"
  exit 0
fi
exec "$@"
EOF

cat > "$TMP/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
pick_online() {
  local pick idx n
  if [[ -n "${FAKE_TS_ONLINE_LIST:-}" ]]; then
    idx=0
    if [[ -n "${FAKE_TS_ONLINE_IDX:-}" && -f "$FAKE_TS_ONLINE_IDX" ]]; then
      idx=$(cat "$FAKE_TS_ONLINE_IDX")
    fi
    local -a arr=()
    read -r -a arr <<< "$FAKE_TS_ONLINE_LIST"
    n=${#arr[@]}
    if (( n == 0 )); then
      pick=${FAKE_TS_ONLINE:-true}
    elif (( idx >= n )); then
      pick=${arr[$((n - 1))]}
    else
      pick=${arr[$idx]}
    fi
    if [[ -n "${FAKE_TS_ONLINE_IDX:-}" ]]; then
      printf '%s\n' "$((idx + 1))" > "$FAKE_TS_ONLINE_IDX"
    fi
  else
    pick=${FAKE_TS_ONLINE:-true}
  fi
  if [[ -n "${FAKE_TS_ONLINE_READS:-}" ]]; then
    printf '%s\n' "$pick" >> "$FAKE_TS_ONLINE_READS"
  fi
  printf '%s' "$pick"
}

ts_socket=""
if [[ "${1:-}" == --socket=* ]]; then
  ts_socket=${1#--socket=}
  shift
elif [[ "${1:-}" == --socket ]]; then
  ts_socket=${2:-}
  shift 2
fi
cmd=${1:-}
shift || true
case "$cmd" in
  debug)
    sub=${1:-}
    printf 'debug socket=%s %s\n' "$ts_socket" "$sub" >> "${FAKE_TS_LOG:?}"
    if [[ -n "${FAKE_TS_DEBUG_RC:-}" ]]; then
      exit "$FAKE_TS_DEBUG_RC"
    fi
    ;;
  status)
    online=$(pick_online)
    case "$online" in
      true|false) online_json=$online ;;
      *) online_json=null ;;
    esac
    printf '{"BackendState":"%s","Self":{"Online":%s}}\n' "${FAKE_TS_BACKEND:-}" "$online_json"
    ;;
  ip)
    if [[ -n "${FAKE_TS_IP:-}" ]]; then
      printf '%s\n' "$FAKE_TS_IP"
    fi
    ;;
  *)
    printf '%s %s\n' "$cmd" "$*" >> "${FAKE_TS_LOG:?}"
    ;;
esac
EOF

cat > "$TMP/bin/ip" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$TMP/bin/tailscaled" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'start %s\n' "$*" >> "${FAKE_TS_LOG:?}"
printf 'TZ=%s\n' "${TZ:-}" >> "${FAKE_TS_LOG:?}"
printf 'daemon-stdout\n'
if [[ -n "${FAKE_TS_FD9_FILE:-}" ]]; then
  if [[ -e /dev/fd/9 ]]; then
    printf 'open\n' > "$FAKE_TS_FD9_FILE"
  else
    printf 'closed\n' > "$FAKE_TS_FD9_FILE"
  fi
fi
rm -f "${FAKE_TAILSCALED_DOWN:-}"
sock=""
for arg in "$@"; do
  case "$arg" in
    -socket=*) sock=${arg#-socket=} ;;
  esac
done
[[ -n "$sock" ]]
python3 -c '
import os, socket, sys
p = sys.argv[1]
os.makedirs(os.path.dirname(p), exist_ok=True)
try:
    os.unlink(p)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX)
s.bind(p)
s.close()
' "$sock"
if [[ -n "${FAKE_TS_SLEEP:-}" ]]; then
  printf '%s\n' "$$" > "${FAKE_TS_STARTED:?}"
  sleep "$FAKE_TS_SLEEP"
fi
EOF

chmod 755 "$TMP/bin/pgrep" "$TMP/bin/sudo" "$TMP/bin/tailscale" "$TMP/bin/ip" "$TMP/bin/tailscaled"
export PATH="$TMP/bin:$PATH"

reset_case() {
  : > "$FAKE_TS_LOG"
  : > "$FAKE_TS_ONLINE_READS"
  rm -f "$FAKE_TAILSCALED_DOWN" "$SOCKET" "$FAKE_TS_ONLINE_IDX"
}

run_ensure() {
  SECONDS=0
  set +e
  ENSURE_OUT=$(ensure_tailscaled 2>&1)
  ENSURE_RC=$?
  set -e
  ENSURE_SECS=$SECONDS
}

export TS_ONLINE_CONFIRM_SECS=30
export FAKE_TS_ONLINE_LIST=
export FAKE_TS_ONLINE=true
reset_case
run_ensure
if [[ "$ENSURE_RC" -ne 0 ]]; then
  echo "FAIL healthy ensure_tailscaled rc=$ENSURE_RC"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if ! grep -q 'tailscaled already running' <<<"$ENSURE_OUT"; then
  echo "FAIL healthy daemon was not left running"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if [[ -s "$FAKE_TS_LOG" ]]; then
  echo "FAIL healthy daemon was restarted"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if [[ "$(cat "$FAKE_TS_ONLINE_READS")" != "true" ]]; then
  echo "FAIL healthy check did not stop at Online=true"
  cat "$FAKE_TS_ONLINE_READS"
  exit 1
fi
if (( ENSURE_SECS > 5 )); then
  echo "FAIL healthy check waited for an online confirm (${ENSURE_SECS}s)"
  exit 1
fi
echo "ok running daemon with Running, an IPv4, and Online=true is left alone"

# Process is up, BackendState is Running, but this node has no IPv4.
# The missing address fails immediately: the 30s online confirm must not run.
export FAKE_TS_BACKEND=Running
export FAKE_TS_IP=
export FAKE_TS_ONLINE_LIST=
export TS_ONLINE_CONFIRM_SECS=30
reset_case
run_ensure
if [[ "$ENSURE_RC" -ne 0 ]]; then
  echo "FAIL unhealthy restart rc=$ENSURE_RC"
  printf '%s\n' "$ENSURE_OUT"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if grep -q 'tailscaled already running' <<<"$ENSURE_OUT"; then
  echo "FAIL unhealthy daemon returned early"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if ! grep -q 'no IPv4' <<<"$ENSURE_OUT"; then
  echo "FAIL restart did not say there was no IPv4"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if ! grep -q 'restarting (reusing '"$STATE"')' <<<"$ENSURE_OUT"; then
  echo "FAIL restart did not say it reuses the state file"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if ! grep -q 'socket ready' <<<"$ENSURE_OUT"; then
  echo "FAIL restart did not bring the socket back"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if grep -q -- '--authkey\|tailscale up' <<<"$ENSURE_OUT" || grep -q -- '--authkey\|tailscale up' "$FAKE_TS_LOG"; then
  echo "FAIL restart used an authkey or tailscale up"
  printf '%s\n' "$ENSURE_OUT"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if ! grep -q 'kill 4242' "$FAKE_TS_LOG"; then
  echo "FAIL unhealthy daemon was not stopped"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if ! grep -F -q -- "-state=$STATE -statedir=$STATEDIR -socket=$SOCKET" "$FAKE_TS_LOG"; then
  echo "FAIL restart did not reuse STATE STATEDIR SOCKET"
  cat "$FAKE_TS_LOG"
  exit 1
fi
kill_line=$(grep -n 'kill 4242' "$FAKE_TS_LOG" | head -n1 | cut -d: -f1)
start_line=$(grep -n '^-state=\|^start ' "$FAKE_TS_LOG" | head -n1 | cut -d: -f1)
if (( kill_line >= start_line )); then
  echo "FAIL daemon was started before the old process was stopped"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if [[ "$(cat "$STATE")" != "$IDENTITY" ]]; then
  echo "FAIL state identity was replaced"
  exit 1
fi
if [[ "$(grep -c . "$FAKE_TS_ONLINE_READS" || true)" -ne 1 ]]; then
  echo "FAIL no-IPv4 check read status more than once"
  cat "$FAKE_TS_ONLINE_READS"
  exit 1
fi
if (( ENSURE_SECS > 5 )); then
  echo "FAIL no-IPv4 check waited (${ENSURE_SECS}s)"
  exit 1
fi
echo "ok running but unhealthy tailscaled restarts on the same state"

# Running + IPv4 + Online=false on both reads restarts. Confirm delay is 0 in tests.
export FAKE_TS_BACKEND=Running
export FAKE_TS_IP=100.64.0.8
export FAKE_TS_ONLINE_LIST='false false'
export TS_ONLINE_CONFIRM_SECS=0
reset_case
run_ensure
if [[ "$ENSURE_RC" -ne 0 ]]; then
  echo "FAIL offline restart rc=$ENSURE_RC"
  printf '%s\n' "$ENSURE_OUT"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if grep -q 'tailscaled already running' <<<"$ENSURE_OUT"; then
  echo "FAIL offline daemon was left running"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if ! grep -q 'offline' <<<"$ENSURE_OUT"; then
  echo "FAIL restart did not say the node was offline"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if ! grep -q 'restarting (reusing '"$STATE"')' <<<"$ENSURE_OUT"; then
  echo "FAIL offline restart did not reuse the state file"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if grep -q -- '--authkey\|tailscale up' <<<"$ENSURE_OUT" || grep -q -- '--authkey\|tailscale up' "$FAKE_TS_LOG"; then
  echo "FAIL offline restart used an authkey or tailscale up"
  printf '%s\n' "$ENSURE_OUT"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if ! grep -F -q -- "-state=$STATE -statedir=$STATEDIR -socket=$SOCKET" "$FAKE_TS_LOG"; then
  echo "FAIL offline restart did not reuse STATE STATEDIR SOCKET"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if [[ "$(cat "$FAKE_TS_ONLINE_READS")" != $'false\nfalse' ]]; then
  echo "FAIL offline check did not read Online=false twice"
  cat "$FAKE_TS_ONLINE_READS"
  exit 1
fi
if [[ "$(cat "$STATE")" != "$IDENTITY" ]]; then
  echo "FAIL offline restart replaced the state identity"
  exit 1
fi
if (( ENSURE_SECS > 5 )); then
  echo "FAIL offline confirm ignored TS_ONLINE_CONFIRM_SECS (${ENSURE_SECS}s)"
  exit 1
fi
echo "ok Online=false on both reads restarts on the same state"
if ! grep -q 'TZ=UTC' "$FAKE_TS_LOG"; then
  echo "FAIL tailscaled was not started with TZ=UTC"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if [[ "$(grep -c 'daemon-stdout' "$TS_DAEMON_LOG")" -lt 2 ]]; then
  echo "FAIL daemon log was not appended across starts"
  cat "$TS_DAEMON_LOG"
  exit 1
fi
if grep -n 'setsid' "$ROOT/steps/03-tailscaled.sh" | grep -q '/dev/null'; then
  echo "FAIL ensure_tailscaled still discards daemon output"
  exit 1
fi
if ! grep -q 'tailscaled_prepare_daemon_log' "$ROOT/steps/03-tailscaled.sh" \
  || ! grep -q 'tailscaled_prepare_daemon_log' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL up.sh and the watchdog do not share the daemon log"
  exit 1
fi
if ! grep -q 'TZ=UTC' "$ROOT/steps/03-tailscaled.sh" \
  || ! grep -q 'TZ=UTC' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL daemon is not started with TZ=UTC"
  exit 1
fi
echo "ok daemon log is appended for up.sh and the watchdog, not /dev/null"

(
  export TS_DAEMON_LOG="$TMP/rotate.log"
  export TS_DAEMON_LOG_MAX_BYTES=8
  printf '0123456789' > "$TS_DAEMON_LOG"
  tailscaled_prepare_daemon_log >/dev/null
  if [[ ! -f "${TS_DAEMON_LOG}.1" || -f "$TS_DAEMON_LOG" ]]; then
    echo "FAIL daemon log above the cap was not moved to .1"
    exit 1
  fi
)
echo "ok daemon log rotates above the size cap"

# One false sample then true is the startup blip: do not restart.
export FAKE_TS_ONLINE_LIST='false true'
export TS_ONLINE_CONFIRM_SECS=0
reset_case
run_ensure
if [[ "$ENSURE_RC" -ne 0 ]]; then
  echo "FAIL blip ensure_tailscaled rc=$ENSURE_RC"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if ! grep -q 'tailscaled already running' <<<"$ENSURE_OUT"; then
  echo "FAIL a single Online=false restarted the daemon"
  printf '%s\n' "$ENSURE_OUT"
  exit 1
fi
if [[ -s "$FAKE_TS_LOG" ]]; then
  echo "FAIL a single Online=false stopped or started tailscaled"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if [[ "$(cat "$FAKE_TS_ONLINE_READS")" != $'false\ntrue' ]]; then
  echo "FAIL blip check did not read false then true"
  cat "$FAKE_TS_ONLINE_READS"
  exit 1
fi
if (( ENSURE_SECS > 5 )); then
  echo "FAIL blip confirm ignored TS_ONLINE_CONFIRM_SECS (${ENSURE_SECS}s)"
  exit 1
fi
echo "ok Online=false once then true does not restart"

if ! grep -q 'tailscale_healthy' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL watchdog does not use the shared health function"
  exit 1
fi
if ! grep -q 'tailscale-health.sh' "$ROOT/units/tailscale-watchdog.sh" \
  || ! grep -q 'tailscale-health.sh' "$ROOT/lib/common.sh"; then
  echo "FAIL tailscale health is not shared by common.sh and the watchdog"
  exit 1
fi
if ! grep -q 'pgrep -x tailscaled' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL watchdog lost its process check"
  exit 1
fi
if ! grep -q 'tailscaled not running; starting' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL process-down start path was removed"
  exit 1
fi
echo "ok watchdog checks health and still starts a missing process"
if ! grep -q 'TS_ONLINE_CONFIRM_SECS:-30' "$ROOT/lib/tailscale-health.sh"; then
  echo "FAIL online confirm default is not 30s"
  exit 1
fi
if ! grep -q 'TS_WATCHDOG_UNHEALTHY_READS:-3' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL watchdog bad-read default is not 3"
  exit 1
fi
if ! grep -q 'TS_WATCHDOG_RESTART_COOLDOWN:-600' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL watchdog cooldown default is not 600s"
  exit 1
fi
echo "ok health confirm, bad-read streak, and cooldown defaults"

# Two bad reads stay under the default streak of 3, so the daemon is not restarted.
export WD_STATE=$STATE WD_STATEDIR=$STATEDIR WD_SOCKET=$SOCKET WD_BIN=$TAILSCALED
(
  export TS_WATCHDOG_LOG="$TMP/wd-streak.log"
  export TS_WATCHDOG_COOLDOWN_FILE="$TMP/wd-streak.cooldown"
  export TS_WATCHDOG_UNHEALTHY_READS=3
  export TS_ONLINE_CONFIRM_SECS=30
  export FAKE_TS_BACKEND=Running
  export FAKE_TS_IP=
  export FAKE_TS_ONLINE_LIST=
  : > "$FAKE_TS_LOG"
  : > "$TS_WATCHDOG_LOG"
  rm -f "$FAKE_TAILSCALED_DOWN" "$TS_WATCHDOG_COOLDOWN_FILE"
  # shellcheck source=../units/tailscale-watchdog.sh
  source "$ROOT/units/tailscale-watchdog.sh"
  STATE=$WD_STATE
  STATEDIR=$WD_STATEDIR
  SOCKET=$WD_SOCKET
  BIN=$WD_BIN
  watchdog_observe_running
  watchdog_observe_running
)
if ! grep -q 'no IPv4 (1/3)' "$TMP/wd-streak.log" || ! grep -q 'no IPv4 (2/3)' "$TMP/wd-streak.log"; then
  echo "FAIL watchdog did not count a bad-read streak"
  cat "$TMP/wd-streak.log"
  exit 1
fi
if [[ -s "$FAKE_TS_LOG" ]]; then
  echo "FAIL watchdog restarted before 3 bad reads"
  cat "$FAKE_TS_LOG"
  exit 1
fi
echo "ok watchdog waits for 3 bad reads before restart"

# Watchdog: one bad read would restart, but a fresh cooldown file blocks it.
# No IPv4 fails immediately, so the 30s online confirm must not run.
export WD_STATE=$STATE WD_STATEDIR=$STATEDIR WD_SOCKET=$SOCKET WD_BIN=$TAILSCALED
run_watchdog() {
  local mode=$1
  (
    export TS_WATCHDOG_LOG="$TMP/wd.log"
    export TS_WATCHDOG_COOLDOWN_FILE="$TMP/wd.cooldown"
    export TS_WATCHDOG_UNHEALTHY_READS=1
    export TS_WATCHDOG_RESTART_COOLDOWN=600
    export TS_ONLINE_CONFIRM_SECS=30
    export FAKE_TS_BACKEND=Running
    export FAKE_TS_IP=
    export FAKE_TS_ONLINE_LIST=
    : > "$FAKE_TS_LOG"
    : > "$TS_WATCHDOG_LOG"
    rm -f "$FAKE_TAILSCALED_DOWN" "$TS_WATCHDOG_COOLDOWN_FILE"
    # shellcheck source=../units/tailscale-watchdog.sh
    source "$ROOT/units/tailscale-watchdog.sh"
    STATE=$WD_STATE
    STATEDIR=$WD_STATEDIR
    SOCKET=$WD_SOCKET
    BIN=$WD_BIN
    if [[ "$mode" == cooldown ]]; then
      date +%s > "$TS_WATCHDOG_COOLDOWN_FILE"
      TS_WATCHDOG_START_WAIT=0
    else
      TS_WATCHDOG_START_WAIT=1
    fi
    SECONDS=0
    set +e
    watchdog_observe_running
    rc=$?
    set -e
    printf '%s\n' "$rc" > "$TMP/wd.rc"
    printf '%s\n' "$SECONDS" > "$TMP/wd.secs"
  )
}

run_watchdog cooldown
wd_rc=$(cat "$TMP/wd.rc")
wd_secs=$(cat "$TMP/wd.secs")
if [[ "$wd_rc" -ne 0 ]]; then
  echo "FAIL cooldown observe rc=$wd_rc"
  cat "$TMP/wd.log"
  exit 1
fi
if ! grep -q 'no IPv4' "$TMP/wd.log" || ! grep -q 'restart skipped (cooldown)' "$TMP/wd.log"; then
  echo "FAIL cooldown did not log no IPv4 and the skip"
  cat "$TMP/wd.log"
  exit 1
fi
if [[ -s "$FAKE_TS_LOG" ]]; then
  echo "FAIL watchdog restarted inside cooldown"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if (( wd_secs > 5 )); then
  echo "FAIL watchdog no-IPv4 check waited (${wd_secs}s)"
  exit 1
fi
echo "ok watchdog inside cooldown does not restart"

run_watchdog restart
wd_rc=$(cat "$TMP/wd.rc")
wd_secs=$(cat "$TMP/wd.secs")
if [[ "$wd_rc" -ne 0 ]]; then
  echo "FAIL watchdog restart rc=$wd_rc"
  cat "$TMP/wd.log"
  cat "$FAKE_TS_LOG" || true
  exit 1
fi
if ! grep -q 'no IPv4; restarting' "$TMP/wd.log"; then
  echo "FAIL watchdog did not log the no IPv4 restart"
  cat "$TMP/wd.log"
  exit 1
fi
if ! grep -q 'kill 4242' "$FAKE_TS_LOG"; then
  echo "FAIL watchdog restart did not stop tailscaled"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if ! grep -F -q -- "-state=$WD_STATE -statedir=$WD_STATEDIR -socket=$WD_SOCKET" "$FAKE_TS_LOG"; then
  echo "FAIL watchdog restart did not reuse STATE STATEDIR SOCKET"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if grep -q -- '--authkey\|tailscale up' "$FAKE_TS_LOG" || grep -q -- '--authkey\|tailscale up' "$TMP/wd.log"; then
  echo "FAIL watchdog restart used an authkey or tailscale up"
  exit 1
fi
if [[ ! -s "$TMP/wd.cooldown" ]]; then
  echo "FAIL watchdog restart did not persist a cooldown"
  exit 1
fi
if [[ "$(cat "$STATE")" != "$IDENTITY" ]]; then
  echo "FAIL watchdog restart replaced the state identity"
  exit 1
fi
if (( wd_secs > 8 )); then
  echo "FAIL watchdog restart waited too long (${wd_secs}s)"
  exit 1
fi
echo "ok watchdog outside cooldown restarts once and records cooldown"

if ! grep -q 'TS_RESUME_SKEW_SECS:-20' "$ROOT/lib/tailscale-health.sh"; then
  echo "FAIL resume skew default is not 20s"
  exit 1
fi
if ! grep -q 'TS_RESUME_MIN_INTERVAL_SECS:-60' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL resume interval default is not 60s"
  exit 1
fi
echo "ok resume skew and interval defaults"

# Clock and uptime are files so the cases do not sleep.
resume_case() {
  local mode=$1
  local log="$TMP/resume-$mode.log"
  (
    export TS_WATCHDOG_LOG="$log"
    export TS_WATCHDOG_COOLDOWN_FILE="$TMP/resume-$mode.cooldown"
    export TS_WALL_CLOCK_FILE="$TMP/resume-$mode.wall"
    export TS_UPTIME_FILE="$TMP/resume-$mode.up"
    export TS_RESUME_SKEW_SECS=20
    export TS_RESUME_MIN_INTERVAL_SECS=60
    export TS_WATCHDOG_UNHEALTHY_READS=1
    export TS_WATCHDOG_RESTART_COOLDOWN=600
    export TS_WATCHDOG_START_WAIT=1
    export TS_ONLINE_CONFIRM_SECS=0
    export FAKE_TS_BACKEND=Running
    export FAKE_TS_ONLINE=true
    export FAKE_TS_ONLINE_LIST=
    unset FAKE_TS_DEBUG_RC
    : > "$FAKE_TS_LOG"
    : > "$TS_WATCHDOG_LOG"
    rm -f "$FAKE_TAILSCALED_DOWN" "$TS_WATCHDOG_COOLDOWN_FILE"
    # shellcheck source=../units/tailscale-watchdog.sh
    source "$ROOT/units/tailscale-watchdog.sh"
    STATE=$WD_STATE
    STATEDIR=$WD_STATEDIR
    SOCKET=$WD_SOCKET
    BIN=$WD_BIN
    printf '%s\n' 1000 > "$TS_WALL_CLOCK_FILE"
    printf '%s\n' 100 > "$TS_UPTIME_FILE"
    case "$mode" in
      above)
        export FAKE_TS_IP=
        date +%s > "$TS_WATCHDOG_COOLDOWN_FILE"
        watchdog_tick
        printf '%s\n' 1100 > "$TS_WALL_CLOCK_FILE"
        watchdog_tick
        ;;
      below)
        export FAKE_TS_IP=100.64.0.8
        watchdog_tick
        printf '%s\n' 1010 > "$TS_WALL_CLOCK_FILE"
        watchdog_tick
        ;;
      twice)
        export FAKE_TS_IP=100.64.0.8
        watchdog_tick
        printf '%s\n' 1100 > "$TS_WALL_CLOCK_FILE"
        watchdog_tick
        printf '%s\n' 1130 > "$TS_WALL_CLOCK_FILE"
        watchdog_tick
        ;;
      debug-missing|debug-fail)
        if [[ "$mode" == debug-missing ]]; then
          export FAKE_TS_DEBUG_RC=127
        else
          export FAKE_TS_DEBUG_RC=1
        fi
        export FAKE_TS_IP=100.64.0.8
        watchdog_tick
        printf '%s\n' 1100 > "$TS_WALL_CLOCK_FILE"
        watchdog_tick
        ;;
      unhealthy|unhealthy-cooldown)
        export TS_WATCHDOG_UNHEALTHY_READS=3
        export FAKE_TS_IP=100.64.0.8
        if [[ "$mode" == unhealthy-cooldown ]]; then
          date +%s > "$TS_WATCHDOG_COOLDOWN_FILE"
        fi
        watchdog_tick
        printf '%s\n' 1200 > "$TS_WALL_CLOCK_FILE"
        export FAKE_TS_IP=
        watchdog_tick
        printf '%s\n' 1205 > "$TS_WALL_CLOCK_FILE"
        printf '%s\n' 105 > "$TS_UPTIME_FILE"
        watchdog_tick
        printf '%s\n' 1210 > "$TS_WALL_CLOCK_FILE"
        printf '%s\n' 110 > "$TS_UPTIME_FILE"
        watchdog_tick
        ;;
    esac
  )
}

start_count() {
  grep -c '^start ' "$FAKE_TS_LOG" || true
}

debug_called() {
  local sub=$1
  grep -F -q "debug socket=$WD_SOCKET $sub" "$FAKE_TS_LOG"
}

resume_case above
if [[ "$(start_count)" -ne 0 ]]; then
  echo "FAIL resume restarted tailscaled"
  cat "$FAKE_TS_LOG"
  cat "$TMP/resume-above.log"
  exit 1
fi
if ! grep -q 'resume detected (paused 100s)' "$TMP/resume-above.log"; then
  echo "FAIL resume was not logged"
  cat "$TMP/resume-above.log"
  exit 1
fi
if ! debug_called rebind || ! debug_called break-derp-conns; then
  echo "FAIL resume did not rebind and break DERP on the daemon socket"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if grep -q 'break-tcp-conns' "$FAKE_TS_LOG" || grep -q 'break-tcp-conns' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL resume used break-tcp-conns"
  exit 1
fi
if ! grep -q 'restart skipped (cooldown)' "$TMP/resume-above.log"; then
  echo "FAIL unhealthy sample after resume ignored the cooldown"
  cat "$TMP/resume-above.log"
  exit 1
fi
if grep -q -- '--authkey\|tailscale up' "$FAKE_TS_LOG"; then
  echo "FAIL resume used an authkey or tailscale up"
  exit 1
fi
if [[ "$(cat "$STATE")" != "$IDENTITY" ]]; then
  echo "FAIL resume replaced the state identity"
  exit 1
fi
echo "ok wall-clock jump refreshes the path and does not restart"

resume_case below
if [[ "$(start_count)" -ne 0 ]]; then
  echo "FAIL jump below the skew restarted tailscaled"
  cat "$FAKE_TS_LOG"
  cat "$TMP/resume-below.log"
  exit 1
fi
if grep -q 'resume detected' "$TMP/resume-below.log"; then
  echo "FAIL small jump was logged as a resume"
  cat "$TMP/resume-below.log"
  exit 1
fi
echo "ok wall-clock jump below the skew does not restart"

resume_case twice
if [[ "$(start_count)" -ne 0 ]]; then
  echo "FAIL two close jumps restarted $(start_count) times"
  cat "$FAKE_TS_LOG"
  cat "$TMP/resume-twice.log"
  exit 1
fi
if [[ "$(grep -c 'resume detected' "$TMP/resume-twice.log")" -ne 1 ]]; then
  echo "FAIL two close jumps logged more than one resume"
  cat "$TMP/resume-twice.log"
  exit 1
fi
if [[ "$(grep -c 'debug socket=.* break-derp-conns' "$FAKE_TS_LOG")" -ne 1 ]]; then
  echo "FAIL two close jumps ran break-derp-conns more than once"
  cat "$FAKE_TS_LOG"
  exit 1
fi
echo "ok two resume jumps inside 60s produce one path refresh"

for mode in debug-missing debug-fail; do
  resume_case "$mode"
  want=127
  if [[ "$mode" == debug-fail ]]; then
    want=1
  fi
  if [[ "$(start_count)" -ne 0 ]]; then
    echo "FAIL $mode restarted tailscaled"
    cat "$FAKE_TS_LOG"
    cat "$TMP/resume-$mode.log"
    exit 1
  fi
  if ! grep -q "resume: tailscale debug rebind failed (exit $want); not restarting" "$TMP/resume-$mode.log"; then
    echo "FAIL $mode did not log the rebind failure"
    cat "$TMP/resume-$mode.log"
    exit 1
  fi
  if ! grep -q "resume: tailscale debug break-derp-conns failed (exit $want); not restarting" "$TMP/resume-$mode.log"; then
    echo "FAIL $mode did not log the break-derp-conns failure"
    cat "$TMP/resume-$mode.log"
    exit 1
  fi
  if ! debug_called rebind || ! debug_called break-derp-conns; then
    echo "FAIL $mode did not attempt both debug commands"
    cat "$FAKE_TS_LOG"
    exit 1
  fi
done
echo "ok missing or failing debug command does not restart"

resume_case unhealthy
if [[ "$(start_count)" -ne 1 ]]; then
  echo "FAIL three bad reads after resume restarted $(start_count) times"
  cat "$FAKE_TS_LOG"
  cat "$TMP/resume-unhealthy.log"
  exit 1
fi
if ! grep -q 'resume detected (paused 200s)' "$TMP/resume-unhealthy.log"; then
  echo "FAIL unhealthy-after-resume did not log the pause"
  cat "$TMP/resume-unhealthy.log"
  exit 1
fi
if ! grep -q 'no IPv4 (3/3)' "$TMP/resume-unhealthy.log"; then
  echo "FAIL three bad reads after resume were not counted"
  cat "$TMP/resume-unhealthy.log"
  exit 1
fi
if ! grep -q 'no IPv4; restarting' "$TMP/resume-unhealthy.log"; then
  echo "FAIL third bad read after resume did not restart"
  cat "$TMP/resume-unhealthy.log"
  exit 1
fi
if ! grep -F -q -- "-state=$WD_STATE -statedir=$WD_STATEDIR -socket=$WD_SOCKET" "$FAKE_TS_LOG"; then
  echo "FAIL health restart after resume did not reuse STATE STATEDIR SOCKET"
  cat "$FAKE_TS_LOG"
  exit 1
fi
echo "ok three bad reads after resume restart once"

resume_case unhealthy-cooldown
if [[ "$(start_count)" -ne 0 ]]; then
  echo "FAIL cooldown did not block the health restart after resume"
  cat "$FAKE_TS_LOG"
  cat "$TMP/resume-unhealthy-cooldown.log"
  exit 1
fi
if ! grep -q 'no IPv4 (3/3)' "$TMP/resume-unhealthy-cooldown.log"; then
  echo "FAIL cooldown case did not reach 3 bad reads"
  cat "$TMP/resume-unhealthy-cooldown.log"
  exit 1
fi
if ! grep -q 'restart skipped (cooldown)' "$TMP/resume-unhealthy-cooldown.log"; then
  echo "FAIL cooldown case did not skip the restart"
  cat "$TMP/resume-unhealthy-cooldown.log"
  exit 1
fi
echo "ok three bad reads after resume respect cooldown"

for unit in "$ROOT/units/tailscale-watchdog.sh" "$ROOT/units/sshd-watchdog.sh"; do
  if grep -E '^[[:space:]]*sleep ' "$unit" | grep -v '9>&-' >/dev/null; then
    echo "FAIL sleep in ${unit#"$ROOT"/} inherits the lock fd"
    grep -E '^[[:space:]]*sleep ' "$unit" | grep -v '9>&-'
    exit 1
  fi
done
if ! grep -q '9>&-' "$ROOT/units/tailscale-watchdog.sh" \
  || ! grep -q '9>&-' "$ROOT/units/sshd-watchdog.sh" \
  || ! grep -q '9>&-' "$ROOT/steps/03-tailscaled.sh" \
  || ! grep -q '9>&-' "$ROOT/steps/08-sshd.sh"; then
  echo "FAIL a daemon start does not close the lock fd"
  exit 1
fi
echo "ok daemon starts and sleeps drop the lock fd"

# The daemon is started while fd 9 holds the watchdog flock. It must not
# inherit that fd, or the next watchdog sees "already running" after this one exits.
(
  export TS_WATCHDOG_LOG="$TMP/lock-fd-wd.log"
  export TS_DAEMON_LOG="$TMP/lock-fd-daemon.log"
  export TS_WATCHDOG_START_WAIT=0
  export FAKE_TS_FD9_FILE="$TMP/lock-fd9"
  export FAKE_TS_STARTED="$TMP/lock-fd-started"
  export FAKE_TS_SLEEP=30
  rm -f "$FAKE_TS_FD9_FILE" "$FAKE_TS_STARTED" "$FAKE_TAILSCALED_DOWN"
  : > "$FAKE_TS_LOG"
  # shellcheck source=../units/tailscale-watchdog.sh
  source "$ROOT/units/tailscale-watchdog.sh"
  STATE=$WD_STATE
  STATEDIR=$WD_STATEDIR
  SOCKET=$WD_SOCKET
  BIN=$WD_BIN
  mkdir -p "$TMP/lock-fd"
  exec 9>"$TMP/lock-fd/pid"
  flock -n 9
  start_daemon
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [[ -s "$FAKE_TS_FD9_FILE" ]] && break
    sleep 0.05
  done
  exec 9>&-
  if [[ "$(cat "$FAKE_TS_FD9_FILE" 2>/dev/null || true)" != "closed" ]]; then
    echo "FAIL tailscaled inherited the watchdog lock fd"
    cat "$FAKE_TS_FD9_FILE" 2>/dev/null || true
    exit 1
  fi
  if ! flock -n "$TMP/lock-fd/pid" -c true; then
    echo "FAIL tailscaled still holds the watchdog lock"
    exit 1
  fi
  if [[ -s "$FAKE_TS_STARTED" ]]; then
    kill "$(cat "$FAKE_TS_STARTED")" 2>/dev/null || true
    wait "$(cat "$FAKE_TS_STARTED")" 2>/dev/null || true
  fi
)
echo "ok tailscaled does not hold the watchdog lock fd"

(
  export SSHD_DEBUG_LOG="$TMP/sshd-debug.log"
  export BOX_ACCESS_SS_TEXT=$'State\n'
  export FD9_FILE="$TMP/sshd-fd9"
  export SSHD_STARTED="$TMP/sshd-started"
  rm -f "$FD9_FILE" "$SSHD_STARTED"
  cat > "$TMP/bin/sshd-probe" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "-t" ]]; then
  exit 0
fi
if [[ -e /dev/fd/9 ]]; then
  printf 'open\n' > "${FD9_FILE:?}"
else
  printf 'closed\n' > "${FD9_FILE:?}"
fi
printf '%s\n' "$$" > "${SSHD_STARTED:?}"
sleep 30
EOF
  chmod 755 "$TMP/bin/sshd-probe"
  # shellcheck source=../units/sshd-watchdog.sh
  source "$ROOT/units/sshd-watchdog.sh"
  LOG="$TMP/sshd-watchdog.log"
  BIN="$TMP/bin/sshd-probe"
  sshd_listening() { return 0; }
  mkdir -p "$TMP/sshd-lock"
  exec 9>"$TMP/sshd-lock/pid"
  flock -n 9
  start_sshd 100.64.0.8
  exec 9>&-
  if [[ "$(cat "$FD9_FILE" 2>/dev/null || true)" != "closed" ]]; then
    echo "FAIL sshd inherited the watchdog lock fd"
    cat "$FD9_FILE" 2>/dev/null || true
    exit 1
  fi
  if ! flock -n "$TMP/sshd-lock/pid" -c true; then
    echo "FAIL sshd still holds the watchdog lock"
    exit 1
  fi
  if [[ -s "$SSHD_STARTED" ]]; then
    kill "$(cat "$SSHD_STARTED")" 2>/dev/null || true
    wait "$(cat "$SSHD_STARTED")" 2>/dev/null || true
  fi
)
echo "ok sshd does not hold the watchdog lock fd"

(
  # shellcheck source=../units/tailscale-watchdog.sh
  source "$ROOT/units/tailscale-watchdog.sh"
  LOCK_DIR="$TMP/stale-clean"
  mkdir -p "$LOCK_DIR"
  printf 'leftover\n' > "$LOCK_DIR/pid.stale-585716"
  watchdog_acquire_lock tailscale-watchdog.sh
  if [[ -e "$LOCK_DIR/pid.stale-585716" ]]; then
    echo "FAIL pid.stale-585716 was kept after the lock was taken"
    exit 1
  fi
  if [[ "$(cat "$LOCK_DIR/pid")" != "$$" ]]; then
    echo "FAIL lock pid file is not this watchdog"
    cat "$LOCK_DIR/pid"
    exit 1
  fi
)
echo "ok pid.stale leftovers are removed once the lock is held"

(
  sleeper=0
  trap '[[ "$sleeper" -ne 0 ]] && kill "$sleeper" 2>/dev/null || true' EXIT
  # shellcheck source=../units/tailscale-watchdog.sh
  source "$ROOT/units/tailscale-watchdog.sh"
  LOCK_DIR="$TMP/stale-leak"
  mkdir -p "$LOCK_DIR"
  : > "$LOCK_DIR/pid"
  bash -c 'exec 9>"$1"; flock -n 9 || exit 1; exec sleep 30' _ "$LOCK_DIR/pid" &
  sleeper=$!
  held=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [[ -e "/proc/$sleeper/fd/9" ]]; then
      held=1
      break
    fi
    sleep 0.05
  done
  if [[ "$held" -ne 1 ]]; then
    echo "FAIL leaked holder did not take the lock"
    exit 1
  fi
  err="$TMP/stale-leak.err"
  watchdog_acquire_lock tailscale-watchdog.sh 2>"$err"
  if ! grep -q "lock held by pid $sleeper" "$err"; then
    echo "FAIL leaked lock was not moved aside"
    cat "$err"
    exit 1
  fi
  if compgen -G "$LOCK_DIR/pid.stale-*" >/dev/null; then
    echo "FAIL pid.stale name survived a successful acquire"
    ls -l "$LOCK_DIR"
    exit 1
  fi
  if flock -n "$LOCK_DIR/pid" true; then
    echo "FAIL new lock file is not held by this watchdog only"
    exit 1
  fi
)
echo "ok a lock held by sleep is moved aside"

(
  sleeper=0
  trap '[[ "$sleeper" -ne 0 ]] && kill "$sleeper" 2>/dev/null || true' EXIT
  # shellcheck source=../units/tailscale-watchdog.sh
  source "$ROOT/units/tailscale-watchdog.sh"
  LOCK_DIR="$TMP/stale-live"
  mkdir -p "$LOCK_DIR"
  : > "$LOCK_DIR/pid"
  bash -c 'exec 9>"$1"; flock -n 9 || exit 1; exec -a tailscale-watchdog.sh sleep 30' _ "$LOCK_DIR/pid" &
  sleeper=$!
  held=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [[ -e "/proc/$sleeper/fd/9" ]]; then
      held=1
      break
    fi
    sleep 0.05
  done
  if [[ "$held" -ne 1 ]]; then
    echo "FAIL live watchdog did not take the lock"
    exit 1
  fi
  err="$TMP/stale-live.err"
  set +e
  watchdog_acquire_lock tailscale-watchdog.sh >"$TMP/stale-live.out" 2>"$err"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "FAIL live watchdog lock was taken over"
    exit 1
  fi
  if ! grep -q 'tailscale-watchdog already running' "$err"; then
    echo "FAIL live watchdog was not left in place"
    cat "$err"
    exit 1
  fi
  if compgen -G "$LOCK_DIR/pid.stale-*" >/dev/null; then
    echo "FAIL live watchdog lock was renamed"
    ls -l "$LOCK_DIR"
    exit 1
  fi
)
echo "ok a live watchdog keeps the lock"
