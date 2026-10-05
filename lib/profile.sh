#!/usr/bin/env bash
# Harness profile loader.
#
# Source this file from the wrapper scripts. It defines:
#   load_profile - validate a harness name and source profiles/<name>/profile.sh
#
# A profile is data only: it names the harness command, its state directory,
# and its environment names. It never changes what the launcher enforces.
# Profiles ship in this repository; there is no user-supplied profile path,
# because sourcing one would run arbitrary code on the host.

PROFILES_DIR="${SCRIPT_DIR:?lib/profile.sh requires SCRIPT_DIR}/profiles"

load_profile() {
    local name=${1:?load_profile requires a harness name} var
    if [[ ! "$name" =~ ^[a-z][a-z0-9-]*$ || ! -f "${PROFILES_DIR}/${name}/profile.sh" ]]; then
        printf 'rapunzel: unknown harness: %s (available: %s)\n' "$name" \
            "$(find "$PROFILES_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort | paste -sd, -)" >&2
        return 1
    fi
    # shellcheck disable=SC2034
    H_ENV_ALLOW=() H_ENV_ALLOW_GATEWAY=() H_ENV_DENY=() H_OFFLINE_ENV=()
    # shellcheck disable=SC2034
    H_EGRESS_HOSTS=() H_STRICT_SUPPORTED=true
    # shellcheck disable=SC2034
    H_DEFAULT_ARGS=() H_WEB_PORT='' H_WEB_PORT_ARG='' H_STATE_ENV=''
    # shellcheck disable=SC1090
    source "${PROFILES_DIR}/${name}/profile.sh"
    # H_STATE_ENV may be empty for a harness without a single home variable
    # (opencode); its image then points the harness at H_STATE_DIR.
    for var in H_NAME H_CMD H_IMAGE H_STATE_DIR; do
        if [[ -z "${!var:-}" ]]; then
            printf 'rapunzel: profile %s does not set %s\n' "$name" "$var" >&2
            return 1
        fi
    done
    if [[ "$H_NAME" != "$name" ]]; then
        printf 'rapunzel: profile %s declares H_NAME=%s\n' "$name" "$H_NAME" >&2
        return 1
    fi
    if [[ "$H_STATE_DIR" != /home/agent/* ]]; then
        printf 'rapunzel: profile %s: H_STATE_DIR must be under /home/agent\n' "$name" >&2
        return 1
    fi
}
