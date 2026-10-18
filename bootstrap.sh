#!/usr/bin/env bash
# Backward-compatible name for ./up.sh.
# Forwards every argument (--install-only, --no-watchdogs).
here=$(realpath "$(dirname "$0")") || exit 1
exec "$here/up.sh" "$@"
