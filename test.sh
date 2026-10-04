#!/usr/bin/env bash
set -Eeuo pipefail

# Offline smoke test: no provider credentials required and no network access.
# Verifies that the entrypoint bootstraps the agent volume and that pi runs.
#
# Build the image first:
#   docker build -t rapunzel .
# Then run:
#   ./test.sh

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/volumes.sh
source "${SCRIPT_DIR}/lib/volumes.sh"
# shellcheck source=lib/docker.sh
source "${SCRIPT_DIR}/lib/docker.sh"

IMAGE=${RAPUNZEL_IMAGE:-rapunzel}
VOLUME=${RAPUNZEL_VOLUME:-rapunzel-test}

[[ "$(id -u)" != 0 ]] || {
    printf 'Refusing to run tests as root; invoke as a non-root user.\n' >&2
    exit 1
}

require_docker test.sh
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    printf 'Image %s is missing. Run docker build -t %s . first.\n' "$IMAGE" "$IMAGE" >&2
    exit 1
}

prepare_volume_owner

run() {
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        --network none \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --mount "type=volume,src=${VOLUME},dst=/home/agent/.pi/agent,volume-nocopy" \
        "$IMAGE" \
        "$@"
}

# Run through the real entrypoint so the bootstrap step is exercised too.
version=$(run pi --version)
[[ -n "$version" ]] || {
    printf 'pi --version produced no output\n' >&2
    exit 1
}
printf 'pi version: %s\n' "$version"

identity=$(run id -un)
[[ "$identity" == "agent" ]] || {
    printf 'expected container user name "agent", got %s\n' "$identity" >&2
    exit 1
}
printf 'identity: %s (%s)\n' "$identity" "$(run id -gn)"

run node -e 'JSON.parse(require("fs").readFileSync("/home/agent/.pi/agent/settings.json","utf8"))'
run test -s /home/agent/.pi/agent/settings.json
run test -s /home/agent/.pi/agent/models.json

# HOME must be writable by the caller's UID, not only the image's UID 1001.
run bash -c 'touch "$HOME/.probe" && git config --global user.name probe'

# The platform pruning in the Dockerfile must keep this platform's esbuild binary.
run node -e '
    const { createRequire } = require("node:module");
    const require_ = createRequire("/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/package.json");
    require_("esbuild").transformSync("let x: number = 1", { loader: "ts" });
'

printf 'PASS: offline smoke test\n'