#!/usr/bin/env bash
# Checkout path is derived from the script. A symlink does not start a second
# watchdog or sshd. A copy still running from an old or deleted path is replaced.
# sshd replacement signals the listener only.
set -euo pipefail
set +b +m

if [[ -z "${BOX_ACCESS_NS:-}" ]]; then
  export BOX_ACCESS_NS=1
  exec unshare --user --pid --fork --mount-proc -- bash "$0" "$@"
fi

ROOT=$(realpath "$(dirname "$0")/..")
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

export BOX_ACCESS_WATCHDOG_START_WAIT=0

fail() {
  echo "FAIL $*" >&2
  exit 1
}

TMP=$(mktemp -d)
cleanup() {
  local pid
  local -a pids=()
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    pids+=("$pid")
  done < <(jobs -p || true)
  disown -a 2>/dev/null || true
  for pid in "${pids[@]+"${pids[@]}"}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

count_instances() {
  local n=0 line
  while IFS= read -r line; do
    [[ -n "$line" ]] && n=$((n + 1))
  done < <(box_access_watchdog_instances "$1")
  printf '%s\n' "$n"
}

stop_watchdogs() {
  local script pid
  local -a pids=()
  for script in "$@"; do
    while IFS=$'\t' read -r pid _; do
      [[ -n "$pid" ]] || continue
      pids+=("$pid")
    done < <(box_access_watchdog_instances "$script" || true)
  done
  disown -a 2>/dev/null || true
  for pid in "${pids[@]+"${pids[@]}"}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

install_stub() {
  local dir=$1 name=$2
  mkdir -p "$dir/units"
  cat > "$dir/units/$name" <<'EOF'
#!/bin/bash
dir=$(dirname "$(realpath -m -- "$0")")
base=$(basename -- "$0" .sh)
mkdir -p -- "$dir/${base}.lock"
exec 9>"$dir/${base}.lock/pid"
flock -n 9 || exit 0
printf '%s\n' "$$" >&9
trap 'exit 0' TERM INT
while true; do
  sleep 30 9>&- &
  wait $! || true
done
EOF
  chmod 755 "$dir/units/$name"
}

ensure_watchdog() {
  # Drop job-control notices when a later replace signals a process this shell started.
  disown -a 2>/dev/null || true
  box_access_ensure_watchdog "$@"
}

wait_pidfile() {
  local script=$1 i pid=""
  for i in $(seq 1 50); do
    pid=$(box_access_pidfile_pid "$script" || true)
    if [[ -n "$pid" ]] && box_access_pid_alive "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.05
  done
  return 1
}

# --- derived path: realpath of the script, no hardcoded checkout ---

want=$(realpath "$ROOT")
[[ "$REPO" == "$want" ]] || fail "REPO=$REPO want $want"
[[ "$(sshd_debug_log)" == "$want/units/sshd.log" ]] || fail "sshd -E $(sshd_debug_log)"

ln -s "$ROOT" "$TMP/via-link"
derived=$(bash -c '
REPO=$(realpath "$(dirname "$0")")
# shellcheck source=/dev/null
source "$REPO/lib/common.sh"
printf "%s\n" "$REPO"
sshd_debug_log
' "$TMP/via-link/up.sh")
got_repo=$(printf '%s\n' "$derived" | awk 'NR==1')
got_log=$(printf '%s\n' "$derived" | awk 'NR==2')
[[ "$got_repo" == "$want" ]] || fail "symlink up.sh REPO=$got_repo"
[[ "$got_log" == "$want/units/sshd.log" ]] || fail "symlink sshd -E $got_log"

direct=$(bash -c '
REPO=$(realpath "$(dirname "$0")")
# shellcheck source=/dev/null
source "$REPO/lib/common.sh"
printf "%s\n" "$REPO"
sshd_debug_log
' "$ROOT/up.sh")
[[ "$direct" == "$derived" ]] || fail "real path and symlink disagree"

for f in up.sh bootstrap.sh lib/common.sh lib/listen.sh \
  units/sshd-watchdog.sh units/tailscale-watchdog.sh; do
  grep -q 'realpath "$(dirname' "$ROOT/$f" || fail "$f does not derive its directory with realpath"
done
grep -q 'dirname "$0"' "$ROOT/up.sh" || fail "up.sh should use dirname of \$0"
grep -q 'BASH_SOURCE' "$ROOT/lib/common.sh" || fail "common.sh should use BASH_SOURCE"
grep -q 'BASH_SOURCE' "$ROOT/units/sshd-watchdog.sh" || fail "sshd watchdog should use BASH_SOURCE"
grep -q 'BASH_SOURCE' "$ROOT/units/tailscale-watchdog.sh" || fail "tailscale watchdog should use BASH_SOURCE"
if grep -q 'dirname "$0"' "$ROOT/units/sshd-watchdog.sh" "$ROOT/units/tailscale-watchdog.sh"; then
  fail "units still derive DIR from \$0"
fi

hits=$(grep -R -n -E '/workspace/box-access|/workspace/box-infra' \
  --exclude-dir=.git --exclude-dir=tests --exclude=README.md "$ROOT" || true)
[[ -z "$hits" ]] || fail "checkout path hardcoded outside docs: $hits"
grep -q 'cd /workspace/box-infra/box-access' "$ROOT/README.md" || fail "docs example path"
grep -q 'realpath' "$ROOT/README.md" || fail "docs do not mention realpath"
if grep -q 'cd /workspace/box-access' "$ROOT/README.md"; then
  fail "docs still tell the operator to cd to the old checkout"
fi
grep -q '/workspace/' "$ROOT/lib/apt-update.sh" && fail "apt-update.sh hardcodes a checkout" || true
grep -q 'BOX_LIB_DIR/apt-update.sh' "$ROOT/lib/common.sh" || fail "apt-update.sh is not loaded from the derived lib dir"
grep -q 'box_access_ensure_watchdog' "$ROOT/steps/09-watchdogs.sh" || fail "step 09 does not use ensure"
grep -q 'box_access_retire_other_watchdogs' "$ROOT/steps/08-sshd.sh" || fail "step 08 does not retire a foreign sshd watchdog"
grep -q 'box_access_stop_foreign_sshd_listeners' "$ROOT/steps/08-sshd.sh" || fail "step 08 does not replace a foreign sshd"
if grep -E -q 'pkill|killall' "$ROOT/lib/listen.sh" "$ROOT/steps/08-sshd.sh"; then
  fail "replacement must not signal every sshd"
fi
echo "ok checkout path is realpath of the script"

# --- symlink: one watchdog, whether up.sh is reached via the link or the real path ---

real=$TMP/real
link=$TMP/link
install_stub "$real" "sshd-watchdog.sh"
install_stub "$real" "tailscale-watchdog.sh"
ln -s "$real" "$link"

ensure_watchdog "$link/units/sshd-watchdog.sh" "sshd keep-alive" >"$TMP/sym1.out"
ensure_watchdog "$real/units/sshd-watchdog.sh" "sshd keep-alive" >"$TMP/sym2.out"
ensure_watchdog "$link/units/sshd-watchdog.sh" "sshd keep-alive" >"$TMP/sym3.out"
grep -q 'starting sshd keep-alive' "$TMP/sym1.out" || fail "first symlink start did not start"
grep -q 'already running' "$TMP/sym2.out" || fail "real path duplicated a symlink watchdog: $(cat "$TMP/sym2.out")"
grep -q 'already running' "$TMP/sym3.out" || fail "second symlink pass duplicated: $(cat "$TMP/sym3.out")"
if grep -q 'starting ' "$TMP/sym2.out" || grep -q 'replacing ' "$TMP/sym2.out"; then
  fail "real path tried to replace the symlink instance: $(cat "$TMP/sym2.out")"
fi
n=$(count_instances "$real/units/sshd-watchdog.sh")
[[ "$n" == 1 ]] || fail "symlink sshd watchdog count=$n"
sym_pid=$(wait_pidfile "$real/units/sshd-watchdog.sh") || fail "symlink watchdog wrote no pidfile"
box_access_pid_alive "$sym_pid" || fail "pidfile pid $sym_pid is dead"
[[ "$(count_instances "$link/units/sshd-watchdog.sh")" == 1 ]] || fail "link and real path see different instances"
echo "ok symlink and real path share one watchdog"

# Pidfile identity: command line has only the script basename. The open
# lock pidfile (reached through the symlink) is what names the checkout.
mkdir -p "$link/units/tailscale-watchdog.lock"
bash -c 'exec 9>"$1"; flock -n 9 || exit 1; printf "%s\n" "$$" >&9; trap "exit 0" TERM INT; while true; do sleep 30 9>&- & wait $! || true; done' \
  tailscale-watchdog.sh \
  "$link/units/tailscale-watchdog.lock/pid" &
holder=$!
got_holder=""
for _ in $(seq 1 50); do
  if [[ -d "/proc/$holder" ]] && box_access_watchdog_is_current "$real/units/tailscale-watchdog.sh"; then
    got_holder=$(box_access_pidfile_pid "$real/units/tailscale-watchdog.sh" || true)
    [[ "$got_holder" == "$holder" ]] && break
  fi
  sleep 0.05
done
[[ "$got_holder" == "$holder" ]] || fail "pidfile did not record the symlink holder (got ${got_holder:-none})"
ensure_watchdog "$real/units/tailscale-watchdog.sh" "tailscaled keep-alive" >"$TMP/pid.out"
grep -q 'already running' "$TMP/pid.out" || fail "pidfile holder was not treated as current: $(cat "$TMP/pid.out")"
if grep -q 'starting ' "$TMP/pid.out"; then
  fail "pidfile path started a second tailscale watchdog: $(cat "$TMP/pid.out")"
fi
box_access_pid_alive "$holder" || fail "pidfile holder was killed"
n=$(count_instances "$real/units/tailscale-watchdog.sh")
[[ "$n" == 1 ]] || fail "pidfile symlink count=$n"
echo "ok symlink pidfile does not start a second watchdog"

# --- old checkout, then a path that no longer exists ---

stop_watchdogs "$real/units/tailscale-watchdog.sh" "$real/units/sshd-watchdog.sh"
old=$TMP/old-checkout
install_stub "$old" "tailscale-watchdog.sh"
ensure_watchdog "$old/units/tailscale-watchdog.sh" "tailscaled keep-alive" >"$TMP/old-start.out"
old_pid=$(wait_pidfile "$old/units/tailscale-watchdog.sh") || fail "old watchdog did not write a pidfile"
ensure_watchdog "$real/units/tailscale-watchdog.sh" "tailscaled keep-alive" >"$TMP/old-replace.out"
grep -q "replacing tailscale-watchdog.sh pid=$old_pid" "$TMP/old-replace.out" || fail "old path was not replaced: $(cat "$TMP/old-replace.out")"
grep -q 'starting tailscaled keep-alive' "$TMP/old-replace.out" || fail "current watchdog was not started: $(cat "$TMP/old-replace.out")"
if box_access_pid_alive "$old_pid"; then
  fail "old watchdog pid $old_pid still running"
fi
n=$(count_instances "$real/units/tailscale-watchdog.sh")
[[ "$n" == 1 ]] || fail "after old-path replace count=$n"
cur_pid=$(wait_pidfile "$real/units/tailscale-watchdog.sh") || fail "current watchdog wrote no pidfile"
[[ "$cur_pid" != "$old_pid" ]] || fail "current pid is the old pid"
box_access_pid_alive "$cur_pid" || fail "current watchdog died"
echo "ok watchdog from the old checkout is replaced"

stop_watchdogs "$real/units/tailscale-watchdog.sh"
gone=$TMP/gone-checkout
install_stub "$gone" "tailscale-watchdog.sh"
ensure_watchdog "$gone/units/tailscale-watchdog.sh" "tailscaled keep-alive" >/dev/null
gone_pid=$(wait_pidfile "$gone/units/tailscale-watchdog.sh") || fail "gone watchdog did not start"
rm -rf "$gone"
ensure_watchdog "$real/units/tailscale-watchdog.sh" "tailscaled keep-alive" >"$TMP/gone-replace.out"
grep -q "replacing tailscale-watchdog.sh pid=$gone_pid" "$TMP/gone-replace.out" || fail "deleted path was not replaced: $(cat "$TMP/gone-replace.out")"
if box_access_pid_alive "$gone_pid"; then
  fail "deleted-path watchdog pid $gone_pid still running"
fi
n=$(count_instances "$real/units/tailscale-watchdog.sh")
[[ "$n" == 1 ]] || fail "after deleted-path replace count=$n"
echo "ok watchdog from a deleted path is replaced"

# --- sshd -E: replace the old listener, keep the session and the current one ---

stop_watchdogs "$real/units/sshd-watchdog.sh" "$real/units/tailscale-watchdog.sh"

old_log=$TMP/old-checkout/units/sshd.log
mkdir -p "$(dirname "$old_log")"
unit_link=$TMP/unit-link
ln -s "$(dirname "$(sshd_debug_log)")" "$unit_link"
current_log=$(sshd_debug_log)
link_log=$unit_link/sshd.log
missing_log=$TMP/missing/units/sshd.log
mkdir -p "$(dirname "$missing_log")"

python3 -c 'import time; time.sleep(120)' -E "$old_log" &
old_listener=$!
python3 -c 'import time; time.sleep(120)' -E "$missing_log" &
missing_listener=$!
python3 -c 'import time; time.sleep(120)' -E "$link_log" &
link_listener=$!
python3 -c 'import time; time.sleep(120)' -E "$current_log" &
current_listener=$!
python3 -c 'import time; time.sleep(120)' -- box-session &
session=$!
rm -rf "$TMP/missing"
sleep 0.1

export BOX_ACCESS_SS_TEXT="LISTEN 0 128 100.64.0.8:${SSH_PORT} 0.0.0.0:* users:((\"sshd\",pid=${old_listener},fd=3))
LISTEN 0 128 100.64.0.8:${SSH_PORT} 0.0.0.0:* users:((\"sshd\",pid=${missing_listener},fd=3))
LISTEN 0 128 100.64.0.8:${SSH_PORT} 0.0.0.0:* users:((\"sshd\",pid=${link_listener},fd=3))
LISTEN 0 128 100.64.0.8:${SSH_PORT} 0.0.0.0:* users:((\"sshd\",pid=${current_listener},fd=3))
LISTEN 0 128 100.64.0.8:${SSH_PORT} 0.0.0.0:* users:((\"sshd\",pid=${session},fd=4))"

foreign=$(box_access_foreign_sshd_pids "$current_log")
printf '%s\n' "$foreign" | grep -q "^${old_listener}$" || fail "old -E listener not foreign: $foreign"
printf '%s\n' "$foreign" | grep -q "^${missing_listener}$" || fail "deleted -E listener not foreign: $foreign"
if printf '%s\n' "$foreign" | grep -q "^${link_listener}$"; then
  fail "symlink -E was treated as foreign"
fi
if printf '%s\n' "$foreign" | grep -q "^${current_listener}$"; then
  fail "current -E was treated as foreign"
fi
if printf '%s\n' "$foreign" | grep -q "^${session}$"; then
  fail "session pid was treated as a foreign listener"
fi

box_access_stop_foreign_sshd_listeners "$current_log" >"$TMP/sshd-stop.out"
grep -q "stopping listener pid=$old_listener" "$TMP/sshd-stop.out" || fail "old listener was not stopped"
grep -q "stopping listener pid=$missing_listener" "$TMP/sshd-stop.out" || fail "deleted-path listener was not stopped"
grep -q 'not signaling sessions' "$TMP/sshd-stop.out" || fail "stop did not say sessions stay up"
if box_access_pid_alive "$old_listener"; then
  fail "old sshd listener still running"
fi
if box_access_pid_alive "$missing_listener"; then
  fail "deleted-path sshd listener still running"
fi
box_access_pid_alive "$link_listener" || fail "symlink -E listener was killed"
box_access_pid_alive "$current_listener" || fail "current -E listener was killed"
box_access_pid_alive "$session" || fail "SSH session was killed"
if grep -q "pid=$session" "$TMP/sshd-stop.out"; then
  fail "stop targeted the session pid"
fi
if grep -q "pid=$link_listener" "$TMP/sshd-stop.out" || grep -q "pid=$current_listener" "$TMP/sshd-stop.out"; then
  fail "stop targeted a listener from this checkout"
fi
echo "ok sshd from an old path is replaced and the session stays up"
