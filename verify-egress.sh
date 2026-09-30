#!/usr/bin/env bash
set -Eeuo pipefail

# Checks PI_DOCKER_EGRESS=gateway through the real launcher. An echo server
# stands in for a provider, so no credentials or internet access are needed.
# pi-project --exec runs lib/egress-probe.mjs inside the agent container.

SCRIPT_PATH=${BASH_SOURCE[0]}
# Follow symlinks so a link on PATH still finds lib/ in the checkout.
while [[ -L "$SCRIPT_PATH" ]]; do
    link=$(readlink -- "$SCRIPT_PATH")
    [[ "$link" == /* ]] || link="$(dirname -- "$SCRIPT_PATH")/$link"
    SCRIPT_PATH=$link
done
ROOT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)
IMAGE=${PI_DOCKER_IMAGE:-pi-project-sandbox}
VOLUME=${PI_DOCKER_VOLUME:-pi-project-egress-check}

docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    printf 'Image %s is missing. Run docker build -t %s . first.\n' "$IMAGE" "$IMAGE" >&2
    exit 1
}

random_token() { od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
secret="pd-secret-$(random_token)"
anthropic_secret="pd-secret-$(random_token)"
upstream="pi-docker-egress-upstream-$$"
canary="pi-docker-egress-canary-$$"
canary_port=$((20000 + RANDOM % 20000))
project=$(mktemp -d "${TMPDIR:-/tmp}/pi-egress-project.XXXXXX")
cleanup() {
    docker rm --force "$upstream" "$canary" >/dev/null 2>&1 || true
    rm -rf "$project"
}
trap cleanup EXIT

gateway_resources() {
    docker ps --all --quiet --filter label=pi-docker.gateway=1 | wc -l | tr -d ' '
    docker network ls --quiet --filter label=pi-docker.gateway=1 | wc -l | tr -d ' '
}
before=$(gateway_resources)

# The echo server replies with the path and auth headers it received.
docker run --detach --rm \
    --name "$upstream" \
    --network bridge \
    --user 65534:65534 \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --entrypoint node \
    "$IMAGE" \
    -e 'require("node:http").createServer((req, res) => {
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify({
            path: req.url,
            authorization: req.headers.authorization ?? null,
            xApiKey: req.headers["x-api-key"] ?? null,
        }));
    }).listen(8080);' >/dev/null
# The canary listens on every host address, including a bridge's host side.
# Reaching it from the agent would mean the host is reachable.
docker run --detach --rm \
    --name "$canary" \
    --network host \
    --user 65534:65534 \
    --cap-drop=ALL \
    --security-opt=no-new-privileges \
    --entrypoint node \
    "$IMAGE" \
    -e 'require("node:http").createServer((req, res) => res.end("host reached"))
        .listen(Number(process.argv[1]), "0.0.0.0");' "$canary_port" >/dev/null

upstream_ip=$(docker inspect --format '{{.NetworkSettings.Networks.bridge.IPAddress}}' "$upstream")
[[ -n "$upstream_ip" ]] || {
    printf 'FAIL: echo upstream has no bridge address\n' >&2
    exit 1
}

output=$(
    env -u PI_DOCKER_ENV_FILE -u PI_DOCKER_NETWORK -u PI_DOCKER_API_KEY_VARIABLE \
        -u OPENAI_API_KEY -u PI_DOCKER_BASE_URL \
        PI_DOCKER_IMAGE="$IMAGE" \
        PI_DOCKER_VOLUME="$VOLUME" \
        PI_DOCKER_EGRESS=gateway \
        PI_DOCKER_PROVIDER=echo \
        PI_DOCKER_MODEL=echo-model \
        PI_DOCKER_API=openai-completions \
        PI_DOCKER_API_BASE_URL="http://${upstream_ip}:8080/v1" \
        PI_DOCKER_API_KEY="$secret" \
        ANTHROPIC_API_KEY="$anthropic_secret" \
        "${ROOT_DIR}/pi-project" --exec "$project" \
        node --input-type=module -e "$(<"${ROOT_DIR}/lib/egress-probe.mjs")" "$upstream_ip" "$canary_port"
)

failures=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}
section() { grep "^$1 " <<<"$output" || true; }

grep '^CHECK ' <<<"$output"
[[ "$(section CHECK | grep -c '^CHECK ')" -ge 11 ]] || fail "probe did not report every check"
if grep -q '^CHECK FAIL' <<<"$output"; then
    fail "network checks failed"
fi

env_line=$(section ENV)
models_line=$(section MODELS)
echo_line=$(section ECHO)
[[ -n "$env_line" && -n "$models_line" && -n "$echo_line" ]] || fail "probe output is incomplete"
for value in "$secret" "$anthropic_secret"; do
    [[ "$env_line" != *"$value"* ]] || fail "a real credential reached the agent environment"
    [[ "$models_line" != *"$value"* ]] || fail "a real credential reached models.json"
done
[[ "$models_line" == *'"baseUrl":"http://llm-proxy:8080/anthropic"'* ]] ||
    fail "models.json does not route anthropic through the gateway"
[[ "$models_line" == *'"baseUrl":"http://llm-proxy:8080/custom"'* ]] ||
    fail "models.json does not route the custom provider through the gateway"
[[ "$echo_line" == *"\"authorization\":\"Bearer ${secret}\""* ]] ||
    fail "the gateway did not replace the agent's Authorization header with the real key"
[[ "$echo_line" == *'"xApiKey":null'* ]] || fail "the gateway forwarded the agent's x-api-key header"
[[ "$echo_line" == *'"path":"/v1/echo?probe=1"'* ]] || fail "the gateway did not map /custom to the upstream path"
[[ "$echo_line" != *attacker-key* ]] || fail "the agent's own credential reached the upstream"

[[ "$(gateway_resources)" == "$before" ]] || fail "the gateway container or network was left behind"

if [[ "$failures" -gt 0 ]]; then
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'PASS: credential gateway, no direct egress, no real credentials in the agent\n'
