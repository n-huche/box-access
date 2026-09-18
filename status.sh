#!/usr/bin/env bash
# Uma página: a box está acessível? (tailscaled, IP, sshd :2222, watchdogs, host key)
# Não toca em processos. Exit 0 só se o acesso está ok.

set -u

HOME_BOX="${HOME_BOX:-/home/box}"
INFRA="${HOME_BOX}/infra"
PORT=2222
HOST_KEY="$INFRA/ssh_host_ed25519_key"
CFG="$INFRA/sshd_config.runtime"

ok=1
sshd_ok=0
ts_ok=0
ip=""

listen_lines() {
  ss -H -lntp 2>/dev/null || ss -lntp 2>/dev/null || sudo -n ss -lntp 2>/dev/null || true
}

pid_alive() {
  local pid=${1:-}
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" >/dev/null 2>&1
}

cmdline_of() {
  local pid=$1
  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  tr '\0' ' ' <"/proc/${pid}/cmdline"
}

cmdline_has_argv() {
  local pid=$1 want=$2
  [[ -r "/proc/${pid}/cmdline" ]] || return 1
  tr '\0' '\n' <"/proc/${pid}/cmdline" | grep -Fxq "$want"
}

watchdog_pid() {
  local name=$1
  local want="${INFRA}/${name}.sh"
  local file="$INFRA/${name}.lock/pid"
  local pid
  if [[ -r "$file" ]]; then
    pid=$(tr -d '[:space:]' <"$file")
    if pid_alive "$pid" && cmdline_has_argv "$pid" "$want"; then
      printf '%s\n' "$pid"
      return 0
    fi
  fi
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    pid_alive "$pid" || continue
    cmdline_has_argv "$pid" "$want" || continue
    printf '%s\n' "$pid"
    return 0
  done < <(pgrep -f "$want" 2>/dev/null || true)
  return 1
}

# --- tailscaled ---
ts_pid=$(pgrep -x tailscaled 2>/dev/null | head -n1 || true)
if pid_alive "${ts_pid:-}"; then
  ts_ok=1
  printf 'tailscaled: up pid=%s\n' "$ts_pid"
else
  ok=0
  printf 'tailscaled: down\n'
fi

ip=$(sudo -n tailscale ip -4 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
if [[ -z "$ip" ]]; then
  ip=$(ip -4 -o addr show tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)
fi
if [[ -n "$ip" ]]; then
  printf 'tailscale-ip: %s\n' "$ip"
else
  ok=0
  printf 'tailscale-ip: none\n'
fi

# --- sshd ---
extra=0
our_pid=""
while IFS= read -r line; do
  [[ "$line" == *sshd* ]] || continue
  pid=$(printf '%s\n' "$line" | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2)
  local_part=$(printf '%s\n' "$line" | awk '{print $4}')
  port=${local_part##*:}
  addr=${local_part%:*}
  addr=${addr#\[}
  addr=${addr%\]}
  cmd=""
  if [[ -n "${pid:-}" ]]; then
    cmd=$(cmdline_of "$pid" 2>/dev/null || true)
  fi
  our=no
  [[ "$cmd" == *"$CFG"* ]] && our=yes
  if [[ -n "$ip" && "$addr" == "$ip" && "$port" == "$PORT" && "$our" == yes ]]; then
    our_pid=$pid
    sshd_ok=1
    printf 'sshd: listening %s:%s pid=%s our=yes\n' "$addr" "$port" "$pid"
  else
    extra=1
    printf 'sshd-extra: %s:%s pid=%s our=%s\n' "$addr" "$port" "${pid:-?}" "$our"
  fi
done < <(listen_lines)

if [[ "$sshd_ok" -eq 0 ]]; then
  ok=0
  if [[ -n "$ip" ]]; then
    printf 'sshd: not listening %s:%s\n' "$ip" "$PORT"
  else
    printf 'sshd: not listening (sem IP Tailscale)\n'
  fi
fi
if [[ "$extra" -eq 1 ]]; then
  ok=0
else
  printf 'sshd-extra: none\n'
fi

# --- watchdogs ---
tsw=$(watchdog_pid tailscale-watchdog || true)
if [[ -n "${tsw:-}" ]]; then
  printf 'tailscale-watchdog: up pid=%s\n' "$tsw"
else
  ok=0
  printf 'tailscale-watchdog: down\n'
fi
ssw=$(watchdog_pid sshd-watchdog || true)
if [[ -n "${ssw:-}" ]]; then
  printf 'sshd-watchdog: up pid=%s\n' "$ssw"
else
  ok=0
  printf 'sshd-watchdog: down\n'
fi

# --- host key ---
if [[ -r "${HOST_KEY}.pub" ]]; then
  fp=$(ssh-keygen -l -f "${HOST_KEY}.pub" 2>/dev/null | awk '{print $2}' || true)
  printf 'host-key: %s %s\n' "${fp:-unknown}" "$HOST_KEY"
elif sudo -n test -f "$HOST_KEY" 2>/dev/null; then
  fp=$(sudo -n ssh-keygen -l -f "$HOST_KEY" 2>/dev/null | awk '{print $2}' || true)
  printf 'host-key: %s %s\n' "${fp:-unknown}" "$HOST_KEY"
else
  printf 'host-key: missing %s\n' "$HOST_KEY"
fi

# --- cron ---
if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q "${HOME_BOX}/start.sh"; then
  printf 'cron-reboot: present\n'
else
  printf 'cron-reboot: absent (best-effort)\n'
fi

if [[ "$ok" -eq 1 && "$ts_ok" -eq 1 && "$sshd_ok" -eq 1 ]]; then
  printf 'acesso: ok\n'
  exit 0
fi
if [[ "$sshd_ok" -eq 1 && "$ts_ok" -eq 1 ]]; then
  printf 'acesso: degradado\n'
  exit 1
fi
printf 'acesso: fail\n'
exit 1
