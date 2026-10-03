#!/usr/bin/env bash
# Docker availability check shared by the wrapper and check scripts.
#
# Source this file from the scripts. It defines:
#   require_docker NAME - exit with advice when the Docker engine is unreachable

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
