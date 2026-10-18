# Tailscale IPv4 and sshd listen helpers.
# Safe to source from lib/common.sh, lib/tailscale-health.sh, and units/sshd-watchdog.sh.
# Constants and functions only: no apt, no secrets, no `set -e`.
# Sourcing does not start daemons. box_access_ensure_watchdog starts one
# keep-alive when up.sh calls it.

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
# other gitignored logs, next to this checkout (realpath of this file).
# A running sshd keeps the path it was started with until up.sh replaces it.
sshd_debug_log() {
  if [[ -n "${SSHD_DEBUG_LOG:-}" ]]; then
    printf '%s\n' "$SSHD_DEBUG_LOG"
    return
  fi
  local root
  root=$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")
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

# Canonical path of a script or log, even when the last component is missing
# or the path is a symlink. Callers compare this, never a hardcoded checkout.
box_access_script_canon() {
  realpath -m -- "$1"
}

box_access_pid_alive() {
  [[ -d "/proc/${1}" ]]
}

# Lock pidfile beside a watchdog script: units/<name>.lock/pid.
box_access_pidfile_for() {
  local canon
  canon=$(box_access_script_canon "$1")
  printf '%s\n' "$(dirname -- "$canon")/$(basename -- "$canon" .sh).lock/pid"
}

# Pid recorded by the watchdog, if that file is still readable.
box_access_pidfile_pid() {
  local file pid
  file=$(box_access_pidfile_for "$1")
  [[ -f "$file" ]] || return 1
  pid=$(awk 'NR==1 { print; exit }' "$file" | tr -cd '0-9' || true)
  [[ -n "$pid" ]] || return 1
  printf '%s\n' "$pid"
}

# One line per watchdog process: pid, tab, canonical script path.
# A process counts when its command line names the script. The path is
# realpath of that argument (cwd for a relative path). If the command line
# has only the basename, the open units/<name>.lock/pid fd is the checkout:
# realpath of that pidfile follows symlinks and still works after the
# directory is deleted. Leaked tailscaled/sshd/sudo fds are ignored.
box_access_watchdog_instances() {
  local script=$1 needle
  needle=$(basename -- "$script")
  python3 - "$needle" "$$" "${BASHPID:-$$}" <<'PY'
import os
import sys

needle = sys.argv[1]
proc_root = os.environ.get("BOX_ACCESS_PROC", "/proc")
skip = set()
for arg in sys.argv[2:]:
    if arg.isdigit():
        skip.add(int(arg))
skip.add(os.getpid())

def read_ppid(pid):
    try:
        text = open(os.path.join(proc_root, str(pid), "status"), "r").read()
    except OSError:
        return 0
    for line in text.splitlines():
        if line.startswith("PPid:"):
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                return int(parts[1])
    return 0

cur = os.getppid()
seen = set()
while cur > 1 and cur not in seen:
    seen.add(cur)
    skip.add(cur)
    cur = read_ppid(cur)

def canon(path):
    if not path:
        return ""
    suffix = " (deleted)"
    if path.endswith(suffix):
        path = path[: -len(suffix)]
    try:
        return os.path.realpath(path)
    except OSError:
        return os.path.abspath(path)

def cmdline(pid):
    try:
        raw = open(os.path.join(proc_root, str(pid), "cmdline"), "rb").read()
    except OSError:
        return []
    return [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]

def comm_of(pid):
    try:
        return open(os.path.join(proc_root, str(pid), "comm"), "r").read().strip()
    except OSError:
        return ""

def cwd_of(pid):
    try:
        cwd = os.readlink(os.path.join(proc_root, str(pid), "cwd"))
    except OSError:
        return "/"
    suffix = " (deleted)"
    if cwd.endswith(suffix):
        cwd = cwd[: -len(suffix)]
    return cwd or "/"

def looks_like_watchdog(comm, parts):
    if not parts:
        return False
    argv0 = os.path.basename(parts[0])
    shells = {"bash", "sh", "dash"}
    # comm is at most 15 characters. A shebang script often shows up as the
    # truncated script name; a shell shows up as bash and names the script
    # in an argument.
    if argv0 == needle or (comm and comm.startswith(needle[:15])):
        return True
    if comm in shells or argv0 in shells:
        return any(os.path.basename(part) == needle for part in parts)
    return False

lock_suffix = "/" + (needle[:-3] if needle.endswith(".sh") else needle) + ".lock/pid"

def lock_target(pid):
    fd_dir = os.path.join(proc_root, str(pid), "fd")
    try:
        names = os.listdir(fd_dir)
    except OSError:
        return ""
    for name in names:
        try:
            target = os.readlink(os.path.join(fd_dir, name))
        except OSError:
            continue
        raw = target[: -len(" (deleted)")] if target.endswith(" (deleted)") else target
        if raw.endswith(lock_suffix):
            return target
    return ""

def ident_from_lock(target):
    raw = target[: -len(" (deleted)")] if target.endswith(" (deleted)") else target
    unit_dir = os.path.dirname(os.path.dirname(raw))
    return canon(os.path.join(unit_dir, needle))

def identity(pid, parts, lock):
    absolute = ""
    relative = ""
    for part in parts:
        if os.path.basename(part) != needle:
            continue
        if os.path.isabs(part):
            absolute = part
            break
        if not relative:
            relative = part
    if absolute:
        return canon(absolute)
    if lock:
        return ident_from_lock(lock)
    if relative:
        return canon(os.path.join(cwd_of(pid), relative))
    return ""

try:
    names = os.listdir(proc_root)
except OSError:
    names = []

seen_pid = set()
for name in names:
    if not name.isdigit():
        continue
    pid = int(name)
    if pid in skip or pid in seen_pid:
        continue
    parts = cmdline(pid)
    if not looks_like_watchdog(comm_of(pid), parts):
        continue
    ident = identity(pid, parts, lock_target(pid))
    if not ident:
        continue
    seen_pid.add(pid)
    sys.stdout.write("%d\t%s\n" % (pid, ident))
PY
}

# True when a live watchdog's script realpath is this file.
# The lock pidfile is the on-disk record of that pid for this checkout.
# A matching realpath with no pidfile yet (just forked) is the same instance.
box_access_watchdog_is_current() {
  local script=$1 canon pid ident recorded=""
  canon=$(box_access_script_canon "$script")
  recorded=$(box_access_pidfile_pid "$script" || true)
  if [[ -n "$recorded" ]] && box_access_pid_alive "$recorded"; then
    while IFS=$'\t' read -r pid ident; do
      if [[ "$pid" == "$recorded" && "$ident" == "$canon" ]]; then
        return 0
      fi
    done < <(box_access_watchdog_instances "$script")
  fi
  while IFS=$'\t' read -r pid ident; do
    [[ -n "${pid:-}" ]] || continue
    [[ "$ident" == "$canon" ]] || continue
    box_access_pid_alive "$pid" || continue
    return 0
  done < <(box_access_watchdog_instances "$script")
  return 1
}

# Signal one pid. SIGTERM, then SIGKILL if it is still there.
# The pid is the watchdog or the sshd listener, never a process group,
# so an SSH session (a different pid) is not signaled.
box_access_stop_pid() {
  local pid=$1 n=0
  if [[ ! "$pid" =~ ^[0-9]+$ ]] || (( pid <= 1 )); then
    return 0
  fi
  if [[ "$pid" -eq $$ || "$pid" -eq ${BASHPID:-$$} ]]; then
    return 0
  fi
  if ! box_access_pid_alive "$pid"; then
    return 0
  fi
  if ! kill -TERM "$pid" 2>/dev/null; then
    sudo kill -TERM "$pid" 2>/dev/null || true
  fi
  while box_access_pid_alive "$pid" && (( n < 25 )); do
    sleep 0.1
    n=$((n + 1))
  done
  if box_access_pid_alive "$pid"; then
    if ! kill -KILL "$pid" 2>/dev/null; then
      sudo kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
}

# Stop watchdogs whose script is not this file. Same realpath (symlink or
# the real directory) is kept. Another checkout, or a deleted path, is stopped.
box_access_retire_other_watchdogs() {
  local script=$1 canon pid ident
  canon=$(box_access_script_canon "$script")
  while IFS=$'\t' read -r pid ident; do
    [[ -n "${pid:-}" ]] || continue
    if [[ "$ident" == "$canon" ]]; then
      continue
    fi
    echo "watchdog: replacing $(basename -- "$script") pid=$pid (running from ${ident})"
    box_access_stop_pid "$pid"
  done < <(box_access_watchdog_instances "$script")
}

# Start $1 unless this checkout's copy is already running.
# Retires a copy from any other path first, so the two never both stay up.
box_access_ensure_watchdog() {
  local script=$1
  local label=${2:-$(basename -- "$script")}
  local n=0
  box_access_retire_other_watchdogs "$script"
  if box_access_watchdog_is_current "$script"; then
    echo "watchdog: $label already running ($script)"
    return 0
  fi
  echo "watchdog: starting $label ($script)"
  nohup "$script" >/dev/null 2>&1 &
  while (( n < 30 )); do
    if box_access_watchdog_is_current "$script"; then
      break
    fi
    sleep 0.05
    n=$((n + 1))
  done
  if [[ "${BOX_ACCESS_WATCHDOG_START_WAIT:-0}" != 0 ]]; then
    sleep "$BOX_ACCESS_WATCHDOG_START_WAIT"
  fi
}

box_access_listen_text() {
  if [[ -n "${BOX_ACCESS_SS_TEXT+x}" ]]; then
    printf '%s\n' "$BOX_ACCESS_SS_TEXT"
    return 0
  fi
  ss -lptn "sport = :${SSH_PORT}" 2>/dev/null \
    || sudo ss -lptn "sport = :${SSH_PORT}" 2>/dev/null \
    || true
}

# Listener pids on SSH_PORT whose -E path is not the current log.
# No -E means "not our checkout": leave it (and any session pid) alone.
# realpath -m so a deleted log path still compares unequal to this checkout.
box_access_foreign_sshd_pids() {
  local current
  current=$(box_access_script_canon "$1")
  BOX_ACCESS_SSHD_CURRENT=$current \
    BOX_ACCESS_SSHD_SS_TEXT=$(box_access_listen_text) \
    python3 - <<'PY'
import os
import re
import sys

current = os.environ.get("BOX_ACCESS_SSHD_CURRENT", "")
text = os.environ.get("BOX_ACCESS_SSHD_SS_TEXT", "")
proc_root = os.environ.get("BOX_ACCESS_PROC", "/proc")

def canon(path):
    if path.endswith(" (deleted)"):
        path = path[: -len(" (deleted)")]
    try:
        return os.path.realpath(path)
    except OSError:
        return os.path.abspath(path)

def cmdline(pid):
    try:
        raw = open(os.path.join(proc_root, str(pid), "cmdline"), "rb").read()
    except OSError:
        return []
    return [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]

def debug_log(parts):
    for i, part in enumerate(parts):
        if part == "-E" and i + 1 < len(parts):
            return parts[i + 1]
        if part.startswith("-E") and part != "-E":
            return part[2:]
    return ""

seen = []
for match in re.finditer(r"pid=(\d+)", text):
    pid = int(match.group(1))
    if pid not in seen:
        seen.append(pid)

for pid in seen:
    parts = cmdline(pid)
    elog = debug_log(parts)
    if not elog:
        continue
    if not os.path.isabs(elog):
        try:
            cwd = os.readlink(os.path.join(proc_root, str(pid), "cwd"))
        except OSError:
            cwd = "/"
        if cwd.endswith(" (deleted)"):
            cwd = cwd[: -len(" (deleted)")]
        elog = os.path.join(cwd or "/", elog)
    if canon(elog) == current:
        continue
    sys.stdout.write("%d\n" % pid)
PY
}

# Stop listeners started from another checkout. Only those pids are signaled.
box_access_stop_foreign_sshd_listeners() {
  local current=$1 pid
  while IFS= read -r pid; do
    [[ -n "${pid:-}" ]] || continue
    echo "ssh: stopping listener pid=$pid from another checkout; not signaling sessions"
    box_access_stop_pid "$pid"
  done < <(box_access_foreign_sshd_pids "$current")
}
