#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}"
mkdir -p "${CONFIG_DIR}"

# Keep the volume usable by the non-root runtime user even when Docker created it.
if [[ "$(id -u)" == 0 ]]; then
    chown -R "${PI_UID:-1001}:${PI_GID:-1001}" "${CONFIG_DIR}"
fi

if [[ ! -f "${CONFIG_DIR}/settings.json" ]]; then
    cat >"${CONFIG_DIR}/settings.json" <<'JSON'
{
  "defaultProjectTrust": "ask",
  "enableAnalytics": false,
  "quietStartup": false
}
JSON
    chmod 0600 "${CONFIG_DIR}/settings.json"
fi

node /usr/local/lib/pi-docker/bootstrap-config.mjs "${CONFIG_DIR}"

# Avoid requiring the host's .pi directory. Project-local resources are available
# only when the user explicitly trusts the mounted project in pi.
exec "$@"
