# box-access

Gate for this box: Tailscale + OpenSSH. Timeless. Does not start processes.

## What it is

- Packages `openssh-server` and `tailscale`
- Refuses to create a new Tailscale identity (needs `/var/lib/tailscale/tailscaled.state`)
- SSH target: Tailscale IPv4, port **2222** — never `0.0.0.0`

## Layout

```text
bootstrap.sh          # packages + checks the state
packages.txt
```

## Use

```bash
cd /workspace/box-access
git pull
./bootstrap.sh
```

## What git does not store

- `/var/lib/tailscale/` (node identity)
- `~/.ssh/`
- `~/.config/gh/`

Without the Tailscale state, bootstrap **stops**. It does not run `tailscale up` on its own.

## Rules

- Do not touch the Grok Bot/Cursor platform (`sand-*`, `.cursor`, `chrome-profile`).
- Do not consume the worker pool.
- Do not start daemons.
- Not a service inventory.
