# Apt helpers for ./up.sh.
# Google Chrome's apt source (google-chrome.sources / google-chrome.list)
# can stall `apt-get update` forever on https://dl.google.com/ (apt prints
# "Ign:" and retries). Rename those files so apt ignores them.
# DNS SRV records for deb.debian.org (_http._tcp / _https._tcp) can resolve
# to 198.18.0.1 on the box egress proxy, returning HTTP 500 or TLS EOF while
# direct A/AAAA resolution works. Write Acquire::EnableSrvRecords "false"; to
# /etc/apt/apt.conf.d/99-no-srv-records so every apt-get update and install
# skips SRV lookups. Short acquire timeouts are a backstop if another repo hangs.

APT_CONF_D=${APT_CONF_D:-/etc/apt/apt.conf.d}

disable_hanging_chrome_apt_sources() {
  local dir=${1:-/etc/apt/sources.list.d}
  local glob_was=0
  local f base dest seen=" "

  [[ -d "$dir" ]] || return 0

  shopt -q nullglob && glob_was=1
  shopt -s nullglob
  for f in "$dir"/google-chrome.sources "$dir"/google-chrome.list "$dir"/*; do
    [[ -f "$f" ]] || continue
    case " $seen " in
      *" $f "*) continue ;;
    esac
    seen+=" $f "
    base=$(basename -- "$f")
    # Already ignored by apt: *.disabled, *.disabled-by-box-access, or a
    # collision suffix on that name. Do not append another .disabled-*.
    case "$base" in
      *.disabled|*.disabled-*) continue ;;
    esac
    case "$base" in
      google-chrome.sources|google-chrome.list) ;;
      *)
        if ! grep -I -q 'dl\.google\.com/linux/chrome' "$f" 2>/dev/null; then
          continue
        fi
        ;;
    esac
    dest="$dir/${base}.disabled-by-box-access"
    if [[ -e "$dest" ]]; then
      dest="$dir/${base}.disabled-by-box-access.$$"
    fi
    echo "apt: disabling $base (https://dl.google.com can stall apt-get update forever)"
    if [[ -w "$dir" ]]; then
      mv -- "$f" "$dest" || echo "WARN: could not disable $base" >&2
    else
      sudo mv -- "$f" "$dest" || echo "WARN: could not disable $base" >&2
    fi
  done
  if [[ "$glob_was" -eq 0 ]]; then
    shopt -u nullglob
  fi
}

disable_apt_srv_records() {
  local conf_dir=${1:-$APT_CONF_D}
  local conf_file="$conf_dir/99-no-srv-records"
  local line='Acquire::EnableSrvRecords "false";'

  if [[ -f "$conf_file" ]] && grep -Fqx -- "$line" "$conf_file" 2>/dev/null; then
    return 0
  fi

  if [[ ! -d "$conf_dir" ]]; then
    if [[ -w "$(dirname -- "$conf_dir")" ]]; then
      mkdir -p -- "$conf_dir" || { echo "WARN: could not create $conf_dir" >&2; return 0; }
    else
      sudo mkdir -p -- "$conf_dir" || { echo "WARN: could not create $conf_dir" >&2; return 0; }
    fi
  fi

  echo "apt: writing $conf_file (Acquire::EnableSrvRecords=false)"
  if [[ -w "$conf_dir" ]]; then
    printf '%s\n' "$line" > "$conf_file" || echo "WARN: could not write $conf_file" >&2
  else
    printf '%s\n' "$line" | sudo tee "$conf_file" >/dev/null || echo "WARN: could not write $conf_file" >&2
  fi
}

apt_get_update() {
  disable_hanging_chrome_apt_sources
  disable_apt_srv_records
  echo "apt: apt-get update (http/https timeout 20s)"
  sudo apt-get update -y \
    -o Acquire::EnableSrvRecords=false \
    -o Acquire::http::Timeout=20 \
    -o Acquire::https::Timeout=20 \
    -o Acquire::Retries=2
}
