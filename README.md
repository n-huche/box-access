# box-access

Gate for this box: Tailscale + OpenSSH. Timeless. Does not start processes.

This repo **owns Tailscale identity for reaching the VM**. Other repos (`box-upkeep`, `aos`) never configure Tailscale login or node recovery.

## What it is

- Packages `openssh-server` and `tailscale`
- Normal path: requires `/var/lib/tailscale/tailscaled.state` (existing identity)
- Recovery path: if state is missing, purge the stale Tailscale device for this hostname via API, then `tailscale up` once
- SSH target: Tailscale IPv4, port **2222** — never `0.0.0.0`

## Layout

```text
bootstrap.sh                    # packages + gate / recovery
lib/purge-stale-hostname.sh     # API helper: list + delete by hostname
packages.txt
```

## Use

```bash
cd /workspace/box-access
git pull
./bootstrap.sh
```

Packages only (skip gate / recovery) — used by `box-upkeep` when it only needs packages installed:

```bash
./bootstrap.sh --install-only
```

## Secrets (not in git)

```text
/home/box/.config/box-access/secrets.env   # chmod 600
```

Optional gitignored override: `$REPO/.env`.

| Variable      | Required when                | Purpose                                     |
|---------------|------------------------------|---------------------------------------------|
| `TS_API_KEY`  | Recovery (state missing)     | Bearer token for Tailscale API purge        |
| `TS_AUTHKEY`  | Recovery (state missing)     | Auth key for `tailscale up`                 |
| `TS_HOSTNAME` | Optional (default: `cursor`) | Stable hostname; purge matches this exactly |

```bash
TS_API_KEY=tskey-api-...
TS_AUTHKEY=tskey-auth-...
# TS_HOSTNAME=cursor
```

## Recovery flow (this repo only)

When `/var/lib/tailscale/tailscaled.state` is **missing**:

1. Load `secrets.env` (and optional `$REPO/.env`)
2. Require `TS_API_KEY` and `TS_AUTHKEY` — clear error if either is missing (never silently create a duplicate node)
3. `TS_HOSTNAME` defaults to `cursor`
4. List tailnet devices; **DELETE** each device whose hostname equals `TS_HOSTNAME` (case-sensitive; noop if none)
5. `sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"`

When the state file **exists**: print `gate-ok` and do not purge.

After a VM reset you clone and bootstrap **each** repo yourself; this one only restores Tailscale access.

## What git does not store

- `/var/lib/tailscale/` (node identity)
- `~/.ssh/`
- `~/.config/gh/`
- `/home/box/.config/box-access/secrets.env`
- `.env` / `.env.*` (gitignored)

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`).
- Do not consume the worker pool.
- Do not start daemons.
- Do not clone or bootstrap other repos.
- Not a service inventory.
- Never commit API keys or auth keys.
