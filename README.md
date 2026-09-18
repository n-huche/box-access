# box-access

Portão desta box: Tailscale + OpenSSH. **Atemporal.** Não sobe processos e não conhece o AOS.

Quem mantém daemons no ar depois de reboot/Update é [box-keep](https://github.com/n-huche/box-keep).

## O que é

- Pacotes `openssh-server` e `tailscale`
- Recusa criar identidade Tailscale nova (precisa de `/var/lib/tailscale/tailscaled.state`)
- sshd, quando o keep o arrancar, escuta só no IPv4 Tailscale **:2222**

## Layout

```text
bootstrap.sh          # pacotes + verifica o state
packages.txt
```

Não instala `/home/box/start.sh`. Isso é o keep.

## Uso

```bash
cd /workspace/box-access
git pull
./bootstrap.sh --install-only
```

Depois, processos:

```bash
cd /workspace/box-keep
./bootstrap.sh
```

Sem `--install-only`, o `bootstrap.sh` deste repo faz o mesmo (portão só) e diz para correres o keep.

## O que o git não guarda

- `/var/lib/tailscale/` (identidade do nó)
- `~/.ssh/`
- `~/.config/gh/`

Sem o state do Tailscale o bootstrap **para**. Não corre `tailscale up` sozinho.

## Regras

- Não toca na plataforma Grok Bot/Cursor (`sand-*`, `.cursor`, `chrome-profile`).
- Não consome pool de workers.
- Não chama o AOS.
- Não é inventário de serviços — serviços novos vão para o keep.
