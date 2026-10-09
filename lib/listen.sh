# Tailscale IPv4 and sshd listen helpers.
# Safe to source from lib/common.sh, lib/tailscale-health.sh, and units/sshd-watchdog.sh.
# Constants and functions only: no apt, no secrets, no `set -e`, no daemons.

if [[ -z "${BOX_ACCESS_LISTEN_LOADED:-}" ]]; then
  BOX_ACCESS_LISTEN_LOADED=1
  # sshd for this box. Port 22 stays closed (see stop_port22_sshd).
  SSH_PORT="${SSH_PORT:-2222}"
  # Shared by steps/08-sshd.sh and units/sshd-watchdog.sh.
  # 40 * 3s is about 2 minutes.
  SSH_IPV4_WAIT_INTERVAL="${SSH_IPV4_WAIT_INTERVAL:-3}"
  SSH_IPV4_WAIT_TRIES="${SSH_IPV4_WAIT_TRIES:-40}"
fi

tailscale_ip() {
  local ip
  ip=$(sudo tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  ip=$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  if [[ -n "$ip" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  return 1
}

# Accept a dotted IPv4 that can be a Tailscale address.
# Reject empty, 0.0.0.0, and 127.0.0.1. Callers also require the address
# to be configured on tailscale0 before sshd binds it.
valid_listen_ip() {
  local ip=$1
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  case "$ip" in
    0.0.0.0|127.0.0.1) return 1 ;;
  esac
  return 0
}

# sshd -E file. SSHD_DEBUG_LOG overrides it. units/sshd.log sits with the
# other gitignored logs. A running sshd keeps this path only after it starts.
sshd_debug_log() {
  if [[ -n "${SSHD_DEBUG_LOG:-}" ]]; then
    printf '%s\n' "$SSHD_DEBUG_LOG"
    return
  fi
  local root
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  printf '%s\n' "$root/units/sshd.log"
}

# True when sshd is listening on $1:$SSH_PORT. Does not look at port 22.
sshd_listening() {
  local ip=$1
  local esc=${ip//./\\.}
  ss -lnt 2>/dev/null | grep -qE "${esc}:${SSH_PORT}\\b"
}

# Print pids of sshd listening on port 22, any address.
# BOX_ACCESS_SS22_TEXT, when set, replaces `ss` output (tests only).
port22_sshd_pids() {
  local ss_text="${BOX_ACCESS_SS22_TEXT-}"
  if [[ -z "$ss_text" ]]; then
    ss_text=$(sudo ss -lptn 'sport = :22' 2>/dev/null || true)
  fi
  grep -E ':22[[:space:]]' <<<"$ss_text" | grep -F '"sshd"' \
    | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true
}

# This box is reached on <tailscale-ipv4>:$SSH_PORT only: stop any sshd on
# port 22 (a package sshd listens on 0.0.0.0:22). Prints each stopped pid.
stop_port22_sshd() {
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    sudo kill "$pid" 2>/dev/null || true
    printf '%s\n' "$pid"
  done < <(port22_sshd_pids 9>&-)
}

# Pids, other than this shell, that have $1 open. sudo so a root-held fd
# (leaked from `sudo setsid`) is visible. Callers pass 9>&- so the scan
# itself does not show up as a holder of the watchdog lock.
watchdog_lock_holder_pids() {
  local target=$1
  sudo python3 -c '
import os, sys
target = os.path.realpath(sys.argv[1])
skip = set()
for arg in sys.argv[2:]:
    if arg.isdigit():
        skip.add(int(arg))
st_target = os.stat(target)
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    pid = int(name)
    if pid in skip:
        continue
    fd_dir = "/proc/%d/fd" % pid
    try:
        fds = os.listdir(fd_dir)
    except OSError:
        continue
    for fd in fds:
        path = os.path.join(fd_dir, fd)
        try:
            st = os.stat(path)
        except OSError:
            continue
        if st.st_dev == st_target.st_dev and st.st_ino == st_target.st_ino:
            print(pid)
            break
' "$target" "$$" 9>&-
}

# True when pid's command line is the watchdog script (a live loop, not a leak).
watchdog_pid_is_script() {
  local pid=$1 script=$2 cmd
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
  [[ "$cmd" == *"$script"* ]]
}

# Take the watchdog lock on fd 9 ($LOCK_DIR/pid). Returns 0 when this process
# holds it. Returns 1 when another copy of $1 already holds it (caller exits 0).
# A lock held by anything else (sudo, tailscaled, sshd, sleep) is a leak:
# rename pid to pid.stale-<pid> and lock a new file. Leftover pid.stale-* names
# are removed once we hold it. Children must still be started with 9>&- so
# they do not keep the flock.
watchdog_acquire_lock() {
  local script=$1 attempt=0 holder="" pid live
  mkdir -p -- "$LOCK_DIR"
  while (( attempt < 2 )); do
    attempt=$((attempt + 1))
    exec 9>"$LOCK_DIR/pid"
    if flock -n 9; then
      printf '%s\n' "$$" >&9
      rm -f -- "$LOCK_DIR"/pid.stale-*
      return 0
    fi
    live=0
    holder=""
    while read -r pid; do
      [[ -n "$pid" ]] || continue
      if watchdog_pid_is_script "$pid" "$script"; then
        live=1
        break
      fi
      holder=$pid
    done < <(watchdog_lock_holder_pids "$LOCK_DIR/pid" "$$" "${BASHPID:-$$}" 9>&-)
    exec 9>&-
    if [[ "$live" -eq 1 || -z "$holder" ]]; then
      echo "${script%.sh} already running" >&2
      return 1
    fi
    echo "${script%.sh}: lock held by pid $holder (not $script); moving it aside" >&2
    mv -f -- "$LOCK_DIR/pid" "$LOCK_DIR/pid.stale-$holder" || true
  done
  echo "${script%.sh} already running" >&2
  return 1
}
