#!/usr/bin/env bash
# shellcheck disable=SC2034 # EGRESS_*/GATEWAY_* variables are read by the sourcing script
# Egress control: per-run networks plus one sidecar that is pi's only way out.
#
# Source this file from rapunzel. It defines:
#   egress_networks_create - create the per-run internal and outbound networks
#   egress_allow_host      - add a validated host to the allowlist
#   egress_allow_login     - add the hosts a pi /login provider needs
#   egress_allow_private_host - add an exact host that may resolve privately
#   allowlist_configure    - render the Pipelock config
#   allowlist_start        - start Pipelock, the CONNECT allowlist proxy
#   gateway_configure      - render the Caddy credential gateway config
#   gateway_start          - start the Caddy credential gateway
#   egress_stop            - remove the sidecar and both networks again
#
# pi joins only EGRESS_NETWORK. That network is --internal with an isolated
# bridge gateway, so pi has no route off it, no upstream DNS, and no address
# on the host side of the bridge. The sidecar also joins EGRESS_OUTBOUND, a
# per-run bridge of its own, so it never shares a network with unrelated
# containers. See docs/egress.md for the design and its decisions.

EGRESS_PROXY_IMAGE=${RAPUNZEL_EGRESS_PROXY_IMAGE:-ghcr.io/luckypipewrench/pipelock:3.6.0@sha256:66d65eaca81ddae4d0872537bca276bd065baa8f2aebe2960de313cffc53fa47}
EGRESS_PROXY_ALIAS=egress
EGRESS_PROXY_PORT=8888
EGRESS_PROXY_URL="http://${EGRESS_PROXY_ALIAS}:${EGRESS_PROXY_PORT}"

GATEWAY_IMAGE=${RAPUNZEL_GATEWAY_IMAGE:-caddy:2.11.4-alpine@sha256:6aeddd44c3078b0f9a35206472a11420648a79c184603ef95957d0a20044cb2b}
GATEWAY_ALIAS=llm-proxy
GATEWAY_PORT=8080
GATEWAY_URL="http://${GATEWAY_ALIAS}:${GATEWAY_PORT}"
# Placeholder the agent sees wherever a provider expects a key.
GATEWAY_DUMMY_KEY=rapunzel-gateway

EGRESS_NETWORK=""
EGRESS_OUTBOUND=""
EGRESS_SIDECAR=""
EGRESS_HOSTS=()
EGRESS_PRIVATE_HOSTS=()
GATEWAY_PROVIDERS=""
GATEWAY_CUSTOM=false

egress_networks_create() {
    local run_id
    run_id="$(date +%s)-$$-${RANDOM}"

    # Isolated gateway mode (Docker Engine 28+) leaves the bridge without a
    # host-side address, so pi cannot reach services on the host.
    EGRESS_NETWORK="rapunzel-${run_id}"
    if ! docker network create --internal \
        --opt com.docker.network.bridge.gateway_mode_ipv4=isolated \
        --opt com.docker.network.bridge.gateway_mode_ipv6=isolated \
        --label rapunzel.egress=1 \
        "$EGRESS_NETWORK" >/dev/null; then
        EGRESS_NETWORK=""
        printf 'rapunzel: could not create an isolated internal network; RAPUNZEL_EGRESS needs Docker Engine 28 or newer\n' >&2
        return 1
    fi

    EGRESS_OUTBOUND="rapunzel-${run_id}-out"
    if ! docker network create \
        --opt com.docker.network.bridge.enable_icc=false \
        --label rapunzel.egress=1 \
        "$EGRESS_OUTBOUND" >/dev/null; then
        EGRESS_OUTBOUND=""
        printf 'rapunzel: could not create the outbound network for the egress sidecar\n' >&2
        return 1
    fi
    EGRESS_SIDECAR="rapunzel-egress-${run_id}"
}

