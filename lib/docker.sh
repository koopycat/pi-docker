#!/usr/bin/env bash
# Docker availability check shared by the wrapper and check scripts.
#
# Source this file from the scripts. It defines:
#   require_docker NAME - exit with advice when the Docker engine is unreachable
#   ensure_image NAME IMAGE TARGET CONTEXT - build a missing local image

require_docker() {
    local name=${1:?require_docker requires the calling script name}
    local error context host
    if ! command -v docker >/dev/null 2>&1; then
        printf '%s: docker is not installed or not on PATH\n' "$name" >&2
        exit 1
    fi
    # docker version reaches the engine; the client part alone always works.
    if error=$(docker version --format '{{.Server.Version}}' 2>&1 >/dev/null); then
        return 0
    fi

    context=$(docker context show 2>/dev/null || true)
    host=${DOCKER_HOST:-}
    {
        printf '%s: cannot reach the Docker engine' "$name"
        if [[ -n "$host" ]]; then
            printf ' (DOCKER_HOST=%s)' "$host"
        elif [[ -n "$context" ]]; then
            printf ' (docker context: %s)' "$context"
        fi
        printf '.\n'
        printf '%s\n' "$error" | sed -n '1,3s/^/  /p'
        printf 'Start the engine, then try again:\n'
        case "${context}:$(uname -s)" in
            colima*:*) printf '  colima start\n' ;;
            desktop-linux:* | *:Darwin) printf '  start Docker Desktop (open -a Docker), or another engine such as: colima start\n' ;;
            *:Linux) printf '  sudo systemctl start docker   (or start Docker Desktop)\n' ;;
            *) printf '  start Docker Desktop or the Docker service\n' ;;
        esac
        printf 'If the engine runs under another context, list and select it:\n'
        printf '  docker context ls\n  docker context use <name>\n'
    } >&2
    exit 1
}

# Build IMAGE from the Dockerfile stage TARGET in CONTEXT when it does not exist
# yet. Only local names (without a /) are built: docker would otherwise look
# for a same-named image on Docker Hub. Registry references are left to docker.
# Build output goes to stderr, so a command's own stdout stays clean.
ensure_image() {
    local name=${1:?ensure_image requires the calling script name}
    local image=${2:?ensure_image requires an image} target=${3:?ensure_image requires a target}
    local context=${4:?ensure_image requires a build context}
    [[ "$image" != */* ]] || return 0
    docker image inspect "$image" >/dev/null 2>&1 && return 0
    printf '%s: image %s is missing; building it from %s (stage %s)\n' \
        "$name" "$image" "$context" "$target" >&2
    if ! docker build --target "$target" -t "$image" "$context" >&2; then
        printf '%s: building %s failed\n' "$name" "$image" >&2
        exit 1
    fi
}
