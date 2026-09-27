# Purge Tailscale devices whose hostname matches TS_HOSTNAME.
# Expects: TS_API_KEY, TS_HOSTNAME (caller must set/export them).
# Optional:
#   TS_SELF_IPS / TS_SELF_IPV4   live node addresses; those devices are kept
#   TS_SELF_IDS                  extra skip tokens (local Self.ID / node key)
#   TS_PURGE_REQUIRE_SELF=1      refuse to delete anything if the live node
#                                cannot be identified (no IP and no id)
# Uses curl + python3 (stdlib). Idempotent when no match.
# Returns 1 on API failure (including HTTP 401) or an unsafe purge.
# Never prints secret values.

purge_stale_hostname() {
  # ${var:?} would exit the whole shell. Return instead so a missing key
  # cannot abort sshd startup; the caller warns and continues.
  local api_key=${TS_API_KEY:-}
  local hostname=${TS_HOSTNAME:-}
  if [[ -z "$api_key" ]]; then
    echo "ERROR: TS_API_KEY is unset; refusing to purge." >&2
    return 1
  fi
  if [[ -z "$hostname" ]]; then
    echo "ERROR: TS_HOSTNAME is unset; refusing to purge." >&2
    return 1
  fi
  local self_ips=${TS_SELF_IPS:-}
  local self_ids=${TS_SELF_IDS:-}
  local require_self=${TS_PURGE_REQUIRE_SELF:-0}
  local list_url="https://api.tailscale.com/api/v2/tailnet/-/devices"
  local json ids id http_code tmp
  local lib_dir

  if [[ -z "$self_ips" && -n "${TS_SELF_IPV4:-}" ]]; then
    self_ips=$TS_SELF_IPV4
  fi

  # A logged-in node with no Tailscale IPv4 must not be deleted. Local
  # Self.ID often does not equal the numeric API device id, so an id-only
  # comparison is not enough to tell "us" from "the other cursor".
  if [[ "$require_self" == "1" && -z "$self_ips" && -z "$self_ids" ]]; then
    echo "ERROR: refusing to purge hostname=$hostname; a live node is present but its Tailscale IPv4 is unknown." >&2
    return 1
  fi

  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  echo "purge: listing tailnet devices for hostname=$hostname"

  tmp=$(mktemp)
  http_code=$(curl -sS -o "$tmp" -w '%{http_code}' \
    -H "Authorization: Bearer ${api_key}" \
    "$list_url" || true)

  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    echo "ERROR: Tailscale API HTTP $http_code listing devices (TS_API_KEY invalid or expired)." >&2
    rm -f "$tmp"
    return 1
  fi
  if [[ "$http_code" != "200" ]]; then
    echo "ERROR: failed to list Tailscale devices (HTTP ${http_code:-000})." >&2
    rm -f "$tmp"
    return 1
  fi

  json=$(cat "$tmp")
  rm -f "$tmp"

  if ! ids=$(HOSTNAME_MATCH="$hostname" SELF_IPS="$self_ips" SELF_IDS="$self_ids" \
    python3 "$lib_dir/purge_select.py" <<<"$json"); then
    echo "ERROR: failed to select devices to purge." >&2
    return 1
  fi

  if [[ -z "${ids}" ]]; then
    echo "purge: no stale device with hostname=$hostname (noop)"
    return 0
  fi

  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    echo "purge: deleting device id=$id hostname=$hostname"
    tmp=$(mktemp)
    http_code=$(curl -sS -o "$tmp" -w '%{http_code}' -X DELETE \
      -H "Authorization: Bearer ${api_key}" \
      "https://api.tailscale.com/api/v2/device/${id}" || true)
    rm -f "$tmp"
    if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
      echo "ERROR: Tailscale API HTTP $http_code deleting device id=$id (TS_API_KEY invalid or expired)." >&2
      return 1
    fi
    if [[ "$http_code" != "200" && "$http_code" != "204" ]]; then
      echo "ERROR: failed to delete device id=$id (HTTP ${http_code:-000})" >&2
      return 1
    fi
    echo "purge: deleted id=$id"
  done <<<"$ids"
}
