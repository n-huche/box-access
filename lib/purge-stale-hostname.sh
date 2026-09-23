# Purge Tailscale devices whose hostname matches TS_HOSTNAME.
# Expects: TS_API_KEY, TS_HOSTNAME (caller must set/export them).
# Uses curl + python3 (stdlib). Idempotent when no match.
# Returns 1 on API failure (including HTTP 401); caller may soft-fail.

purge_stale_hostname() {
  local api_key=${TS_API_KEY:?TS_API_KEY is required}
  local hostname=${TS_HOSTNAME:?TS_HOSTNAME is required}
  local list_url="https://api.tailscale.com/api/v2/tailnet/-/devices"
  local json ids id http_code tmp

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

  # Case-sensitive match on HostName or hostname field; emit device id strings.
  ids=$(HOSTNAME_MATCH="$hostname" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
want = os.environ["HOSTNAME_MATCH"]
devices = data.get("devices") or data.get("Devices") or []
for d in devices:
    name = d.get("hostname") or d.get("HostName") or ""
    if name == want:
        did = d.get("id") or d.get("ID") or ""
        if did:
            print(did)
' <<<"$json")

  if [[ -z "${ids}" ]]; then
    echo "purge: no device with hostname=$hostname (noop)"
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
