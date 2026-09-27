#!/usr/bin/env bash
# Shared named-volume helpers: per-project naming and ownership preparation.
#
# Source this file from the wrapper scripts. It defines:
#   project_volume_name  - stable per-project volume name derived from a path
#   prepare_volume_owner - make a named volume writable by the invoking UID/GID

# Derive a short, stable volume suffix from a canonical project path.
project_hash() {
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | cut -c1-12
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | cut -c1-12
    else
        printf 'a sha256 tool (shasum or sha256sum) is required to derive the project volume\n' >&2
        return 1
    fi
}

# Print the default per-project agent volume name for a canonical project path.
project_volume_name() {
    : "${1:?project_volume_name requires a project path}"
    local hash
    hash=$(project_hash "$1") || return 1
    printf 'pi-project-agent-%s' "$hash"
}
#
# Make the agent volume writable by the invoking host UID/GID.
#
# The agent volume is created by `docker volume create` (root-owned) and mounted
# with `volume-nocopy`, so Docker never seeds it with the image's home-directory
# ownership. That means the volume root is owned by root:root and the runtime,
# which runs as the caller's non-root UID, cannot create files in it.
#
# This applies on every platform, including Docker Desktop: named volumes live in
# the VM's filesystem and are root-owned regardless of the host. Preparation is
# idempotent and becomes a single marker read after the first successful run.
#
# Requires IMAGE and VOLUME to be set. Must be invoked as a non-root user.

prepare_volume_owner() {
    : "${IMAGE:?prepare_volume_owner requires IMAGE to be set}"
    : "${VOLUME:?prepare_volume_owner requires VOLUME to be set}"

    local uid gid
    uid=$(id -u)
    gid=$(id -g)
    if [[ "$uid" == "0" ]]; then
        printf 'prepare_volume_owner: refusing to prepare a volume as root\n' >&2
        return 1
    fi

    docker volume create "$VOLUME" >/dev/null

    # Fast path: the volume was already prepared for this exact owner.
    if docker run --rm --user 0:0 --network none --cap-drop=ALL --cap-add=DAC_OVERRIDE \
        --security-opt=no-new-privileges \
        --entrypoint /bin/bash \
        --mount "type=volume,src=${VOLUME},dst=/home/pi/.pi/agent,volume-nocopy" \
        "$IMAGE" \
        -euo pipefail -c '[[ -f /home/pi/.pi/agent/.owner-initialized ]] && [[ "$(</home/pi/.pi/agent/.owner-initialized)" == "$1:$2" ]]' \
        -- "$uid" "$gid"; then
        return 0
    fi

    docker run --rm \
        --user 0:0 \
        --network none \
        --cap-drop=ALL \
        --cap-add=CHOWN \
        --cap-add=DAC_OVERRIDE \
        --security-opt=no-new-privileges \
        --entrypoint /bin/bash \
        --mount "type=volume,src=${VOLUME},dst=/home/pi/.pi/agent,volume-nocopy" \
        "$IMAGE" \
        -euo pipefail -c 'chown -R "$1:$2" /home/pi/.pi/agent' -- "$uid" "$gid"

    docker run --rm \
        --user "${uid}:${gid}" \
        --network none \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --entrypoint /bin/bash \
        --mount "type=volume,src=${VOLUME},dst=/home/pi/.pi/agent,volume-nocopy" \
        "$IMAGE" \
        -euo pipefail -c 'printf "%s:%s\n" "$1" "$2" > /home/pi/.pi/agent/.owner-initialized' \
        -- "$uid" "$gid"
}