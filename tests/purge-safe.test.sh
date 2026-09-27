#!/usr/bin/env bash
# Shell purge refuses an unidentified live node and does not DELETE it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/purge-stale-hostname.sh
source "$ROOT/lib/purge-stale-hostname.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
export FAKE_CURL_LOG="$TMP/curl.log"
export FAKE_DEVICES_JSON="$TMP/devices.json"
cat > "$FAKE_DEVICES_JSON" <<'JSON'
{
  "devices": [
    {"id": "111", "hostname": "cursor", "addresses": ["100.64.0.1"]},
    {"id": "222", "hostname": "cursor", "addresses": ["100.64.0.2"]}
  ]
}
JSON

cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
url=""
method=GET
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out=$2
      shift 2
      ;;
    -X)
      method=$2
      shift 2
      ;;
    -w|-H)
      shift 2
      ;;
    -sS|-s|-S|-f|-fsSL)
      shift
      ;;
    http://*|https://*)
      url=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "${FAKE_CURL_LOG:?}"
if [[ "$method" == "GET" ]]; then
  cp "${FAKE_DEVICES_JSON:?}" "$out"
  printf '200'
elif [[ "$method" == "DELETE" ]]; then
  : > "$out"
  printf '200'
else
  printf '500'
fi
EOF
chmod 755 "$FAKE_BIN/curl"

PATH="$FAKE_BIN:$PATH"
export TS_API_KEY="tskey-api-test"
export TS_HOSTNAME=cursor

# Refuse before any HTTP call when a live node cannot be identified.
export TS_PURGE_REQUIRE_SELF=1
export TS_SELF_IPS=""
export TS_SELF_IDS=""
export TS_SELF_IPV4=""
: > "$FAKE_CURL_LOG"
if purge_stale_hostname; then
  echo "FAIL purge should refuse without a self IPv4"
  exit 1
fi
if [[ -s "$FAKE_CURL_LOG" ]]; then
  echo "FAIL curl was called during an unsafe purge"
  exit 1
fi
echo "ok refuse when live node has no ipv4"

# A missing API key must return, not exit the shell via ${var:?}.
saved_key=$TS_API_KEY
unset TS_API_KEY
: > "$FAKE_CURL_LOG"
set +e
purge_stale_hostname >/dev/null 2>"$TMP/nokey.err"
rc=$?
set -e
export TS_API_KEY=$saved_key
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL purge succeeded without an API key"
  exit 1
fi
if [[ -s "$FAKE_CURL_LOG" ]]; then
  echo "FAIL curl ran without an API key"
  exit 1
fi
if ! grep -q 'TS_API_KEY is unset' "$TMP/nokey.err"; then
  echo "FAIL missing-key error was not reported"
  exit 1
fi
echo "ok missing API key returns instead of exiting"

# IPv4 match: delete the stale device only.
export TS_PURGE_REQUIRE_SELF=1
export TS_SELF_IPS="100.64.0.1"
export TS_SELF_IDS="nodekey:different-from-111"
: > "$FAKE_CURL_LOG"
out="$TMP/out"
err="$TMP/err"
purge_stale_hostname >"$out" 2>"$err"
if ! grep -q 'DELETE https://api.tailscale.com/api/v2/device/222' "$FAKE_CURL_LOG"; then
  echo "FAIL stale device was not deleted"
  cat "$FAKE_CURL_LOG"
  exit 1
fi
if grep -q 'device/111' "$FAKE_CURL_LOG"; then
  echo "FAIL live device was deleted"
  cat "$FAKE_CURL_LOG"
  exit 1
fi
if grep -q 'tskey-' "$FAKE_CURL_LOG" "$out" "$err"; then
  echo "FAIL secret value was logged"
  exit 1
fi
if ! grep -q 'matched Tailscale IP' "$err"; then
  echo "FAIL skip was not recorded"
  cat "$err"
  exit 1
fi
echo "ok shell purge deletes stale id and keeps live ipv4"
