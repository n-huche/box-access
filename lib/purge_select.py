#!/usr/bin/env python3
"""Choose Tailscale API device ids to delete for a hostname purge.

stdin: JSON from GET /api/v2/tailnet/-/devices
env:
  HOSTNAME_MATCH   hostname that must match exactly (after strip)
  SELF_IPS         space-separated Tailscale IPs of the live node
  SELF_IDS         space-separated local ids (optional extra skip only)

The API device id is numeric. Local `tailscale status` Self.ID is often a
different string, so the live node is identified by Tailscale IPv4 (and any
other TailscaleIPs) first. A local id match is only an extra reason to skip.

stdout: API device ids to DELETE, one per line
stderr: skip decisions (ids and addresses only; never secrets)
"""

from __future__ import annotations

import json
import os
import sys


def norm_ip(value: object) -> str:
    if value is None:
        return ""
    text = str(value).strip()
    if not text:
        return ""
    text = text.split("/", 1)[0].split("%", 1)[0].strip()
    if ":" in text:
        return text.lower()
    return text


def token_set(raw: str) -> set[str]:
    return {part for part in raw.split() if part}


def device_addresses(device: dict) -> list[str]:
    raw = device.get("addresses") or device.get("Addresses") or []
    if isinstance(raw, str):
        raw = [raw]
    found: list[str] = []
    if not isinstance(raw, list):
        return found
    for item in raw:
        if isinstance(item, dict):
            item = item.get("ip") or item.get("address") or ""
        ip = norm_ip(item)
        if ip:
            found.append(ip)
    return found


def device_identity_tokens(device: dict) -> set[str]:
    tokens: set[str] = set()
    for key in ("id", "ID", "nodeId", "nodeID", "NodeID", "nodeKey", "nodekey"):
        value = device.get(key)
        if isinstance(value, (str, int)) and str(value).strip():
            tokens.add(str(value).strip())
    return tokens


def api_device_id(device: dict) -> str:
    value = device.get("id")
    if value is None:
        value = device.get("ID")
    if value is None:
        return ""
    return str(value).strip()


def select_ids(data: dict, hostname: str, self_ips: set[str], self_ids: set[str]) -> list[str]:
    devices = data.get("devices") or data.get("Devices") or []
    if not isinstance(devices, list):
        return []
    chosen: list[str] = []
    for device in devices:
        if not isinstance(device, dict):
            continue
        name = str(device.get("hostname") or device.get("HostName") or "").strip()
        if name != hostname:
            continue
        did = api_device_id(device)
        if not did:
            print(f"purge: skip hostname={hostname} (device has no API id)", file=sys.stderr)
            continue
        addrs = device_addresses(device)
        ident = device_identity_tokens(device)
        if self_ips and any(addr in self_ips for addr in addrs):
            print(
                f"purge: skip live device id={did} hostname={hostname} (matched Tailscale IP)",
                file=sys.stderr,
            )
            continue
        if self_ids and ident & self_ids:
            print(
                f"purge: skip live device id={did} hostname={hostname} (matched local node id)",
                file=sys.stderr,
            )
            continue
        # Cannot prove an address-less record is not this node.
        if self_ips and not addrs:
            print(
                f"purge: skip device id={did} hostname={hostname} (no addresses; not deleting the live node)",
                file=sys.stderr,
            )
            continue
        chosen.append(did)
    return chosen


def main() -> int:
    hostname = os.environ.get("HOSTNAME_MATCH", "")
    if not hostname:
        print("ERROR: HOSTNAME_MATCH is required", file=sys.stderr)
        return 1
    self_ips = {norm_ip(part) for part in token_set(os.environ.get("SELF_IPS", ""))}
    self_ips.discard("")
    self_ids = token_set(os.environ.get("SELF_IDS", ""))
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"ERROR: device list is not JSON ({exc})", file=sys.stderr)
        return 1
    if not isinstance(data, dict):
        print("ERROR: device list JSON must be an object", file=sys.stderr)
        return 1
    for did in select_ids(data, hostname, self_ips, self_ids):
        print(did)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
