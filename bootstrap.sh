#!/usr/bin/env bash
# Backward-compatible name for ./up.sh. Same arguments, including --install-only.
here=$(cd "$(dirname "$0")" && pwd) || exit 1
exec "$here/up.sh" "$@"
