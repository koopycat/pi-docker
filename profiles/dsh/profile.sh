# shellcheck shell=bash
# shellcheck disable=SC2034
# Harness profile for DeepSeek Harness (dsh). Sourced by lib/profile.sh; it only
# declares data, and the launcher keeps every enforcement decision.

H_NAME=dsh
H_CMD=dsh
H_IMAGE=rapunzel:dsh
# DSH_HOME holds profiles, the home-level patch, .credentials.yaml, sessions,
# and storages.
H_STATE_DIR=/home/agent/.dsh
H_STATE_ENV=DSH_HOME

# dsh ships no terminal UI. Without harness arguments rapunzel starts the web UI
# and publishes it on the host's loopback (H_WEB_PORT, RAPUNZEL_PORT
# overrides); `rapunzel --harness dsh --exec . dsh headless "task"` runs one
# task in the terminal.
H_DEFAULT_ARGS=(web --patch /usr/local/lib/rapunzel/dsh-web.patch.yml --no-open)
H_WEB_PORT=3080
H_WEB_PORT_ARG=--port

# DEEPSEEK_API_KEY is in the launcher's shared list.
H_ENV_ALLOW=(EXA_API_KEY PERPLEXITY_API_KEY)
H_ENV_ALLOW_GATEWAY=()
# DSH_* variables reconfigure dsh's sandbox and permissions (for example
# DSH_PERMISSION_MODE); none comes from the host.
H_ENV_DENY=(DSH_HOME DSH_AGENTS_HOME DSH_PERMISSION_MODE DSH_TELEMETRY_OTLP_URL)
# OpenTelemetry feedback upload connects directly, ignoring the proxy.
H_OFFLINE_ENV=(DSH_TELEMETRY_MODE=DISABLED)

H_EGRESS_HOSTS=(api.deepseek.com)

# strict mode would need a gateway route for DeepSeek's API; untested.
H_STRICT_SUPPORTED=false
