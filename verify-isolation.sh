#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
IMAGE=${PI_DOCKER_IMAGE:-pi-project-sandbox}
VOLUME=${PI_DOCKER_VOLUME:-pi-project-verify}
PROJECT_DIR=${1:-$ROOT_DIR}

[[ -d "$PROJECT_DIR" ]] || {
    printf 'Usage: %s [project-directory]\n' "$0" >&2
    exit 2
}
PROJECT_DIR=$(cd -- "$PROJECT_DIR" && pwd -P)
HOST_HOME=${HOME:-}

printf 'Building/checking image: %s\n' "$IMAGE"
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    printf 'Image %s is missing. Run docker build -t %s . first.\n' "$IMAGE" "$IMAGE" >&2
    exit 1
}
docker volume create "$VOLUME" >/dev/null
docker run --rm \
    --user 0:0 \
    --entrypoint /bin/bash \
    --mount "type=volume,src=${VOLUME},dst=/home/pi/.pi/agent,volume-nocopy" \
    "$IMAGE" \
    -euo pipefail -c "chown -R $(id -u):$(id -g) /home/pi/.pi/agent"

# Use the same two mounts as pi-project, with no host HOME or environment file.
# volume-nocopy prevents Docker from copying image seed files into the named volume.
docker run --rm \
    --user "$(id -u):$(id -g)" \
    --workdir /workspace \
    --network none \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --mount "type=bind,src=${PROJECT_DIR},dst=/workspace" \
    --mount "type=volume,src=${VOLUME},dst=/home/pi/.pi/agent,volume-nocopy" \
    --env HOME=/home/pi \
    --env PI_CODING_AGENT_DIR=/home/pi/.pi/agent \
    --env HOST_HOME_PATH="$HOST_HOME" \
    "$IMAGE" \
    /usr/local/lib/pi-docker/verify-isolation-inner.sh
