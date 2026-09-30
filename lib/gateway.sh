#!/usr/bin/env bash
# shellcheck disable=SC2034 # GATEWAY_* variables are read by the sourcing script
# Credential gateway: a per-run internal network whose only other member is a
# reverse proxy that holds the real provider credentials.
#
# Source this file from the wrapper scripts. It defines:
#   gateway_configure - validate provider settings and render the gateway config
#   gateway_start     - create the internal network and start the gateway
#   gateway_stop      - remove the gateway and its network again
#
# The agent joins only GATEWAY_NETWORK. That network is --internal with an
# isolated bridge gateway, so the agent has no route off it, cannot reach the
# host, and has no upstream DNS. The gateway also joins the default bridge and
# forwards a fixed set of provider routes. It always overwrites the auth
# headers with the real credential, so the agent never holds one and cannot
# send traffic to an allowed provider under a credential of its own.

GATEWAY_IMAGE=${PI_DOCKER_GATEWAY_IMAGE:-caddy:2.11.4-alpine}
GATEWAY_ALIAS=llm-proxy
GATEWAY_PORT=8080
GATEWAY_URL="http://${GATEWAY_ALIAS}:${GATEWAY_PORT}"
# Placeholder the agent sees wherever a provider expects a key.
GATEWAY_DUMMY_KEY=pi-docker-gateway

GATEWAY_PROVIDERS=""
GATEWAY_CUSTOM=false
GATEWAY_NETWORK=""
GATEWAY_CONTAINER=""

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
        if [[ ! "$GW_CUSTOM_URL" =~ ^(https?://[^/?#[:space:]]+)(/[^?#[:space:]]*)?$ ]]; then
            printf 'pi-project: PI_DOCKER_API_BASE_URL is not an http(s) URL without query or fragment: %s\n' \
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
        printf 'pi-project: PI_DOCKER_EGRESS=gateway needs ANTHROPIC_API_KEY, OPENAI_API_KEY, or a custom provider (PI_DOCKER_API_BASE_URL)\n' >&2
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

# Create the internal network and start the gateway from the files in DIR.
gateway_start() {
    local dir=${1:?gateway_start requires a directory}
    local run_id attempt
    run_id="$(date +%s)-$$-${RANDOM}"
    GATEWAY_NETWORK="pi-docker-${run_id}"

    # Isolated gateway mode (Docker Engine 28+) leaves the bridge without a
    # host-side address, so the agent cannot reach services on the host.
    if ! docker network create --internal \
        --opt com.docker.network.bridge.gateway_mode_ipv4=isolated \
        --opt com.docker.network.bridge.gateway_mode_ipv6=isolated \
        --label pi-docker.gateway=1 \
        "$GATEWAY_NETWORK" >/dev/null; then
        GATEWAY_NETWORK=""
        printf 'pi-project: could not create an isolated internal network; PI_DOCKER_EGRESS=gateway needs Docker Engine 28 or newer\n' >&2
        return 1
    fi

    GATEWAY_CONTAINER="pi-docker-gateway-${run_id}"
    # The image's caddy binary carries the NET_BIND_SERVICE file capability
    # and cannot be executed without it in the bounding set.
    # The config travels as an env value rather than a bind mount, so it works
    # without Docker Desktop file sharing and with remote Docker contexts.
    if ! docker run --detach --rm \
        --name "$GATEWAY_CONTAINER" \
        --label pi-docker.gateway=1 \
        --network "$GATEWAY_NETWORK" \
        --network-alias "$GATEWAY_ALIAS" \
        --user 65534:65534 \
        --read-only \
        --tmpfs /tmp \
        --env XDG_CONFIG_HOME=/tmp/config \
        --env XDG_DATA_HOME=/tmp/data \
        --cap-drop=ALL \
        --cap-add=NET_BIND_SERVICE \
        --security-opt=no-new-privileges \
        --env-file "${dir}/gateway.env" \
        --env "GW_CADDYFILE=$(<"${dir}/Caddyfile")" \
        "$GATEWAY_IMAGE" \
        sh -c 'printf "%s\n" "$GW_CADDYFILE" >/tmp/Caddyfile && exec caddy run --config /tmp/Caddyfile --adapter caddyfile' \
        >/dev/null; then
        GATEWAY_CONTAINER=""
        printf 'pi-project: could not start the credential gateway (%s)\n' "$GATEWAY_IMAGE" >&2
        return 1
    fi
    docker network connect bridge "$GATEWAY_CONTAINER"

    for attempt in $(seq 1 50); do
        if docker exec "$GATEWAY_CONTAINER" \
            wget -q -O /dev/null "http://127.0.0.1:${GATEWAY_PORT}/healthz" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
    done
    printf 'pi-project: the credential gateway did not become ready after %s attempts:\n' "$attempt" >&2
    docker logs --tail 20 "$GATEWAY_CONTAINER" >&2 || true
    return 1
}

gateway_stop() {
    if [[ -n "$GATEWAY_CONTAINER" ]]; then
        docker rm --force "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [[ -n "$GATEWAY_NETWORK" ]]; then
        docker network rm "$GATEWAY_NETWORK" >/dev/null 2>&1 || true
    fi
}
