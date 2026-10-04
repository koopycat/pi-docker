#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
mkdir -p "${CONFIG_DIR}"

# shellcheck disable=SC1091
source /usr/local/lib/rapunzel/setup-identity.sh

node /usr/local/lib/rapunzel/bootstrap-config.mjs "${CONFIG_DIR}"

# Avoid requiring the host's .pi directory. Project-local resources are available
# only when the user explicitly trusts the mounted project in pi.
exec "$@"
