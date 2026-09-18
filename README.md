# box-access

Portão desta box: Tailscale + OpenSSH. Atemporal. Não sobe processos.

## O que é

- Pacotes `openssh-server` e `tailscale`
- Recusa criar identidade Tailscale nova (precisa de `/var/lib/tailscale/tailscaled.state`)
- Destino do SSH: IPv4 Tailscale, porta **2222** — nunca `0.0.0.0`

## Layout

```text
bootstrap.sh          # pacotes + verifica o state
packages.txt
```

## Uso

```bash
cd /workspace/box-access
git pull
./bootstrap.sh
```

## O que o git não guarda

- `/var/lib/tailscale/` (identidade do nó)
- `~/.ssh/`
- `~/.config/gh/`

Sem o state do Tailscale o bootstrap **para**. Não corre `tailscale up` sozinho.

## Regras

- Não toca na plataforma Grok Bot/Cursor (`sand-*`, `.cursor`, `chrome-profile`).
- Não consome pool de workers.
- Não arranca daemons.
- Não é inventário de serviços.
