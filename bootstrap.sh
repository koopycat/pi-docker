#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${RAPUNZEL_STATE_DIR:?RAPUNZEL_STATE_DIR is not set}"
mkdir -p "${CONFIG_DIR}"

# shellcheck disable=SC1091
source /usr/local/lib/rapunzel/setup-identity.sh

# Per-harness defaults (the profile ships this file in its image stage).
if [[ -f /usr/local/lib/rapunzel/bootstrap-harness.mjs ]]; then
    node /usr/local/lib/rapunzel/bootstrap-harness.mjs "${CONFIG_DIR}"
fi

exec "$@"
