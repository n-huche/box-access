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

cmd=${1:-}
shift || true
case "$cmd" in
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
