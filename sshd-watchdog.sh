#!/usr/bin/env bash
# Mantém sshd em <tailscale-ipv4>:2222. Depende do Tailscale já up.
# Não consome pool. Não toca na plataforma.
# Único listener sshd: o nosso. Host keys em $INFRA (fora do git).

set -u

INFRA=$(cd "$(dirname "$0")" && pwd)
LOG="$INFRA/sshd-watchdog.log"
LOCK_DIR="$INFRA/sshd-watchdog.lock"
BIN=/usr/sbin/sshd
PORT=2222
HOST_KEY="$INFRA/ssh_host_ed25519_key"
CFG="$INFRA/sshd_config.runtime"
MIN_BACKOFF=5
MAX_BACKOFF=60
DISTRO_HOST_KEY=/etc/ssh/ssh_host_ed25519_key

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"
}

mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/pid"
if ! flock -n 9; then
  echo "sshd-watchdog already running" >&2
  exit 0
fi
echo $$ >&9

backoff=$MIN_BACKOFF
log "watchdog start pid=$$"

sftp_server() {
  if [[ -x /usr/lib/openssh/sftp-server ]]; then
    printf '%s\n' /usr/lib/openssh/sftp-server
  elif [[ -x /usr/libexec/openssh/sftp-server ]]; then
    printf '%s\n' /usr/libexec/openssh/sftp-server
  else
    printf '%s\n' /usr/lib/openssh/sftp-server
  fi
}

disable_distro_sshd_units() {
  sudo systemctl disable --now ssh.socket sshd.socket ssh.service sshd.service >/dev/null 2>&1 || true
  sudo service ssh stop >/dev/null 2>&1 || true
  sudo service sshd stop >/dev/null 2>&1 || true
}

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

sshd_cmdline() {
  local pid=$1
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    tr '\0' ' ' <"/proc/${pid}/cmdline"
    return 0
  fi
  return 1
}

is_our_sshd_pid() {
  local pid=$1
  local cmd
  cmd=$(sshd_cmdline "$pid") || return 1
  [[ "$cmd" == *"$CFG"* ]]
}

listen_lines() {
  ss -H -lntp 2>/dev/null || ss -lntp 2>/dev/null || sudo ss -lntp 2>/dev/null || true
}

