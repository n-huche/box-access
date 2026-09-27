#!/usr/bin/env bash
# Chrome apt sources are renamed so apt-get update cannot hang on dl.google.com.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/apt-update.sh
source "$ROOT/lib/apt-update.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
DIR="$TMP/sources.list.d"
mkdir -p "$DIR"

cat > "$DIR/google-chrome.sources" <<'EOF'
Types: deb
URIs: https://dl.google.com/linux/chrome-stable/deb/
Suites: stable
Components: main
EOF
cat > "$DIR/google-chrome.list" <<'EOF'
deb [arch=amd64] https://dl.google.com/linux/chrome/deb/ stable main
EOF
cat > "$DIR/extra-chrome.list" <<'EOF'
deb https://dl.google.com/linux/chrome/deb/ stable main
EOF
cat > "$DIR/ubuntu.sources" <<'EOF'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble
Components: main
EOF
echo "see google for docs" > "$DIR/notes.txt"
# Already disabled. Content still mentions Chrome; must not be renamed again.
cat > "$DIR/google-chrome.sources.disabled" <<'EOF'
Types: deb
URIs: https://dl.google.com/linux/chrome-stable/deb/
EOF
cat > "$DIR/legacy-chrome.list.disabled-by-box-access" <<'EOF'
deb https://dl.google.com/linux/chrome/deb/ stable main
EOF

disable_hanging_chrome_apt_sources "$DIR"

[[ ! -f "$DIR/google-chrome.sources" ]]
[[ -f "$DIR/google-chrome.sources.disabled-by-box-access" ]]
[[ ! -f "$DIR/google-chrome.list" ]]
[[ -f "$DIR/google-chrome.list.disabled-by-box-access" ]]
[[ ! -f "$DIR/extra-chrome.list" ]]
[[ -f "$DIR/extra-chrome.list.disabled-by-box-access" ]]
[[ -f "$DIR/ubuntu.sources" ]]
[[ -f "$DIR/notes.txt" ]]
[[ -f "$DIR/google-chrome.sources.disabled" ]]
[[ ! -e "$DIR/google-chrome.sources.disabled.disabled-by-box-access" ]]
[[ -f "$DIR/legacy-chrome.list.disabled-by-box-access" ]]
[[ ! -e "$DIR/legacy-chrome.list.disabled-by-box-access.disabled-by-box-access" ]]
echo "ok chrome sources disabled, other sources kept"
echo "ok already-disabled chrome sources are not renamed again"

# Second run is a no-op.
out=$(disable_hanging_chrome_apt_sources "$DIR")
if grep -q 'disabling ' <<<"$out"; then
  echo "FAIL second run tried to disable a source again"
  printf '%s\n' "$out"
  exit 1
fi
[[ -f "$DIR/ubuntu.sources" ]]
echo "ok second run leaves disabled sources disabled"
