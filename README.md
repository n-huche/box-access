# box-access

Everything required to reach this box over SSH: Tailscale identity, `sshd` on the Tailscale IPv4 port **2222**, and `authorized_keys`. Other repos never configure Tailscale or SSH.

This host has no systemd. Bootstrap starts `tailscaled` and `sshd` and leaves watchdogs that keep them up.

## What it is

- Packages `openssh-server` and `tailscale`
- Recovery: if `/var/lib/tailscale/tailscaled.state` is missing, start `tailscaled`, purge the stale device for this hostname via API, then `tailscale up` once
- If state exists: `gate-ok` (no purge)
- SSH public key in `~/.ssh/authorized_keys` (prompt on a TTY if empty)
- Watchdogs: `tailscaled` with the existing state; `sshd` listening on `<tailscale-ipv4>:2222` — never `0.0.0.0`

## Layout

```text
bootstrap.sh                    # packages + identity + sshd + watchdogs
start.sh                        # start watchdogs (copied to /home/box/access/)
lib/purge-stale-hostname.sh     # API helper: list + delete by hostname
units/tailscale-watchdog.sh
units/sshd-watchdog.sh
packages.txt
```

## Use

```bash
cd /workspace/box-access
git pull
./bootstrap.sh
```

Packages only (no identity, no sshd, no keys):

```bash
./bootstrap.sh --install-only
```

## Secrets (not in git)

```text
/home/box/.config/box-access/secrets.env   # chmod 600
/home/box/.ssh/authorized_keys             # chmod 600
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

If recovery runs and a required key is missing, `bootstrap.sh` **prompts on the terminal** (hidden input for the two Tailscale keys), creates `~/.config/box-access/` (0700), and writes `secrets.env` (0600). Empty `authorized_keys`: prompt for one public key (not hidden). Non-interactive runs (no TTY) fail with a clear error instead of hanging.

## Recovery flow

When `/var/lib/tailscale/tailscaled.state` is **missing**:

1. Load `secrets.env` (and optional `$REPO/.env`)
2. If `TS_API_KEY` / `TS_AUTHKEY` are missing: prompt on a TTY, or exit clearly when not a TTY
3. `TS_HOSTNAME` defaults to `cursor`
4. Start `tailscaled` if it is not running. Wait for the socket.
5. List tailnet devices; **DELETE** each device whose hostname equals `TS_HOSTNAME` (case-sensitive; noop if none)
6. `sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"`

Then, always (missing or existing state):

7. Ensure `authorized_keys`
8. Install watchdogs to `/home/box/access/` and start them

When the state file **exists**: skip 1–6 (`gate-ok`).

After a VM reset, clone this repo (or let the host bootstrap clone it) and run `./bootstrap.sh`. That is enough for `ssh -p 2222 box@cursor`.

## What git does not store

- `/var/lib/tailscale/` (node identity)
- `~/.ssh/`
- `~/.config/gh/`
- `/home/box/.config/box-access/secrets.env`
- `.env` / `.env.*` (gitignored)

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`).
- Do not consume the worker pool.
- Do not clone or bootstrap other repos.
- Do not start cron or AOS.
- Never commit API keys, auth keys, or SSH private keys.
