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
# shellcheck source=lib/profile.sh
source "${SCRIPT_DIR}/lib/profile.sh"

load_profile "${RAPUNZEL_HARNESS:-pi}"
IMAGE=${RAPUNZEL_IMAGE:-$H_IMAGE}
VOLUME=${RAPUNZEL_VOLUME:-rapunzel-test-${H_NAME}}

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

# Extra docker run options (such as --env) for the next run_env call.
RUN_OPTS=()
run() {
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        --network none \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --mount "type=volume,src=${VOLUME},dst=${H_STATE_DIR},volume-nocopy" \
        ${RUN_OPTS[@]+"${RUN_OPTS[@]}"} \
        "$IMAGE" \
        "$@"
}

# Run through the real entrypoint so the bootstrap step is exercised too.
version=$(run "$H_CMD" --version)
[[ -n "$version" ]] || {
    printf '%s --version produced no output\n' "$H_CMD" >&2
    exit 1
}
printf '%s version: %s\n' "$H_NAME" "$version"

identity=$(run id -un)
[[ "$identity" == "agent" ]] || {
    printf 'expected container user name "agent", got %s\n' "$identity" >&2
    exit 1
}
printf 'identity: %s (%s)\n' "$identity" "$(run id -gn)"

# HOME must be writable by the caller's UID, not only the image's UID 1001.
run bash -c 'touch "$HOME/.probe" && git config --global user.name probe'

# State directory is writable and bootstrapped by the entrypoint.
run test -w "$H_STATE_DIR"

if [[ "$H_NAME" == pi ]]; then
    run node -e 'JSON.parse(require("fs").readFileSync("/home/agent/.pi/agent/settings.json","utf8"))'
    run test -s /home/agent/.pi/agent/settings.json
    run test -s /home/agent/.pi/agent/models.json

    # Sessions must stay in the volume: pi resolves a relative sessionDir from
    # /workspace, the mounted project. Plant the old relative value first.
    run node -e '
        const fs = require("fs"), f = "/home/agent/.pi/agent/settings.json";
        const s = JSON.parse(fs.readFileSync(f, "utf8")); s.sessionDir = "sessions";
        fs.writeFileSync(f, JSON.stringify(s));
    '
    session_dir=$(run node -p 'require("/home/agent/.pi/agent/settings.json").sessionDir')
    [[ "$session_dir" == /home/agent/.pi/agent/sessions ]] || {
        printf 'sessionDir is %s, expected the agent volume\n' "$session_dir" >&2
        exit 1
    }

    # The platform pruning in the Dockerfile must keep this platform's esbuild binary.
    run node -e '
        const { createRequire } = require("node:module");
        const require_ = createRequire("/usr/local/lib/node_modules/@earendil-works/pi-coding-agent/package.json");
        require_("esbuild").transformSync("let x: number = 1", { loader: "ts" });
    '
fi

if [[ "$H_NAME" == opencode ]]; then
    provider_file=/home/agent/.opencode-state/rapunzel/opencode.json

    # Without provider settings the rapunzel file is empty.
    run node -e '
        const c = require(process.argv[1]);
        if (Object.keys(c).length !== 0) throw new Error("expected an empty provider file");
    ' "$provider_file"

    # pi's custom-provider settings become an opencode provider that refers to
    # the key by name. The listing fails offline, so only RAPUNZEL_MODEL is in it.
    RUN_OPTS=(
        --env RAPUNZEL_PROVIDER=router --env RAPUNZEL_API_BASE_URL=https://router.invalid/v1
        --env RAPUNZEL_MODEL=a/b --env RAPUNZEL_API_KEY_VARIABLE=ROUTER_API_KEY
        --env ROUTER_API_KEY=sekrit-test-key
    )
    run bash -c '
        set -e
        node -e "
            const p = require(process.argv[1]).provider.router;
            const c = require(process.argv[1]);
            if (p.npm !== \"@ai-sdk/openai-compatible\") throw new Error(\"npm: \" + p.npm);
            if (p.options.baseURL !== \"https://router.invalid/v1\") throw new Error(\"baseURL\");
            if (p.options.apiKey !== \"{env:ROUTER_API_KEY}\") throw new Error(\"apiKey: \" + p.options.apiKey);
            if (Object.keys(p.models).join() !== \"a/b\") throw new Error(\"models\");
            if (c.model !== \"router/a/b\") throw new Error(\"model: \" + c.model);
        " "$1"
        if grep -rq sekrit-test-key "$RAPUNZEL_STATE_DIR"; then echo "API key written to the volume" >&2; exit 1; fi
        opencode models router | grep -qx router/a/b
    ' -- "$provider_file"
    RUN_OPTS=()

    # A listing fills the models and is cached for the next start that cannot
    # reach the endpoint. A loopback stub stands in for the router.
    run bash -c '
        set -e
        bootstrap=/usr/local/lib/rapunzel/bootstrap-harness.mjs
        node -e "
            require(\"http\").createServer((req, res) => {
                res.setHeader(\"content-type\", \"application/json\");
                res.end(JSON.stringify({ data: [
                    { id: \"x/y\", name: \"X Y\", context_length: 200000, max_output_tokens: 32000 },
                    { id: \"z\" },
                ] }));
            }).listen(18080, \"127.0.0.1\");
        " &
        server=$!
        for _ in $(seq 50); do node -e "fetch(\"http://127.0.0.1:18080/\").catch(() => process.exit(1))" && break; sleep 0.1; done
        export RAPUNZEL_PROVIDER=router RAPUNZEL_API_BASE_URL=http://127.0.0.1:18080/v1 RAPUNZEL_MODEL=a/b
        node "$bootstrap" "$RAPUNZEL_STATE_DIR"
        check="
            const m = require(process.argv[1]).provider.router.models;
            if (Object.keys(m).sort().join() !== \"a/b,x/y,z\") throw new Error(\"models: \" + Object.keys(m));
            if (m[\"x/y\"].name !== \"X Y\" || m[\"x/y\"].limit.context !== 200000) throw new Error(\"x/y\");
        "
        node -e "$check" "$1"
        kill "$server"; wait "$server" 2>/dev/null || true
        node "$bootstrap" "$RAPUNZEL_STATE_DIR" 2>&1 | grep -q "using 2 cached models"
        node -e "$check" "$1"
    ' -- "$provider_file"
fi

printf 'PASS: offline smoke test\n'