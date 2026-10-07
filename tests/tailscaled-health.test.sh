#!/usr/bin/env bash
# A live tailscaled that is not Running with its own IPv4 is restarted
# on the same state file. The bounce does not use an authkey.
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
export FAKE_TS_BACKEND=Running
export FAKE_TS_IP=100.64.0.8
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
cmd=${1:-}
shift || true
case "$cmd" in
  status)
    printf '{"BackendState":"%s"}\n' "${FAKE_TS_BACKEND:-}"
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
  rm -f "$FAKE_TAILSCALED_DOWN" "$SOCKET"
}

reset_case
set +e
out=$(ensure_tailscaled 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL healthy ensure_tailscaled rc=$rc"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'tailscaled already running' <<<"$out"; then
  echo "FAIL healthy daemon was not left running"
  printf '%s\n' "$out"
  exit 1
fi
if [[ -s "$FAKE_TS_LOG" ]]; then
  echo "FAIL healthy daemon was restarted"
  cat "$FAKE_TS_LOG"
  exit 1
fi
echo "ok running daemon with Running and an IPv4 is left alone"

# Process is up, BackendState is Running, but this node has no IPv4.
export FAKE_TS_BACKEND=Running
export FAKE_TS_IP=
reset_case
set +e
out=$(ensure_tailscaled 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL unhealthy restart rc=$rc"
  printf '%s\n' "$out"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if grep -q 'tailscaled already running' <<<"$out"; then
  echo "FAIL unhealthy daemon returned early"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'restarting (reusing '"$STATE"')' <<<"$out"; then
  echo "FAIL restart did not say it reuses the state file"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'socket ready' <<<"$out"; then
  echo "FAIL restart did not bring the socket back"
  printf '%s\n' "$out"
  exit 1
fi
if grep -q -- '--authkey\|tailscale up' <<<"$out" || grep -q -- '--authkey\|tailscale up' "$FAKE_TS_LOG"; then
  echo "FAIL restart used an authkey or tailscale up"
  printf '%s\n' "$out"
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
echo "ok running but unhealthy tailscaled restarts on the same state"

if grep -q 'BackendState' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL watchdog should stay process-only"
  exit 1
fi
if ! grep -q 'pgrep -x tailscaled' "$ROOT/units/tailscale-watchdog.sh"; then
  echo "FAIL watchdog lost its process check"
  exit 1
fi
echo "ok tailscale watchdog stays process-only"
