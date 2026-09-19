# Purge Tailscale devices whose hostname matches TS_HOSTNAME.
# Expects: TS_API_KEY, TS_HOSTNAME (caller must set/export them).
# Uses curl + python3 (stdlib). Idempotent when no match.

purge_stale_hostname() {
  local api_key=${TS_API_KEY:?TS_API_KEY is required}
  local hostname=${TS_HOSTNAME:?TS_HOSTNAME is required}
  local list_url="https://api.tailscale.com/api/v2/tailnet/-/devices"
  local json ids id

  echo "purge: listing tailnet devices for hostname=$hostname"

  json=$(curl -fsS \
    -H "Authorization: Bearer ${api_key}" \
    "$list_url") || {
    echo "ERROR: failed to list Tailscale devices (check TS_API_KEY)." >&2
    return 1
  }

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
    curl -fsS -X DELETE \
      -H "Authorization: Bearer ${api_key}" \
      "https://api.tailscale.com/api/v2/device/${id}" \
      -o /dev/null || {
      echo "ERROR: failed to delete device id=$id" >&2
      return 1
    }
    echo "purge: deleted id=$id"
  done <<<"$ids"
}
