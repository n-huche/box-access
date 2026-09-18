# box-infra

Acesso SSH à box via Tailscale, e o cold start dos processos que reboot ou Update da box não relançam.

Não é o AOS. AOS vive em `/workspace/aos`. Este repo só: **Tailscale**, **sshd :2222**, **`start.sh`**, **`status.sh`**.

## Layout

No git:

```text
bootstrap.sh          # pacotes + instala em /home/box + start
start.sh              # cold start (cópia em /home/box/start.sh)
status.sh             # a box está acessível? (cópia em /home/box/status.sh)
packages.txt          # openssh-server, tailscale, cron
sshd-watchdog.sh
tailscale-watchdog.sh
```

Na box, depois do bootstrap:

```text
/home/box/start.sh
/home/box/status.sh
/home/box/infra/          # watchdogs, logs, locks, host keys, sshd_config.runtime
```

`/home/box/start.sh` fica na raiz de propósito: é o que se corre à mão. Watchdogs instalam em `/home/box/infra/` (logs, locks e host keys junto).

## O que o git não guarda

- `/var/lib/tailscale/` (identidade do nó)
- `/home/box/infra/ssh_host_*` (fingerprint do sshd; copia a chave da distro na primeira vez)
- `~/.ssh/`
- `~/.config/gh/`
- logs e locks

Sem o state do Tailscale o bootstrap **para**. Não roda `tailscale up` sozinho.

## Recuperar

Há systemd nesta box: **não**. `@reboot` do cron: best-effort (muitas vezes não dispara). Alguém tem de correr o bootstrap/`start.sh`. O bootstrap grava a linha no crontab na mesma: se o cron sobreviver, a box volta sozinha.

### Update da box

Arquivos em `/workspace` tendem a ficar. Pacotes apt somem. Cron e spool podem sumir.

```bash
cd /workspace/box-infra
git pull
./bootstrap.sh
```

Isso reinstala `openssh-server`, `tailscale` e `cron` se faltarem, regrava `start.sh` + `status.sh` + watchdogs, persiste/reusa host keys em `/home/box/infra`, tenta o `@reboot`, para o sshd da distro, sobe os daemons se o state ainda estiver em disco.

Depois: `/home/box/status.sh` (ou `start.sh status`). `acesso: ok` quer dizer Tailscale + sshd só em `<ip>:2222` + watchdogs.

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

Host keys: se `/home/box/infra/ssh_host_ed25519_key` estiver no disco, o fingerprint SSH permanece. Se não, o bootstrap copia `/etc/ssh/ssh_host_ed25519_key` ou gera uma nova (TOFU no cliente).

### Só copiar arquivos, sem mexer em processos

```bash
./bootstrap.sh --install-only
```

Copia scripts, garante host keys e tenta gravar o crontab. Não para sshd, não sobe watchdogs.

## `start.sh`

1. Sobe `tailscale-watchdog` (adota `tailscaled` se já estiver no ar).
2. Sobe `sshd-watchdog` (sshd só no IPv4 Tailscale, porta **2222**; para o sshd da distro em `:22` / `0.0.0.0`).
3. Imprime `status.sh` (não falha o cold start se ainda estiver a subir).
4. Se existir `/workspace/aos/scripts/aos`, chama `aos up` — cold start do AOS, que é outro sistema.

`start.sh status` é o mesmo que `/home/box/status.sh`.

Da sua máquina (Tailscale no mesmo tailnet):

```text
ssh -p 2222 box@<tailscale-ipv4>
```

IP atual: `sudo tailscale ip -4` nesta box.

O primeiro bootstrap desta versão pode derrubar um sshd antigo na 2222 (cmdline sem a config do repo) e subir o nosso — uma reconexão.

## Regras

- Não toca na plataforma Grok Bot/Cursor (`sand-*`, `.cursor`, `chrome-profile`).
- Não consome pool de workers.
- Watchdog do Tailscale recusa subir sem `tailscaled.state`.
- sshd não escuta 0.0.0.0; só o IP Tailscale. O sshd empacotado da distro não fica de listener.
