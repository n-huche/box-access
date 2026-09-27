#!/usr/bin/env python3
"""MagicDNS helpers for sticky cursor-1 names. No secrets."""

from __future__ import annotations

import json
import re
import sys


def dns_label(name: str) -> str:
    text = (name or "").strip().rstrip(".")
    if not text:
        return ""
    return text.split(".", 1)[0].lower()


def _suffix_re(want: str) -> re.Pattern[str]:
    return re.compile(re.escape(want) + r"-\d+\Z")


def is_stuck(host: str, dns: str, want: str) -> bool:
    """True when this node should bounce its hostname to reclaim MagicDNS.

    Production case: HostName is already the desired name (cursor) but
    DNSName is stuck on the conflict label (cursor-1.<tailnet>.ts.net).
    Also true when this node itself is registered under that suffixed name.
    """
    want_l = (want or "").strip().lower()
    if not want_l:
        return False
    host_l = (host or "").strip().lower()
    label = dns_label(dns)
    if label == want_l and host_l == want_l:
        return False
    suffix = _suffix_re(want_l)
    if host_l == want_l and suffix.fullmatch(label):
        return True
    if suffix.fullmatch(host_l):
        return True
    if suffix.fullmatch(label) and host_l == label:
        return True
    return False


def _one_line(value: object) -> str:
    return str(value or "").replace("\n", "").replace("\r", "").strip()


def status_fields(data: dict) -> None:
    self_node = data.get("Self") or {}
    if not isinstance(self_node, dict):
        self_node = {}
    has_self = 1 if self_node else 0
    ips: list[str] = []
    raw_ips = self_node.get("TailscaleIPs") or []
    if isinstance(raw_ips, list):
        for item in raw_ips:
            text = _one_line(item)
            if text:
                ips.append(text)
    ids: list[str] = []
    for key in ("ID", "Id", "StableID", "NodeID"):
        text = _one_line(self_node.get(key))
        if text:
            ids.append(text)
    public_key = _one_line(self_node.get("PublicKey"))
    if public_key:
        ids.append(public_key)
    print("HAS_SELF", has_self)
    print("HOST", _one_line(self_node.get("HostName")))
    print("DNS", _one_line(self_node.get("DNSName")))
    print("IPS", " ".join(ips))
    print("IDS", " ".join(ids))


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: magicdns.py stuck|label|status-fields ...", file=sys.stderr)
        return 2
    cmd = argv[1]
    if cmd == "label":
        if len(argv) != 3:
            print("usage: magicdns.py label DNSNAME", file=sys.stderr)
            return 2
        print(dns_label(argv[2]))
        return 0
    if cmd == "stuck":
        if len(argv) != 5:
            print("usage: magicdns.py stuck HOSTNAME DNSNAME WANT", file=sys.stderr)
            return 2
        return 0 if is_stuck(argv[2], argv[3], argv[4]) else 1
    if cmd == "status-fields":
        raw = sys.stdin.read()
        if not raw.strip():
            print("HAS_SELF 0")
            print("HOST")
            print("DNS")
            print("IPS")
            print("IDS")
            return 0
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            print("HAS_SELF 0")
            print("HOST")
            print("DNS")
            print("IPS")
            print("IDS")
            return 0
        if not isinstance(data, dict):
            print("HAS_SELF 0")
            return 0
        status_fields(data)
        return 0
    print(f"unknown command: {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
