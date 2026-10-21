#!/usr/bin/env bash
# Explicit tailscale socket, daemon-unreachable vs bad-key errors, purge only
# after auth, and /run/sshd before sshd. Mock sudo and tailscale; no daemons,
# no network, no secrets. Nothing outside $TMP is written.
set -euo pipefail

ROOT=$(realpath "$(dirname "$0")/..")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL $*"
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/home"
export FAKE_TS_LOG=$TMP/ts.log SUDO_LOG=$TMP/sudo.log
cat > "$TMP/bin/sudo" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SUDO_LOG:?}"
exec "$@"
EOF2
cat > "$TMP/bin/tailscale" <<'EOF2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_TS_LOG:?}"
[[ "${1:-}" == --socket=* ]] && shift
cmd=${1:-}
case "$cmd" in
  status)
    if [[ -n "${FAKE_STATUS_ERR:-}" ]]; then
      printf '%s\n' "$FAKE_STATUS_ERR" >&2
      exit 1
    fi
    printf '{"BackendState":"%s","Self":{"Online":true}}\n' "${FAKE_BACKEND:-Running}"
    ;;
  ip) [[ -n "${FAKE_IP:-}" ]] && printf '%s\n' "$FAKE_IP" ;;
  up)
    if [[ -n "${FAKE_UP_ERR:-}" ]]; then
      printf '%s\n' "$FAKE_UP_ERR" >&2
      exit 1
    fi
    ;;
esac
exit 0
EOF2
# No tailscale0 fallback from the host: the IPv4 comes from the fake CLI only.
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/ip"
chmod 755 "$TMP/bin/sudo" "$TMP/bin/tailscale" "$TMP/bin/ip"
export PATH="$TMP/bin:$PATH"

export HOME_BOX=$TMP/home
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=../steps/03-tailscaled.sh
source "$ROOT/steps/03-tailscaled.sh"
# shellcheck source=../steps/04-auth.sh
source "$ROOT/steps/04-auth.sh"
SOCKET=$TMP/run/tailscale/tailscaled.sock
mkdir -p "$(dirname "$SOCKET")"
make_socket() {
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$SOCKET"
}

# --- (a) every CLI call passes --socket ---
[[ "$(env -u SOCKET bash -c 'source "$1"; tailscale_socket' _ "$ROOT/lib/listen.sh")" == /run/tailscale/tailscaled.sock ]] \
  || fail "default socket is not /run/tailscale/tailscaled.sock"
: > "$FAKE_TS_LOG"
FAKE_IP=100.64.0.9 tailscale_ip >/dev/null
tailscale_read_status
tailscale_backend_state >/dev/null
tailscale_status_logged_out || true
FAKE_BACKEND=Stopped TS_HOSTNAME=cursor ensure_tailscale_up_if_down >/dev/null
tailscale_as_root status --json >/dev/null
BOX_ACCESS_NOSUDO=1 tailscale_as_root status --json >/dev/null
read_tailscale_status_fields
set_tailscale_hostname cursor
[[ "$(wc -l < "$FAKE_TS_LOG")" -ge 9 ]] || fail "expected at least 9 CLI calls, got $(wc -l < "$FAKE_TS_LOG")"
if grep -v -- "^--socket=$SOCKET " "$FAKE_TS_LOG"; then
  fail "a tailscale CLI call did not pass --socket=$SOCKET"
fi
grep -q -- "^--socket=$SOCKET up --hostname=cursor" "$FAKE_TS_LOG" || fail "ensure_tailscale_up_if_down did not run up"
echo "ok every tailscale CLI call passes --socket"

bare=$(grep -R -n -E '(^|[;|&(]|\$\()[[:space:]]*(sudo[[:space:]]+)?tailscale[[:space:]]+(status|ip|up|down|set|login|logout|debug)\b' \
  "$ROOT/lib" "$ROOT/steps" "$ROOT/units" | grep -v -E ':[0-9]+:[[:space:]]*#' || true)
