# Apt helpers for ./up.sh.
# Google Chrome's apt source (google-chrome.sources / google-chrome.list)
# can stall `apt-get update` forever on https://dl.google.com/ (apt prints
# "Ign:" and retries). Rename those files so apt ignores them. Short acquire
# timeouts are a backstop if another repo hangs.

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

apt_get_update() {
  disable_hanging_chrome_apt_sources
  echo "apt: apt-get update (http/https timeout 20s)"
  sudo apt-get update -y \
    -o Acquire::http::Timeout=20 \
    -o Acquire::https::Timeout=20 \
    -o Acquire::Retries=2
}
