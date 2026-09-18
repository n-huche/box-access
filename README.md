# box-infra

Acesso SSH à box via Tailscale, e o cold start dos processos que reboot ou Update da box não relançam.

Não é o AOS. AOS vive em `/workspace/aos`. Este repo: **Tailscale**, **sshd :2222**, **`start.sh`**.

## Reset completo (o caminho normal)

Disco vazio. Dois clones e um script:

```bash
cd /workspace
git clone https://github.com/n-huche/box-infra.git
git clone <url-do-aos> aos
./box-infra/bootstrap.sh
```

Isto cria o user `box`, instala pacotes, junta o Tailscale como hostname `box`, sobe sshd só em `<ip>:2222`, e se o AOS estiver em `/workspace/aos` corre `aos up`.

```text
ssh -p 2222 box@<tailscale-ipv4>
```

IP: `sudo tailscale ip -4` nesta box. No cliente Tailscale o nome é `box`.

### Uma vez (obrigatório, senão o clone não chega)

O git não inventa identidade Tailscale nem a chave da tua máquina.

1. `authorized_keys` — as tuas pubkeys. Commit normal.
2. `secrets/ts-authkey` — auth key **reutilizável** (não efémera). O ficheiro está no gitignore:

```bash
cp secrets/ts-authkey.example secrets/ts-authkey
# cola a key
chmod 600 secrets/ts-authkey
git add -f secrets/ts-authkey authorized_keys
git commit && git push
```

Host key ed25519 já vai no repo (`secrets/ssh_host_ed25519_key`): o fingerprint SSH não muda a cada reset.

Sem a auth key no clone, o bootstrap **para**. Não faz `tailscale up` às cegas.

## Layout

No git:

```text
bootstrap.sh
start.sh
status.sh
authorized_keys
packages.txt
sshd_config
sshd-watchdog.sh
tailscale-watchdog.sh
secrets/ssh_host_ed25519_key
secrets/ts-authkey          # tracked à mão (git add -f)
```

Na box, depois do bootstrap:

```text
/home/box/start.sh
/home/box/status.sh
/home/box/.ssh/authorized_keys
/home/box/infra/
```

## Update (ficheiros ainda no disco)

```bash
cd /workspace/box-infra
git pull
./bootstrap.sh
```

`--install-only` copia arquivos e não sobe processos.

Há systemd nesta box: **não**. Alguém (tu, ou o agent) corre o bootstrap depois do clone. `@reboot` não é a história.

## `start.sh`

1. `tailscale-watchdog` (adota `tailscaled` se já estiver no ar).
2. `sshd-watchdog` (sshd no IPv4 Tailscale :2222; para `:22` da distro no start).
3. Se existir `/workspace/aos/scripts/aos`, `aos up`.

## Regras

- Não toca na plataforma Grok Bot/Cursor (`sand-*`, `.cursor`, `chrome-profile`).
- Não consome pool de workers.
- Watchdog do Tailscale não cria nó novo. Quem junta na primeira vez é o bootstrap, e só com auth key.
- sshd não escuta 0.0.0.0; só o IP Tailscale.
