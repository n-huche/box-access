#!/usr/bin/env bash
# Sticky MagicDNS detection and the tmp → desired hostname bounce.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PY="$ROOT/lib/magicdns.py"

expect_stuck() {
  local host=$1 dns=$2 want=$3 expect=$4 name=$5
  set +e
  python3 "$PY" stuck "$host" "$dns" "$want" >/dev/null
  local rc=$?
  set -e
  if [[ "$rc" -ne "$expect" ]]; then
    echo "FAIL $name (rc=$rc want=$expect)"
    exit 1
  fi
  echo "ok $name"
}

expect_stuck cursor "cursor-1.tailc4d0e9.ts.net." cursor 0 "hostname correct, dns cursor-1"
expect_stuck cursor "cursor-1.tailc4d0e9.ts.net" cursor 0 "dns without trailing dot"
expect_stuck cursor "cursor-2.tailc4d0e9.ts.net." cursor 0 "dns cursor-2"
expect_stuck cursor "cursor.tailc4d0e9.ts.net." cursor 1 "dns already reclaimed"
expect_stuck cursor-1 "cursor-1.tailc4d0e9.ts.net." cursor 0 "node joined as cursor-1"
expect_stuck other "cursor-1.tailc4d0e9.ts.net." cursor 1 "unrelated hostname is not bounced"
expect_stuck cursor "" cursor 1 "empty dns is not stuck"
label=$(python3 "$PY" label "cursor-1.tailc4d0e9.ts.net.")
[[ "$label" == "cursor-1" ]]
echo "ok dns label"

# Bounce uses a fake tailscale: setting the desired name alone stays sticky
# until the hostname has been tmp.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export FAKE_TS_STATE="$TMP/state"
export FAKE_TS_LOG="$TMP/tailscale.log"
cat > "$FAKE_TS_STATE" <<'EOF'
host=cursor
dns=cursor-1.tailc4d0e9.ts.net.
ip=100.64.0.5
id=nodekey:live
EOF
: > "$FAKE_TS_LOG"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd=${1:-}
shift || true
printf '%s %s\n' "$cmd" "$*" >> "${FAKE_TS_LOG:?}"
state=${FAKE_TS_STATE:?}
read_field() {
  local key=$1
  sed -n "s/^${key}=//p" "$state" | head -n1
}
case "$cmd" in
  status)
    HOST=$(read_field host)
    DNS=$(read_field dns)
    IP=$(read_field ip)
    ID=$(read_field id)
    HOST=$HOST DNS=$DNS IP=$IP ID=$ID python3 -c '
import json, os
print(json.dumps({
  "BackendState": "Running",
  "MagicDNSSuffix": "tailc4d0e9.ts.net",
  "Self": {
    "ID": os.environ["ID"],
    "HostName": os.environ["HOST"],
    "DNSName": os.environ["DNS"],
    "TailscaleIPs": [os.environ["IP"]],
    "Online": True,
  },
}))
'
    ;;
  set)
    name=""
    for arg in "$@"; do
      case "$arg" in
        --hostname=*) name=${arg#--hostname=} ;;
      esac
    done
    [[ -n "$name" ]]
    prev_host=$(read_field host)
    prev_dns=$(read_field dns)
    ip=$(read_field ip)
    id=$(read_field id)
    suffix=tailc4d0e9.ts.net
    if [[ "$name" == "tmp" ]]; then
      new_dns="tmp.${suffix}."
    elif [[ "$prev_host" == "tmp" ]]; then
      new_dns="${name}.${suffix}."
    else
      new_dns=$prev_dns
    fi
    cat > "$state" <<STATE
host=$name
dns=$new_dns
ip=$ip
id=$id
STATE
    ;;
  *)
    echo "unexpected tailscale command: $cmd" >&2
    exit 1
    ;;
esac
EOF
chmod 755 "$TMP/bin/tailscale"

export PATH="$TMP/bin:$PATH"
export BOX_ACCESS_NOSUDO=1
export REPO="$ROOT"
export TS_HOSTNAME=cursor
PURGE_LOG="$TMP/purge.log"
: > "$PURGE_LOG"
try_purge_stale_hostname() {
  echo called >> "$PURGE_LOG"
}
tailscale_ip() {
  printf '%s\n' "100.64.0.5"
}
# shellcheck source=../lib/magicdns-reclaim.sh
source "$ROOT/lib/magicdns-reclaim.sh"

reclaim_magicdns_if_needed
if ! grep -q '^called$' "$PURGE_LOG"; then
  echo "FAIL stuck name did not purge"
  exit 1
fi
if ! grep -q 'set --hostname=tmp' "$FAKE_TS_LOG"; then
  echo "FAIL bounce did not set tmp"
  cat "$FAKE_TS_LOG"
  exit 1
fi
if ! grep -q 'set --hostname=cursor' "$FAKE_TS_LOG"; then
  echo "FAIL bounce did not restore cursor"
  cat "$FAKE_TS_LOG"
  exit 1
fi
# tmp must happen before the desired name.
tmp_line=$(grep -n 'set --hostname=tmp' "$FAKE_TS_LOG" | head -n1 | cut -d: -f1)
want_line=$(grep -n 'set --hostname=cursor' "$FAKE_TS_LOG" | head -n1 | cut -d: -f1)
if (( tmp_line >= want_line )); then
  echo "FAIL hostname was not bounced via tmp first"
  exit 1
fi
dns=$(sed -n 's/^dns=//p' "$FAKE_TS_STATE")
if [[ "$dns" != "cursor.tailc4d0e9.ts.net." ]]; then
  echo "FAIL dns was not reclaimed ($dns)"
  exit 1
fi
echo "ok bounce tmp then cursor reclaims magicdns"

# Already-correct DNS does not purge or rename.
cat > "$FAKE_TS_STATE" <<'EOF'
host=cursor
dns=cursor.tailc4d0e9.ts.net.
ip=100.64.0.5
id=nodekey:live
EOF
: > "$FAKE_TS_LOG"
: > "$PURGE_LOG"
reclaim_magicdns_if_needed
if [[ -s "$PURGE_LOG" ]]; then
  echo "FAIL purge ran when dns was already correct"
  exit 1
fi
if grep -q 'set --hostname=' "$FAKE_TS_LOG"; then
  echo "FAIL hostname changed when dns was already correct"
  exit 1
fi
echo "ok already-correct dns is left alone"
