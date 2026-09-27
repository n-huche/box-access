# box-access

One entrypoint reaches this box over Tailscale SSH and keeps that path up.

`./up.sh` installs packages, recovers the Tailscale identity, reclaims MagicDNS, binds `sshd` to the Tailscale IPv4 on port **2222**, and starts keep-alive watchdogs. Other repos do not configure Tailscale or SSH login. `./bootstrap.sh` is a thin wrapper that execs `./up.sh` with the same arguments.

After a Grok Bot / Cursor **Update**, apt packages and `/var/lib/tailscale` are wiped. `/home/box` (secrets, `authorized_keys`) and `/workspace` (this repo) persist. Run `./up.sh` again. It reinstalls packages and re-authenticates. It does not invent a second identity when the state file is still there.

Identity stays: hostname **`cursor`**, SSH user **`box`**, port **2222**, listen address **the Tailscale IPv4 only** (never `0.0.0.0`).

Port **2222** is never bound to `0.0.0.0`, `*`, or `[::]`. The package `sshd` on port **22** may listen on `0.0.0.0` and is left alone on purpose. `up.sh` does not kill it.

## Layout

`up.sh` is only the orchestrator. It sources `lib/common.sh`, then each `steps/*.sh` in order. Steps share one shell, so `TS_HOSTNAME`, `TS_IP`, and the recovery reason carry forward. Each step is idempotent.

```text
up.sh                           # run the steps below; honors flags
bootstrap.sh                    # exec ./up.sh "$@"; same arguments
lib/common.sh                   # paths, logging, secrets (never prints values)
lib/listen.sh                   # SSH_PORT, tailscale_ip, valid_listen_ip
lib/purge-stale-hostname.sh     # API purge; skips the live node
lib/purge_select.py             # match stale devices by hostname, keep our IPv4
lib/magicdns-reclaim.sh         # bounce tmp → desired name when DNS is stuck
lib/magicdns.py
lib/apt-update.sh               # disable the hanging Chrome apt source
steps/01-packages.sh            # Tailscale apt, openssh, chrome apt workaround
steps/02-secrets.sh             # load secrets.env; default hostname cursor
steps/03-tailscaled.sh          # start tailscaled; reuse state if it exists
steps/04-purge.sh               # on recovery, delete other TS_HOSTNAME devices
steps/05-auth.sh                # authkey, or tailscale up when only down
steps/06-magicdns.sh            # tmp → hostname when DNS is stuck on -1
steps/07-ssh-keys.sh            # authorized_keys, fingerprints, ssh-keygen -R
steps/08-sshd.sh                # ListenAddress=$TS_IP:2222 only
steps/09-watchdogs.sh           # start units/tailscale-watchdog.sh and sshd
packages.txt                    # openssh-server, tailscale
units/tailscale-watchdog.sh     # restart tailscaled only when state already exists
units/sshd-watchdog.sh          # sshd on the current Tailscale IPv4:2222
```

Watchdogs run from this repo. `up.sh` does not call another clone.

## Use

```bash
cd /workspace/box-access
git pull
./up.sh
```

`./bootstrap.sh` does the same thing. Prefer `./up.sh`.

From another machine on the tailnet, after `up.sh` prints the address:

```bash
ssh -p 2222 box@cursor
ssh -p 2222 box@<tailscale-ipv4>
```

Packages, the Chrome apt workaround, and SSH host-key fingerprints only (no auth, no sshd, no watchdogs):

```bash
./up.sh --install-only
```

Full path without the keep-alive loops (`sshd` still listens on the Tailscale IPv4):

```bash
./up.sh --no-watchdogs
```

Flags can be combined. `./bootstrap.sh` forwards them unchanged.

Re-run `./up.sh` after reboot or Update. The watchdogs then keep `tailscaled` and `sshd` up if either process crashes. They are not systemd units. A reboot stops the loops until `up.sh` starts them again.

## What one run does

`--install-only` runs step 01 and stops. `--no-watchdogs` skips step 09. Otherwise:

