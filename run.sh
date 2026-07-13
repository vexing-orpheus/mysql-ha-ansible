#!/usr/bin/env bash
set -euo pipefail

playbook="${1:-site.yml}"
shift || true

read -rp "SSH username: " ssh_user

exec ansible-playbook "$playbook" \
  -u "$ssh_user" \
  --ask-pass \
  --ask-become-pass \
  "$@"