listen_addr_port() {
  local local_part addr port
  local_part=$(printf '%s\n' "$1" | awk '{print $4}')
  port=${local_part##*:}
  addr=${local_part%:*}
  addr=${addr#\[}
  addr=${addr%\]}
  printf '%s %s\n' "$addr" "$port"
}

our_sshd_listening() {
  local ip=$1
  local line pid addr port
  while IFS= read -r line; do
    [[ "$line" == *sshd* ]] || continue
    pid=$(printf '%s\n' "$line" | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2)
    [[ -n "${pid:-}" ]] || continue
    read -r addr port <<<"$(listen_addr_port "$line")"
    [[ "$addr" == "$ip" && "$port" == "$PORT" ]] || continue
    if is_our_sshd_pid "$pid"; then
      return 0
    fi
  done < <(listen_lines)
  return 1
}

kill_pid() {
  local pid=$1
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
  sudo kill "$pid" >/dev/null 2>&1 || true
  sleep 0.3
  if kill -0 "$pid" >/dev/null 2>&1; then
    sudo kill -9 "$pid" >/dev/null 2>&1 || true
  fi
}

# Qualquer sshd que não seja o nosso ${ip}:2222 sai. Inclui :22 da distro
# e o sshd antigo (cmdline sem sshd_config.runtime) — um corte na 2222.
stop_unwanted_sshd() {
  local keep_ip=${1:-}
  local line addr port pid
  while IFS= read -r line; do
    [[ "$line" == *sshd* ]] || continue
    pid=$(printf '%s\n' "$line" | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2)
    [[ -n "${pid:-}" ]] || continue
    read -r addr port <<<"$(listen_addr_port "$line")"
    if [[ -n "$keep_ip" && "$addr" == "$keep_ip" && "$port" == "$PORT" ]] && is_our_sshd_pid "$pid"; then
      continue
    fi
    log "stopping unwanted sshd pid=$pid listen=${addr}:${port}"
    kill_pid "$pid"
  done < <(listen_lines)
}

ensure_host_key() {
  if sudo test -f "$HOST_KEY"; then
    sudo chmod 600 "$HOST_KEY" >/dev/null 2>&1 || true
    if ! sudo test -f "${HOST_KEY}.pub"; then
      sudo ssh-keygen -y -f "$HOST_KEY" | sudo tee "${HOST_KEY}.pub" >/dev/null
      sudo chmod 644 "${HOST_KEY}.pub"
    fi
    sudo chown root:root "$HOST_KEY" "${HOST_KEY}.pub" >/dev/null 2>&1 || true
    return 0
  fi
  if sudo test -f "$DISTRO_HOST_KEY"; then
    log "host-key: copy $DISTRO_HOST_KEY -> $HOST_KEY"
    sudo cp "$DISTRO_HOST_KEY" "$HOST_KEY"
    if sudo test -f "${DISTRO_HOST_KEY}.pub"; then
      sudo cp "${DISTRO_HOST_KEY}.pub" "${HOST_KEY}.pub"
    else
      sudo ssh-keygen -y -f "$HOST_KEY" | sudo tee "${HOST_KEY}.pub" >/dev/null
    fi
  else
    log "host-key: generate $HOST_KEY"
    sudo ssh-keygen -q -t ed25519 -f "$HOST_KEY" -N "" -C "box-infra"
  fi
  sudo chmod 600 "$HOST_KEY"
  sudo chmod 644 "${HOST_KEY}.pub" >/dev/null 2>&1 || true
  sudo chown root:root "$HOST_KEY" "${HOST_KEY}.pub" >/dev/null 2>&1 || true
}

write_sshd_config() {
  local ip=$1
  local pam=$2
  local sftp
  sftp=$(sftp_server)
  cat >"$CFG" <<EOF
# gerado pelo sshd-watchdog — não incluir /etc/ssh/sshd_config
AddressFamily inet
Port ${PORT}
ListenAddress ${ip}
HostKey ${HOST_KEY}
PidFile ${INFRA}/sshd.pid
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM ${pam}
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp ${sftp}
EOF
}

prepare_sshd_config() {
  local ip=$1
  write_sshd_config "$ip" yes
  if sudo "$BIN" -t -f "$CFG" >/dev/null 2>&1; then
    return 0
  fi
  log "WARN: sshd -t com UsePAM yes falhou; tentando UsePAM no"
  write_sshd_config "$ip" no
  if sudo "$BIN" -t -f "$CFG" >/dev/null 2>&1; then
    return 0
  fi
  log "WARN: sshd -t ainda falhou; vou tentar iniciar mesmo assim"
  return 0
}

wait_for_tailscale() {
  local n=0
  while ! pgrep -x tailscaled >/dev/null 2>&1; do
    log "waiting for tailscaled..."
    sleep 3
    n=$((n+1))
    if (( n > 40 )); then
      log "ERROR: tailscaled still down after wait"
      return 1
    fi
  done
  n=0
  while true; do
    local ip
    ip=$(tailscale_ip) || ip=""
    if [[ -n "$ip" ]] && ip -4 addr show tailscale0 2>/dev/null | grep -q "inet ${ip}/"; then
      printf '%s\n' "$ip"
      return 0
    fi
    log "waiting for tailscale0 address (got=${ip:-none})..."
    sleep 3
    n=$((n+1))
    if (( n > 40 )); then
      log "ERROR: no tailscale IP yet"
      return 1
    fi
  done
}

start_sshd() {
  local ip=$1
  if [[ ! -x "$BIN" ]]; then
    log "ERROR: missing $BIN"
    return 1
  fi
  ensure_host_key
  prepare_sshd_config "$ip"
  sudo setsid "$BIN" -D -e -f "$CFG" >>"$LOG" 2>&1 &
  local pid=$!
  sleep 1
  if our_sshd_listening "$ip"; then
    log "started sshd ListenAddress=$ip:$PORT (spawn_pid=$pid)"
    return 0
  fi
  log "ERROR: sshd not listening on $ip:$PORT after start"
  return 1
}

disable_distro_sshd_units

while true; do
  ip=$(wait_for_tailscale) || {
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
    continue
  }

  ensure_host_key
  prepare_sshd_config "$ip"
  stop_unwanted_sshd "$ip"

  if our_sshd_listening "$ip"; then
    backoff=$MIN_BACKOFF
    log "adopting existing listener on $ip:$PORT"
    while our_sshd_listening "$ip"; do
      stop_unwanted_sshd "$ip"
      sleep 5
    done
    log "listener on $ip:$PORT gone; will restart"
  else
    log "no listener on $ip:$PORT; starting sshd"
    if start_sshd "$ip"; then
      backoff=$MIN_BACKOFF
      continue
    fi
    log "start failed; sleep ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
  fi
done
