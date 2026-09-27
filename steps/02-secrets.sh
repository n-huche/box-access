#!/usr/bin/env bash
# Load secrets and default TS_HOSTNAME. Do not prompt here.
# Prompting happens only when recovery actually needs the keys (04/05),
# so a logged-in box with no secrets file is not asked for them.
# Never print secret values.

step_secrets() {
  if ! declare -F report_ssh_host_keys >/dev/null 2>&1; then
    # shellcheck source=07-ssh-keys.sh
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/07-ssh-keys.sh"
  fi
  load_secrets
  export TS_HOSTNAME="${TS_HOSTNAME:-cursor}"
  # Same moment as before: if openssh regenerated host keys, say so before
  # recovery, which can take a while. The Tailscale IP is not known yet.
  if [[ "$SSH_HOST_KEYS_CHANGED" -eq 1 ]]; then
    report_ssh_host_keys
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_access_parse_args "$@"
  step_secrets
fi
