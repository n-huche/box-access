# box-access

Gate for this box: Tailscale + OpenSSH. Timeless. Does not start processes.

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

Packages only (skip gate / recovery):

```bash
./bootstrap.sh --install-only
```

## Secrets (not in git)

Store outside the repo:

```text
/home/box/.config/box-access/secrets.env   # chmod 600
```

Optional gitignored override: `$REPO/.env` (do not put real secrets into a tracked file).

| Variable      | Required when                         | Purpose                                      |
|---------------|----------------------------------------|----------------------------------------------|
| `TS_API_KEY`  | Recovery (state missing)               | Bearer token for Tailscale API purge         |
| `TS_AUTHKEY`  | Recovery (state missing)               | One-time auth key for `tailscale up`         |
| `TS_HOSTNAME` | Optional (default: `cursor`)           | Stable hostname; purge matches this exactly  |

Example `secrets.env` shape (values redacted):

```bash
TS_API_KEY=tskey-api-...
TS_AUTHKEY=tskey-auth-...
# TS_HOSTNAME=cursor
```

## Recovery flow

When `/var/lib/tailscale/tailscaled.state` is **missing**:

1. Load `secrets.env` (and optional `$REPO/.env`)
2. Require `TS_API_KEY` and `TS_AUTHKEY` — exit with a clear error if either is missing (never silently create a duplicate node)
3. `TS_HOSTNAME` defaults to `cursor`
4. List tailnet devices; **DELETE** each device whose hostname equals `TS_HOSTNAME` (case-sensitive; noop if none)
5. `sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"`

When the state file **exists**: print `gate-ok` and do not purge.

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
- Not a service inventory.
- Never commit API keys or auth keys.

## Recovery after VM reset

Goal: after a full VM wipe, get Tailscale (`hostname` **cursor**), SSH on port **2222**, upkeep watchdogs, and AOS back with one script.

1. Restore secrets (from your password manager), never from git:

```bash
mkdir -p ~/.config/box-access && chmod 700 ~/.config/box-access
cat > ~/.config/box-access/secrets.env <<'EOF'
TS_API_KEY=tskey-api-...
TS_AUTHKEY=tskey-auth-...
TS_HOSTNAME=cursor
EOF
chmod 600 ~/.config/box-access/secrets.env
```

2. Clone this repo (or any bootstrap path that lands `recover.sh`), then:

```bash
cd /workspace
git clone https://github.com/n-huche/box-access.git
./box-access/recover.sh
```

`recover.sh` will: clone/pull `box-access`, `box-upkeep`, `aos`, and `aos-user`; run `box-access/bootstrap.sh` (API purge of old `cursor` + `tailscale up` when state is missing); run `box-upkeep/bootstrap.sh` (daemons + `aos up`).

Private `aos-user` needs GitHub auth on the fresh box (`gh auth login` or HTTPS credentials).