# Add one allowlist entry after checking it is a plain DNS name.
egress_allow_host() {
    local host
    host=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    [[ -n "$host" ]] || return 0
    if [[ ! "$host" =~ ^(\*\.)?([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
        printf 'rapunzel: not an allowable host name: %s\n' "$1" >&2
        return 1
    fi
    local known
    for known in ${EGRESS_HOSTS[@]+"${EGRESS_HOSTS[@]}"}; do
        [[ "$known" != "$host" ]] || return 0
    done
    EGRESS_HOSTS+=("$host")
}

# Allow an exact host that resolves to a private address, such as a model
# router on the local network. Pipelock otherwise refuses private and
# loopback destinations after DNS resolution, allowlisted or not. Only exact
# names: whoever controls a name's DNS decides where it points.
egress_allow_private_host() {
    if [[ "$1" == *'*'* ]]; then
        printf 'rapunzel: RAPUNZEL_EGRESS_ALLOW_PRIVATE takes exact host names, not wildcards: %s\n' "$1" >&2
        return 1
    fi
    egress_allow_host "$1" || return 1
    EGRESS_PRIVATE_HOSTS+=("$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')")
}

# Add the hosts that a pi /login (OAuth) provider uses for its model API and
# token refresh. Names are pi provider IDs, as in auth.json. Taken from pi-ai
# 0.99.1 (auth/oauth/*, providers/*); review them when pi changes providers. The set comes from the host's
# environment, never from auth.json: pi controls that file and could widen
# its own allowlist through it.
egress_allow_login() {
    case "$1" in
        # "Sign in with ChatGPT": the subscription token is used directly
        # against api.openai.com.
        openai) egress_allow_host api.openai.com && egress_allow_host auth.openai.com ;;
        # pi's legacy ChatGPT Plus/Pro login, served from chatgpt.com.
        openai-codex) egress_allow_host chatgpt.com && egress_allow_host auth.openai.com ;;
        anthropic) egress_allow_host api.anthropic.com && egress_allow_host platform.claude.com ;;
        # The model host comes from the token (individual, business, or
        # enterprise). api.github.com also exposes GitHub's whole REST API.
        github-copilot) egress_allow_host api.github.com && egress_allow_host '*.githubcopilot.com' ;;
        *)
            printf 'rapunzel: unknown RAPUNZEL_EGRESS_LOGINS entry: %s (supported: openai, openai-codex, anthropic, github-copilot)\n' \
                "$1" >&2
            return 1
            ;;
    esac
}