[[ -z "$bare" ]] || fail "tailscale CLI called without ts_cli: $bare"
echo "ok no tailscale CLI call bypasses ts_cli"

# --- (d) daemon unreachable vs bad auth key ---
export TS_AUTHKEY='tskey-auth-testsecret1' TS_HOSTNAME=cursor
run_auth() {
  set +e
  out=$( (tailscale_up_with_auth) </dev/null 2>&1 )
  rc=$?
  set -e
}

rm -f "$SOCKET"; : > "$FAKE_TS_LOG"
run_auth
[[ "$rc" -eq 3 ]] || fail "missing socket status was $rc, want 3: $out"
grep -q 'tailscaled is not reachable' <<<"$out" || fail "missing socket not reported: $out"
grep -q 'TS_AUTHKEY invalid' <<<"$out" && fail "missing socket was reported as a bad key: $out"
grep -q -- ' up ' "$FAKE_TS_LOG" && fail "tailscale up ran without a reachable daemon"
echo "ok a missing socket is a daemon error (status 3), not a bad key"

make_socket; : > "$FAKE_TS_LOG"
FAKE_STATUS_ERR='failed to connect to local tailscaled; it doesn'"'"'t appear to be running' run_auth
[[ "$rc" -eq 3 ]] || fail "daemon not answering status was $rc, want 3: $out"
echo "ok a socket with no daemon behind it is status 3"

: > "$FAKE_TS_LOG"
FAKE_UP_ERR='failed to connect to local tailscaled (dial unix /var/run/tailscale/tailscaled.sock: connect: no such file or directory)' run_auth
[[ "$rc" -eq 3 ]] || fail "dial error from up was $rc, want 3: $out"
grep -q 'not an auth key problem' <<<"$out" || fail "dial error from up was not called a daemon problem: $out"
echo "ok a dial error from tailscale up is status 3"

: > "$FAKE_TS_LOG"
FAKE_UP_ERR="backend error: invalid key: API key ${TS_AUTHKEY} not valid" run_auth
[[ "$rc" -eq 1 ]] || fail "bad key status was $rc, want 1: $out"
grep -q 'TS_AUTHKEY invalid' <<<"$out" || fail "bad key not reported: $out"
grep -q 'not reachable' <<<"$out" && fail "bad key was reported as a daemon error: $out"
grep -qF "$TS_AUTHKEY" <<<"$out" && fail "the auth key was printed"
grep -qF -- "--socket=$SOCKET up" <<<"$out" || fail "next-step hint lacks --socket: $out"
echo "ok a rejected key is status 1, redacted, with a --socket hint"

: > "$FAKE_TS_LOG"
run_auth
[[ "$rc" -eq 0 ]] || fail "good auth status was $rc: $out"
echo "ok a reachable daemon and a good key authenticate"

# --- (c) auth before purge; purge waits for Running + IPv4 ---
order=$(grep -oE 'steps/0[45]-[a-z]+\.sh' "$ROOT/up.sh" | tr '\n' ' ')
[[ "$order" == "steps/04-auth.sh steps/05-purge.sh " ]] || fail "auth must run before purge: $order"
# shellcheck source=../steps/05-purge.sh
source "$ROOT/steps/05-purge.sh"
PURGED=$TMP/purged
ensure_secrets_for_recovery() { :; }
prepare_purge_self_markers() { :; }
try_purge_stale_hostname() { : > "$PURGED"; }
export TS_PURGE_WAIT_TRIES=2 TS_PURGE_WAIT_INTERVAL=0
TS_RECOVERY_REASON=state-missing

rm -f "$PURGED"
set +e
out=$(FAKE_BACKEND=NeedsLogin FAKE_IP=100.64.0.9 step_purge 2>&1)
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "purge on a node that is not up returned $rc"
[[ ! -e "$PURGED" ]] || fail "purge ran while the node was not Running"
grep -q 'purge: skipped' <<<"$out" || fail "skipped purge not reported: $out"

out=$(FAKE_BACKEND=Running FAKE_IP='' step_purge 2>&1)
[[ ! -e "$PURGED" ]] || fail "purge ran while the node had no IPv4"

