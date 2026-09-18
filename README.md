# box-infra

Acesso SSH à box via Tailscale, e o cold start dos processos que reboot ou Update da box não relançam.

Não é o AOS. AOS vive em `/workspace/aos`. Este repo só: **Tailscale**, **sshd :2222**, **`start.sh`**.

## Layout

No git:

```text
bootstrap.sh          # pacotes + instala em /home/box + start
start.sh              # cold start (cópia em /home/box/start.sh)
status.sh             # a box está acessível?
packages.txt          # openssh-server, tailscale
sshd_config           # Port 2222; sem /etc/ssh/sshd_config
sshd-watchdog.sh
tailscale-watchdog.sh
```

Na box, depois do bootstrap:

```text
/home/box/start.sh
/home/box/status.sh
/home/box/infra/          # watchdogs, sshd_config, logs, locks, backup das host keys
```

`/home/box/start.sh` fica na raiz de propósito: é o que se corre à mão. Watchdogs instalam em `/home/box/infra/` (logs e locks junto).

## O que o git não guarda

- `/var/lib/tailscale/` (identidade do nó)
- `/home/box/infra/ssh_host_*` (backup das host keys; o sshd lê `/etc/ssh/`)
- `~/.ssh/`
- `~/.config/gh/`
- logs e locks

Sem o state do Tailscale o bootstrap **para**. Não roda `tailscale up` sozinho.

## Recuperar

Há systemd nesta box: **não**. `@reboot` do cron: best-effort (muitas vezes não dispara). Alguém tem de correr o bootstrap/`start.sh`.

### Update da box

Arquivos em `/workspace` tendem a ficar. Pacotes apt somem. Cron e spool podem sumir.

```bash
cd /workspace/box-infra
git pull
./bootstrap.sh
```

Isso reinstala `openssh-server` e `tailscale` se faltarem, regrava `start.sh` + watchdogs + `sshd_config`, restaura host keys para `/etc/ssh` se o backup existir, para o sshd da distro em `:22`, sobe os daemons se o state ainda estiver em disco.

`/home/box/status.sh` — `acesso: ok` quer dizer Tailscale + sshd em `<ip>:2222`.

Se `/workspace/box-infra` tiver sumido:

```bash
cd /workspace
git clone https://github.com/n-huche/box-infra.git
cd box-infra
./bootstrap.sh
```

### Reset (snapshot)

Pode voltar um disco velho ou perder trabalho não sincronizado. Se o clone não estiver no snapshot:

1. Clonar o repo (acima).
2. Confirmar `sudo test -f /var/lib/tailscale/tailscaled.state`.
3. `./bootstrap.sh`.

State ausente: autenticar o Tailscale **na mão** neste nó (não deixar o script criar identidade). Só então bootstrap de novo.

### Só copiar arquivos, sem mexer em processos

```bash
./bootstrap.sh --install-only
```

## `start.sh`

1. Sobe `tailscale-watchdog` (adota `tailscaled` se já estiver no ar).
2. Sobe `sshd-watchdog` (sshd só no IPv4 Tailscale, porta **2222**; para `:22` da distro no start).
3. Se existir `/workspace/aos/scripts/aos`, chama `aos up` — cold start do AOS, que é outro sistema.

Da sua máquina (Tailscale no mesmo tailnet):

```text
ssh -p 2222 box@<tailscale-ipv4>
```

IP atual: `sudo tailscale ip -4` nesta box.

## Regras

- Não toca na plataforma Grok Bot/Cursor (`sand-*`, `.cursor`, `chrome-profile`).
- Não consome pool de workers.
- Watchdog do Tailscale recusa subir sem `tailscaled.state`.
- sshd não escuta 0.0.0.0; só o IP Tailscale.
