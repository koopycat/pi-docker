#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_PATH=${BASH_SOURCE[0]}
# Follow symlinks so a link on PATH still finds lib/ in the checkout.
while [[ -L "$SCRIPT_PATH" ]]; do
    link=$(readlink -- "$SCRIPT_PATH")
    [[ "$link" == /* ]] || link="$(dirname -- "$SCRIPT_PATH")/$link"
    SCRIPT_PATH=$link
done
ROOT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)
# shellcheck source=lib/volumes.sh
source "${ROOT_DIR}/lib/volumes.sh"
# shellcheck source=lib/docker.sh
source "${ROOT_DIR}/lib/docker.sh"
IMAGE=${RAPUNZEL_IMAGE:-rapunzel}
VOLUME=${RAPUNZEL_VOLUME:-rapunzel-verify}
PROJECT_DIR=${1:-$ROOT_DIR}

[[ "$(id -u)" != 0 ]] || {
    printf 'Refusing to run verification as root; invoke it as a non-root user.\n' >&2
    exit 1
}

[[ -d "$PROJECT_DIR" ]] || {
    printf 'Usage: %s [project-directory]\n' "$0" >&2
    exit 2
}
PROJECT_DIR=$(cd -- "$PROJECT_DIR" && pwd -P)
HOST_HOME=${HOME:-}

printf 'Building/checking image: %s\n' "$IMAGE"
require_docker verify-isolation.sh
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    printf 'Image %s is missing. Run docker build -t %s . first.\n' "$IMAGE" "$IMAGE" >&2
    exit 1
}
# The named agent volume is created root-owned and mounted with volume-nocopy,
# so its ownership must be prepared for the invoking UID/GID on every platform.
prepare_volume_owner

# Use the same two mounts as rapunzel, with no host HOME or environment file.
# volume-nocopy prevents Docker from copying image seed files into the named volume.
docker run --rm \
    --user "$(id -u):$(id -g)" \
    --workdir /workspace \
    --network none \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --mount "type=bind,src=${PROJECT_DIR},dst=/workspace" \
    --mount "type=volume,src=${VOLUME},dst=/home/agent/.pi/agent,volume-nocopy" \
    --env HOME=/home/agent \
    --env PI_CODING_AGENT_DIR=/home/agent/.pi/agent \
    --env HOST_HOME_PATH="$HOST_HOME" \
    "$IMAGE" \
    /usr/local/lib/rapunzel/verify-isolation-inner.sh
