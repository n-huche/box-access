# box-access

Everything required to **reach** this box over SSH: Tailscale identity, `authorized_keys`, and a one-shot start of `tailscaled` + `sshd` on the Tailscale IPv4 port **2222**. Other repos never configure Tailscale or SSH login.

Keeping those processes up after reboot is **not** this repo. That is host persistence.

## What it is

- Official Tailscale apt repo (Debian does not ship `tailscale`), then packages `openssh-server` and `tailscale`
- Recovery when state is missing **or** the session is dead (`NeedsLogin` / logged out / no Tailscale IPv4 with a dead session)
- SSH host key fingerprints after `openssh-server` work, plus the client `ssh-keygen -R` step when keys were created or regenerated
- SSH public key in `~/.ssh/authorized_keys` (prompt on a TTY if empty)
- One-shot: `sshd` listening on `<tailscale-ipv4>:2222` — never `0.0.0.0`

No watchdogs. No `/home/box/access/` install. No one-off paste helpers — `./bootstrap.sh` is the recovery path.

## Layout

```text
bootstrap.sh                    # packages + identity + one-shot sshd
lib/purge-stale-hostname.sh     # API helper: list + delete by hostname
packages.txt
```

## Use

```bash
cd /workspace/box-access
git pull
./bootstrap.sh
```

After this, `ssh -p 2222 box@cursor` works until the processes die. Persistence is a different repo.

Packages only (no identity, no sshd, no keys):

```bash
./bootstrap.sh --install-only
```

`--install-only` still adds the Tailscale apt repo if needed, installs packages, ensures SSH host keys exist, and prints fingerprints (plus the client `known_hosts` fix when keys changed).

## Debian apt: Tailscale is not in the distro

`tailscale` is **not** in Debian apt (including Debian 13 / trixie). Before `ensure_pkg tailscale`, bootstrap adds the official stable repo for the **current suite** from `/etc/os-release` (`VERSION_CODENAME`, e.g. `trixie` in production). It does **not** hardcode a suite.

- Signed keyring: `/usr/share/keyrings/tailscale-archive-keyring.gpg`
- Source list: `/etc/apt/sources.list.d/tailscale.list` (`pkgs.tailscale.com` stable)
- Idempotent: skip if that repo and keyring are already present, then `apt-get update` and install `packages.txt` as usual
- `openssh-server` still comes from Debian

## SSH host keys and `known_hosts`

Reinstalling `openssh-server` on a wipe can **regenerate host keys**. Clients (Mac `neo`, Cursor Remote-SSH host `box` → `[cursor]:2222`) then fail with `REMOTE HOST IDENTIFICATION HAS CHANGED` / `Host key verification failed`.

Bootstrap runs on the box and cannot edit the Mac's `~/.ssh/known_hosts`. When host keys are created or regenerated this run, it prints fingerprints (at least ED25519 SHA256) and the exact client commands. It **always** prints fingerprints at the end of a successful bootstrap so operators can verify Remote-SSH warnings.

On the client:

```bash
ssh-keygen -R '[cursor]:2222'
ssh-keygen -R '[<tailscale-ipv4>]:2222'
```

Use the printed `TS_HOSTNAME` (default `cursor`) and the printed Tailscale IPv4. Then reconnect and accept the new fingerprint.

## Secrets (not in git)

```text
/home/box/.config/box-access/secrets.env   # chmod 600
/home/box/.ssh/authorized_keys             # chmod 600
```

Optional gitignored override: `$REPO/.env`.

| Variable      | Required when                         | Purpose                                     |
|---------------|---------------------------------------|---------------------------------------------|
| `TS_API_KEY`  | Recovery (purge stale device)         | Bearer token for Tailscale API purge        |
| `TS_AUTHKEY`  | Recovery (authenticate this node)     | Auth key for `tailscale up`                 |
| `TS_HOSTNAME` | Optional (default: `cursor`)          | Join as this name; purge matches it exactly |

```bash
TS_API_KEY=tskey-api-...
TS_AUTHKEY=tskey-auth-...
# TS_HOSTNAME=cursor
```

If recovery runs and a required key is missing, `bootstrap.sh` **prompts on the terminal** (hidden input for the two Tailscale keys), creates `~/.config/box-access/` (0700), and writes `secrets.env` (0600). Empty `authorized_keys`: prompt for one public key (not hidden). Non-interactive runs (no TTY) fail with a clear error instead of hanging.

Do not invent secrets. If `TS_AUTHKEY` is rejected, generate a new reusable auth key in admin, or complete the printed browser login URL from `tailscale up` / `tailscale login` (bootstrap will start the interactive `up` on a TTY).

## Recovery flow

Recovery runs when **any** of these is true (not only a missing state file):

- `/var/lib/tailscale/tailscaled.state` is missing (wipe)
- `tailscale status` is `NeedsLogin` / logged out / not logged in (including after `tailscale logout`)
- There is no Tailscale IPv4 and the session is dead (not merely `tailscale down`)

Then:

1. Load `secrets.env` (and optional `$REPO/.env`)
2. If `TS_API_KEY` / `TS_AUTHKEY` are missing: prompt on a TTY, or exit clearly when not a TTY
3. `TS_HOSTNAME` defaults to `cursor` — join **as that name**. Do not join as `cursor-1` and rename later; MagicDNS stays sticky on the old name.
4. Start `tailscaled` if it is not running. Wait for the socket.
5. List tailnet devices; **DELETE** each device whose hostname equals `TS_HOSTNAME` (case-sensitive; noop if none). If the API key is invalid (HTTP 401), **warn and continue** — auth can still proceed. Delete a conflicting offline device of the same name in admin if MagicDNS is sticky (or re-run purge when the key works).
6. `sudo tailscale up --authkey="$TS_AUTHKEY" --hostname="$TS_HOSTNAME"`. If the auth key fails: clear next step (new reusable auth key, or interactive `tailscale up` / browser URL). On a TTY, bootstrap starts the interactive `up` so you can complete the URL. One-off scripts such as `paste-ts-auth.sh` are obsolete.

A logged-in session that is only down (`Stopped`, no IPv4) is **not** full recovery: bootstrap runs `tailscale up --hostname="$TS_HOSTNAME"` without re-auth.

Then, always (recovery or existing session):

7. Ensure `authorized_keys`
8. One-shot `tailscaled` (if down) and `sshd` on `<tailscale-ipv4>:2222`
9. Print SSH host key fingerprints (and the client `ssh-keygen -R` commands if keys changed this run)

When the session is already logged in and has an IPv4: skip 1–6 (`gate-ok`).

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
- Do not babysit processes. One-shot start only.
- Do not start cron or AOS.
- Never listen on `0.0.0.0`. `ListenAddress` is the Tailscale IPv4 only, port 2222.
- Never commit API keys, auth keys, or SSH private keys.
