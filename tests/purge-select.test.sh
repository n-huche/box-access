#!/usr/bin/env bash
# Live-node safety for the Tailscale hostname purge. No network.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PY="$ROOT/lib/purge_select.py"
fail=0

assert_ids() {
  local name=$1
  local want=$2
  local got=$3
  if [[ "$got" != "$want" ]]; then
    echo "FAIL $name"
    echo "  want: $(printf %q "$want")"
    echo "  got:  $(printf %q "$got")"
    fail=1
  else
    echo "ok $name"
  fi
}

run_select() {
  local ips=$1
  local ids=$2
  HOSTNAME_MATCH=cursor SELF_IPS="$ips" SELF_IDS="$ids" python3 "$PY"
}

FIXTURE='{
  "devices": [
    {
      "id": "111",
      "nodeId": "nLIVE",
      "hostname": "cursor",
      "addresses": ["100.64.0.1", "fd7a:115c:a1e0::1"]
    },
    {
      "id": "222",
      "nodeId": "nSTALE",
      "hostname": "cursor",
      "addresses": ["100.64.0.2/32"]
    },
    {
      "id": "333",
      "hostname": "other",
      "addresses": ["100.64.0.3"]
    },
    {
      "id": "444",
      "nodeId": "nodekey:abc",
      "hostname": "cursor",
      "addresses": ["100.99.0.4"]
    },
    {
      "id": 555,
      "hostname": "cursor",
      "addresses": []
    },
    {
      "id": "666",
      "hostname": "Cursor",
      "addresses": ["100.64.0.6"]
    }
  ]
}'

# API id is numeric; local Self.ID is a different string. IPv4 still keeps 111.
got=$(printf '%s' "$FIXTURE" | run_select "100.64.0.1" "nodekey:not-the-api-id")
assert_ids "ipv4 keeps live node despite mismatched ids" $'222\n444' "$got"

got=$(printf '%s' "$FIXTURE" | run_select "100.64.0.1" "nodekey:abc")
assert_ids "ipv4 and local id both skip" $'222' "$got"

got=$(printf '%s' "$FIXTURE" | run_select "" "")
assert_ids "no live markers deletes every exact hostname" $'111\n222\n444\n555' "$got"

got=$(printf '%s' "$FIXTURE" | run_select "100.64.0.1/32" "")
assert_ids "cidr self ip matches bare device address" $'222\n444' "$got"

# Address-less record is not deleted once we know our own IP.
got=$(printf '%s' "$FIXTURE" | run_select "100.64.0.1" "")
if printf '%s\n' "$got" | grep -qx '555'; then
  echo "FAIL address-less device was selected"
  fail=1
else
  echo "ok address-less device kept when self ip is known"
fi
if printf '%s\n' "$got" | grep -qx '111'; then
  echo "FAIL live ipv4 device was selected"
  fail=1
else
  echo "ok live ipv4 absent from delete list"
fi
if printf '%s\n' "$got" | grep -qx '666'; then
  echo "FAIL hostname match was case-insensitive"
  fail=1
else
  echo "ok hostname match is case-sensitive"
fi

stderr=$(printf '%s' "$FIXTURE" | HOSTNAME_MATCH=cursor SELF_IPS="100.64.0.1" SELF_IDS="" python3 "$PY" 2>&1 >/dev/null)
if ! grep -q 'matched Tailscale IP' <<<"$stderr"; then
  echo "FAIL skip reason missing"
  fail=1
else
  echo "ok skip reason names Tailscale IP"
fi
if grep -q 'tskey-' <<<"$stderr"; then
  echo "FAIL stderr contained a secret-like token"
  fail=1
fi

exit "$fail"