out=$(FAKE_BACKEND=Running FAKE_IP=100.64.0.9 step_purge 2>&1)
[[ -e "$PURGED" ]] || fail "purge did not run once the node was Running with an IPv4: $out"
echo "ok purge runs only after the node is Running with an IPv4"

# --- (b) /run/sshd before sshd ---
export SSHD_PRIVSEP_DIR=$TMP/run/sshd
: > "$SUDO_LOG"
ensure_sshd_privsep_dir
[[ -d "$SSHD_PRIVSEP_DIR" ]] || fail "privsep dir not created"
[[ "$(stat -c %a "$SSHD_PRIVSEP_DIR")" == 755 ]] || fail "privsep dir mode $(stat -c %a "$SSHD_PRIVSEP_DIR")"
grep -qx "install -d -m 0755 $SSHD_PRIVSEP_DIR" "$SUDO_LOG" || fail "privsep dir not made with install -d -m 0755"
: > "$SUDO_LOG"
ensure_sshd_privsep_dir
grep -q '^install' "$SUDO_LOG" && fail "existing privsep dir was recreated"
echo "ok /run/sshd is created 0755 and left alone when present"

rmdir "$SSHD_PRIVSEP_DIR"
export SSHD_STARTED=$TMP/sshd-started
cat > "$TMP/bin/sshd-fake" <<'EOF2'
#!/usr/bin/env bash
if [[ "${1:-}" == "-t" ]]; then
  if [[ -n "${FAKE_SSHD_T_ERR:-}" ]]; then
    echo "$FAKE_SSHD_T_ERR" >&2
    exit 255
  fi
  [[ -d "${SSHD_PRIVSEP_DIR:?}" ]] || { echo "Missing privilege separation directory: $SSHD_PRIVSEP_DIR" >&2; exit 255; }
  exit 0
fi
[[ -d "${SSHD_PRIVSEP_DIR:?}" ]] && : > "${SSHD_STARTED:?}"
exit 0
EOF2
chmod 755 "$TMP/bin/sshd-fake"
(
  # shellcheck source=../units/sshd-watchdog.sh
  source "$ROOT/units/sshd-watchdog.sh"
  LOG=$TMP/sshd-watchdog.log
  BIN=$TMP/bin/sshd-fake
  export BOX_ACCESS_SS_TEXT=' '
  sshd_listening() { return 0; }
  start_sshd 100.64.0.9 >/dev/null
  sleep 0.3
  [[ -d "$SSHD_PRIVSEP_DIR" ]] || fail "watchdog did not create the privsep dir"
  [[ -e "$SSHD_STARTED" ]] || fail "sshd started before the privsep dir existed"
  grep -q "created $SSHD_PRIVSEP_DIR" "$LOG" || fail "watchdog did not log the privsep dir: $(cat "$LOG")"
  grep -q 'sshd -t failed' "$LOG" && fail "sshd -t failed after the dir was created: $(cat "$LOG")"
  : > "$LOG"
  FAKE_SSHD_T_ERR='/etc/ssh/sshd_config line 3: Bad configuration option' start_sshd 100.64.0.9 >/dev/null
  grep -q 'sshd -t failed (/etc/ssh/sshd_config line 3: Bad configuration option)' "$LOG" \
    || fail "watchdog did not log the sshd -t reason: $(cat "$LOG")"
)
echo "ok the sshd watchdog creates /run/sshd first and logs the sshd -t reason"

s08=$ROOT/steps/08-sshd.sh
p_dir=$(grep -n 'ensure_sshd_privsep_dir' "$s08" | head -n1 | cut -d: -f1)
p_start=$(grep -n 'sudo setsid "\$SSHD"' "$s08" | head -n1 | cut -d: -f1)
[[ -n "$p_dir" && -n "$p_start" ]] && (( p_dir < p_start )) || fail "08-sshd.sh does not create /run/sshd before starting sshd"
echo "ok 08-sshd.sh creates /run/sshd before starting sshd"