1. **`01-packages.sh`** — Disable Google Chrome apt sources that hang `apt-get update` (see below). Add the official Tailscale apt repo for the current Debian/Ubuntu suite, then install `openssh-server` and `tailscale`. Install `curl` or `python3` only if they are missing. Ensure SSH host keys exist (`ssh-keygen -A`). `--install-only` prints fingerprints here and exits.
2. **`02-secrets.sh`** — Load `/home/box/.config/box-access/secrets.env` (`TS_API_KEY`, `TS_AUTHKEY`, `TS_HOSTNAME`, default hostname `cursor`). Does not prompt. If host keys were regenerated, print fingerprints and the client `ssh-keygen -R` lines before recovery.
3. **`03-tailscaled.sh`** — Start `tailscaled`. An existing `/var/lib/tailscale/tailscaled.state` is reused. A missing state file means recovery, not a silent new node.
4. **`04-purge.sh`** — Only on recovery: prompt for missing keys if there is a TTY, then **purge** devices whose hostname equals `TS_HOSTNAME`, except this machine's live node (matched by Tailscale IPv4). A logged-in session skips this step.
5. **`05-auth.sh`** — On recovery, `tailscale up --authkey --hostname`. If the auth key fails on a TTY, start interactive `tailscale up` and print the browser URL. A logged-in session that is only down (`Stopped`) is `tailscale up` without a new auth key.
6. **`06-magicdns.sh`** — Reclaim when the hostname is right but the DNS name is still `cursor-1` (see below).
7. **`07-ssh-keys.sh`** — Ensure `/home/box/.ssh/authorized_keys`. Print host-key fingerprints again (and `ssh-keygen -R` when keys changed this run).
8. **`08-sshd.sh`** — `sshd` listens only on `<tailscale-ipv4>:2222` (`ListenAddress=$TS_IP`). It waits about 2 minutes for that IPv4, the same budget as the sshd watchdog. If the address is still missing, it warns and continues so the watchdogs start; they keep waiting and bind sshd. A wildcard check applies to port 2222 only. Port 22 is left alone.
9. **`09-watchdogs.sh`** — Start the tailscaled and sshd watchdogs from `units/`. Skipped with `--no-watchdogs`.

## Debian apt: Tailscale is not in the distro

`tailscale` is not in Debian apt (including Debian 13 / trixie). `up.sh` adds the official stable repo for the current suite from `/etc/os-release` (`VERSION_CODENAME`, for example `trixie`). It does not hardcode a suite.

- Signed keyring: `/usr/share/keyrings/tailscale-archive-keyring.gpg`
- Source list: `/etc/apt/sources.list.d/tailscale.list` (`pkgs.tailscale.com` stable)
- Idempotent: skip if that repo and keyring are already present
- `openssh-server` still comes from Debian

## Chrome apt source hangs `apt-get update`

`/etc/apt/sources.list.d/google-chrome.sources` (and sometimes `google-chrome.list`) points at `https://dl.google.com/linux/chrome...`. When that host does not answer, apt prints `Ign:` and retries until the update never finishes.

On every run, before `apt-get update`, `steps/01-packages.sh` **renames** those files so apt ignores them:

```text
google-chrome.sources → google-chrome.sources.disabled-by-box-access
google-chrome.list    → google-chrome.list.disabled-by-box-access
```

Any other file under `sources.list.d` whose contents reference `dl.google.com/linux/chrome` is renamed the same way. The Chrome browser itself is left installed. Apt updates for Tailscale and OpenSSH proceed. `apt-get update` also uses a 20s HTTP(S) acquire timeout so a different dead repo cannot block forever.

The Chrome `.sources` file says it is not recreated if removed. To use the Chrome apt repo again after `dl.google.com` is reachable:

```bash
sudo mv /etc/apt/sources.list.d/google-chrome.sources.disabled-by-box-access \
        /etc/apt/sources.list.d/google-chrome.sources
```

## Secrets (not in git)

```text
/home/box/.config/box-access/secrets.env   # chmod 600
/home/box/.ssh/authorized_keys             # chmod 600
```

Optional gitignored override: `$REPO/.env` (loaded after `secrets.env`).

| Variable      | Required when                         | Purpose                                      |
|---------------|---------------------------------------|----------------------------------------------|
| `TS_API_KEY`  | Recovery and MagicDNS purge           | Bearer token for the Tailscale API           |
| `TS_AUTHKEY`  | Recovery (authenticate this node)     | Auth key for `tailscale up`                  |
| `TS_HOSTNAME` | Optional (default: `cursor`)          | Join as this name; purge matches it exactly  |

```bash
TS_API_KEY=tskey-api-...
TS_AUTHKEY=tskey-auth-...
# TS_HOSTNAME=cursor
```

If recovery runs and a required key is missing, `up.sh` prompts on the terminal (hidden input for the two Tailscale keys), creates `~/.config/box-access/` (0700), and writes `secrets.env` (0600). Empty `authorized_keys`: prompt for one public key (not hidden). Non-interactive runs (no TTY) fail with a clear error instead of hanging.

`up.sh` never prints secret values. Auth-key failures are redacted before they are shown.

Do not invent secrets. If `TS_AUTHKEY` is rejected, generate a new reusable auth key in the admin console, or complete the printed browser login URL. On a TTY, `up.sh` starts that interactive `tailscale up`.