# Print the host of an http(s) URL, or fail.
url_host() {
    if [[ ! "$1" =~ ^https?://([^/?#:@[:space:]]+)(:[0-9]+)?(/[^?#[:space:]]*)?$ ]]; then
        printf 'rapunzel: RAPUNZEL_API_BASE_URL is not an http(s) URL without credentials, query or fragment: %s\n' \
            "$1" >&2
        return 1
    fi
    printf '%s' "${BASH_REMATCH[1]}"
}

# Render the Pipelock config into DIR from EGRESS_HOSTS.
allowlist_configure() {
    local dir=${1:?allowlist_configure requires a directory}
    local host
    if [[ ${#EGRESS_HOSTS[@]} -eq 0 ]]; then
        printf 'rapunzel: RAPUNZEL_EGRESS=allowlist needs at least one host: set ANTHROPIC_API_KEY, OPENAI_API_KEY, RAPUNZEL_API_BASE_URL, RAPUNZEL_EGRESS_LOGINS, RAPUNZEL_EGRESS_ALLOW, or RAPUNZEL_EGRESS_ALLOW_PRIVATE\n' >&2
        return 1
    fi
    {
        printf '%s\n' \
            'version: 1' \
            '# Only api_allowlist hosts are reachable.' \
            'mode: strict' \
            'enforce: true' \
            'explain_blocks: false' \
            'api_allowlist:'
        for host in "${EGRESS_HOSTS[@]}"; do
            printf '  - "%s"\n' "$host"
        done
        if [[ ${#EGRESS_PRIVATE_HOSTS[@]} -gt 0 ]]; then
            printf '%s\n' '# Exact hosts that may resolve to private addresses.' 'trusted_domains:'
            for host in "${EGRESS_PRIVATE_HOSTS[@]}"; do
                printf '  - "%s"\n' "$host"
            done
        fi
        printf '%s\n' \
            'forward_proxy:' \
            '  enabled: true' \
            '  # The TLS ClientHello must name the CONNECT host. Without this, a' \
            '  # tunnel to an allowed CDN-hosted name reaches any co-tenant site.' \
            '  sni_verification: true' \
            '  sni_require_tls: true' \
            '  # Long model turns can stream quietly for minutes.' \
            '  idle_timeout_seconds: 900' \
            '# Keep /metrics and /stats off the port pi can reach.' \
            'metrics_listen: "127.0.0.1:9091"' \
            'logging:' \
            '  format: json' \
            '  output: stdout' \
            '  include_allowed: false' \
            '  include_blocked: true'
    } >"${dir}/pipelock.yaml"
}

allowlist_start() {
    local dir=${1:?allowlist_start requires a directory}
    # The image has no shell, and a read-only root refuses docker cp, so the
    # config goes into an anonymous volume before the container starts.
    docker create \
        --name "$EGRESS_SIDECAR" \
        --label rapunzel.egress=1 \
        --network "$EGRESS_NETWORK" \
        --network-alias "$EGRESS_PROXY_ALIAS" \
        --user 65532:65532 \
        --read-only \
        --tmpfs /tmp \
        --mount type=volume,dst=/config \
        --env PIPELOCK_HOME=/tmp/pipelock \
        --cap-drop=ALL \
        --security-opt=no-new-privileges \
        --pids-limit 256 \
        --memory 512m \
        "$EGRESS_PROXY_IMAGE" \
        run --config /config/pipelock.yaml --listen "0.0.0.0:${EGRESS_PROXY_PORT}" >/dev/null
    docker cp --quiet "${dir}/pipelock.yaml" "${EGRESS_SIDECAR}:/config/pipelock.yaml"
    docker network connect "$EGRESS_OUTBOUND" "$EGRESS_SIDECAR"
    docker start "$EGRESS_SIDECAR" >/dev/null
    _egress_wait /pipelock healthcheck --addr "127.0.0.1:${EGRESS_PROXY_PORT}"
}

# Render the Caddyfile and the gateway env-file into DIR.
# Reads GW_ANTHROPIC_KEY, GW_OPENAI_KEY, GW_CUSTOM_URL, GW_CUSTOM_KEY and
# GW_CUSTOM_API. Sets GATEWAY_PROVIDERS and GATEWAY_CUSTOM.
gateway_configure() {
    local dir=${1:?gateway_configure requires a directory}
    local caddyfile="${dir}/Caddyfile" envfile="${dir}/gateway.env"
    local routes="" origin="" prefix=""

    : >"$envfile"
    chmod 600 "$envfile"

    # Secrets stay in the env-file and are read through {env.*} at request
    # time, so the rendered config itself contains none.
    if [[ -n "${GW_ANTHROPIC_KEY:-}" ]]; then
        printf 'GW_ANTHROPIC_KEY=%s\n' "$GW_ANTHROPIC_KEY" >>"$envfile"
        routes+=$(_gateway_route /anthropic https://api.anthropic.com "" x-api-key GW_ANTHROPIC_KEY)$'\n'
        GATEWAY_PROVIDERS+="anthropic,"
    fi
    if [[ -n "${GW_OPENAI_KEY:-}" ]]; then
        printf 'GW_OPENAI_KEY=%s\n' "$GW_OPENAI_KEY" >>"$envfile"
        routes+=$(_gateway_route /openai https://api.openai.com "" bearer GW_OPENAI_KEY)$'\n'
        GATEWAY_PROVIDERS+="openai,"
    fi
    if [[ -n "${GW_CUSTOM_URL:-}" ]]; then
        if [[ ! "$GW_CUSTOM_URL" =~ ^(https?://[^/?#@[:space:]]+)(/[^?#[:space:]]*)?$ ]]; then
            printf 'rapunzel: RAPUNZEL_API_BASE_URL is not an http(s) URL without credentials, query or fragment: %s\n' \
                "$GW_CUSTOM_URL" >&2
            return 1
        fi
        origin=${BASH_REMATCH[1]}
        prefix=${BASH_REMATCH[2]%/}
        printf 'GW_CUSTOM_KEY=%s\n' "${GW_CUSTOM_KEY:-}" >>"$envfile"
        if [[ "${GW_CUSTOM_API:-}" == anthropic-messages ]]; then
            routes+=$(_gateway_route /custom "$origin" "$prefix" x-api-key GW_CUSTOM_KEY)$'\n'
        else
            routes+=$(_gateway_route /custom "$origin" "$prefix" bearer GW_CUSTOM_KEY)$'\n'
        fi
        GATEWAY_CUSTOM=true
    fi
    GATEWAY_PROVIDERS=${GATEWAY_PROVIDERS%,}

    if [[ -z "$routes" ]]; then
        printf '%s\n' \
            'rapunzel: RAPUNZEL_EGRESS=strict needs ANTHROPIC_API_KEY, OPENAI_API_KEY, or a custom provider (RAPUNZEL_API_BASE_URL).' \
            'rapunzel: /login (subscription) credentials cannot stay outside the sandbox; use RAPUNZEL_EGRESS=allowlist with RAPUNZEL_EGRESS_LOGINS instead.' >&2
        return 1
    fi

    cat >"$caddyfile" <<EOF
{
	admin off
	auto_https off
}

:${GATEWAY_PORT} {
	handle /healthz {
		respond 204
	}
${routes}
	handle {
		respond 403
	}
}
EOF
}

# Print one handle_path block. Arguments: route prefix, upstream origin,
# upstream path prefix, auth style (x-api-key|bearer), key variable name.
_gateway_route() {
    local route=$1 origin=$2 prefix=$3 style=$4 key=$5
    local auth
    if [[ "$style" == x-api-key ]]; then
        auth=$'\t\t\theader_up -Authorization\n\t\t\theader_up X-Api-Key {env.'"$key"'}'
    else
        auth=$'\t\t\theader_up -X-Api-Key\n\t\t\theader_up Authorization "Bearer {env.'"$key"'}"'
    fi
    printf '\thandle_path %s/* {\n' "$route"
    [[ -n "$prefix" ]] && printf '\t\trewrite * %s{uri}\n' "$prefix"
    printf '\t\treverse_proxy %s {\n' "$origin"
    printf '\t\t\theader_up Host {upstream_hostport}\n'
    printf '%s\n' "$auth"
    printf '\t\t\tflush_interval -1\n'
    printf '\t\t}\n\t}\n'
}

gateway_start() {
    local dir=${1:?gateway_start requires a directory}
    # The image's caddy binary carries the NET_BIND_SERVICE file capability
    # and cannot be executed without it in the bounding set.
    # The config travels as an env value rather than a bind mount, so it works
    # without Docker Desktop file sharing and with remote Docker contexts.
    docker create \
        --name "$EGRESS_SIDECAR" \
        --label rapunzel.egress=1 \
        --network "$EGRESS_NETWORK" \
        --network-alias "$GATEWAY_ALIAS" \
        --user 65534:65534 \
        --read-only \
        --tmpfs /tmp \
        --env XDG_CONFIG_HOME=/tmp/config \
        --env XDG_DATA_HOME=/tmp/data \
        --cap-drop=ALL \
        --cap-add=NET_BIND_SERVICE \
        --security-opt=no-new-privileges \
        --pids-limit 256 \
        --memory 512m \
        --env-file "${dir}/gateway.env" \
        --env "GW_CADDYFILE=$(<"${dir}/Caddyfile")" \
        "$GATEWAY_IMAGE" \
        sh -c 'printf "%s\n" "$GW_CADDYFILE" >/tmp/Caddyfile && exec caddy run --config /tmp/Caddyfile --adapter caddyfile' \
        >/dev/null
    docker network connect "$EGRESS_OUTBOUND" "$EGRESS_SIDECAR"
    docker start "$EGRESS_SIDECAR" >/dev/null
    _egress_wait wget -q -O /dev/null "http://127.0.0.1:${GATEWAY_PORT}/healthz"
}

# Run a readiness command inside the sidecar until it succeeds.
_egress_wait() {
    local attempt
    for attempt in $(seq 1 50); do
        if docker exec "$EGRESS_SIDECAR" "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    printf 'rapunzel: the egress sidecar did not become ready after %s attempts:\n' "$attempt" >&2
    docker logs --tail 20 "$EGRESS_SIDECAR" >&2 || true
    return 1
}

egress_stop() {
    if [[ -n "$EGRESS_SIDECAR" ]]; then
        # --volumes also removes the anonymous config volume.
        docker rm --force --volumes "$EGRESS_SIDECAR" >/dev/null 2>&1 || true
    fi
    local network
    for network in "$EGRESS_NETWORK" "$EGRESS_OUTBOUND"; do
        [[ -z "$network" ]] || docker network rm "$network" >/dev/null 2>&1 || true
    done
}