## Purge does not delete the live node

Recovery and MagicDNS reclaim delete tailnet devices whose **hostname** equals `TS_HOSTNAME`, so an offline `cursor` cannot force this box onto `cursor-1`.

The live node is kept by **Tailscale IPv4**, not by comparing ids. The API device `id` is numeric. `tailscale status --json` `Self.ID` is often a different string, so an id comparison both misses this node and can delete it. `up.sh` reads `tailscale ip -4` (and `Self.TailscaleIPs`) and skips every API device whose addresses contain that IP.

- No local node (wiped state, logged out): every device named `TS_HOSTNAME` is stale and can be deleted, then this box joins as that name.
- Local node is up and its IPv4 is known: that device is skipped; other devices with the same hostname are deleted.
- Local node is present but its IPv4 is unknown: purge **refuses**. It will not guess with a mismatched id.
- HTTP 401/403: warn and continue. Auth can still proceed. Fix the API key and re-run if a stale name is still in the way.

## MagicDNS reclaim (`cursor-1`)

If an offline `cursor` still exists at join time, Tailscale gives this node MagicDNS `cursor-1.<tailnet>.ts.net` even when `HostName` is already `cursor`. Deleting the stale device does not always clear that label.

Example from production: `cursor-1.tailc4d0e9.ts.net` stuck, and the name to reclaim was `cursor.tailc4d0e9.ts.net`. The tailnet suffix is read from the current `DNSName`. It is not hardcoded.

When `HostName` is the desired name and the DNS label is `cursor-1` (or `cursor-2`, …), or this node itself is registered under that suffixed name, `up.sh`:

1. Purges other devices named `TS_HOSTNAME`, skipping this node's Tailscale IPv4.
2. Sets the hostname to **`tmp`**, waits until status shows that name.
3. Sets the hostname back to `TS_HOSTNAME` and waits until the DNS label is exactly that name.

Setting the desired hostname alone did not clear the sticky label. The `tmp` hop did. If reclaim does not finish, `up.sh` warns and still brings up SSH on the Tailscale IPv4.

## Keep-alive

| Unit | Behavior |
|---|---|
| `units/tailscale-watchdog.sh` | Loop. If `tailscaled` is down, start `/usr/sbin/tailscaled -state=/var/lib/tailscale/tailscaled.state -statedir=/var/lib/tailscale -socket=/run/tailscale/tailscaled.sock`. Requires the state file (does not create an identity). `flock` so only one loop runs. Exponential backoff (5s–60s) when the binary or the state file is missing. |
| `units/sshd-watchdog.sh` | Wait for a Tailscale IPv4, then `sshd -D -e -p 2222 -o ListenAddress=<that-ip>`. Restart if that process dies or the Tailscale IPv4 changes. Refuse `0.0.0.0` and any listener on port 2222 that is not the current Tailscale IPv4. The package sshd on port 22 is left alone. |

Logs and lock directories sit next to the unit scripts (`*.log`, `*.lock/`) and are gitignored. Cron and AOS are not started.

## SSH host keys and `known_hosts`

Reinstalling `openssh-server` after a wipe regenerates host keys. Clients then fail with `REMOTE HOST IDENTIFICATION HAS CHANGED` / `Host key verification failed`.

`up.sh` cannot edit the Mac's `~/.ssh/known_hosts`. When host keys are created or regenerated, it prints fingerprints (at least ED25519 SHA256) and the client commands before recovery, and `07-ssh-keys.sh` prints them again once the node is up. `--install-only` prints them from `01-packages.sh` and then exits.

On the client:

```bash
ssh-keygen -R '[cursor]:2222'
ssh-keygen -R '[<tailscale-ipv4>]:2222'
```

Use the printed hostname (default `cursor`) and the printed Tailscale IPv4. Then reconnect and accept the new fingerprint.

## What git does not store

- `/var/lib/tailscale/` (node identity)
- `~/.ssh/`
- `~/.config/gh/`
- `/home/box/.config/box-access/secrets.env`
- `.env` / `.env.*` (gitignored)
- Watchdog logs and lock directories

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`). Disabling the Chrome **apt source** is only so `apt-get update` can finish.
- Do not consume the worker pool.
- Do not clone or bootstrap other repos. Watchdogs in `units/` are the copies that run.
- Do not start cron or AOS.
- Never listen on `0.0.0.0` for port 2222. `ListenAddress` is the Tailscale IPv4 only. `0.0.0.0:22` from the openssh package is left alone.
- Never commit API keys, auth keys, or SSH private keys. Never print them.
