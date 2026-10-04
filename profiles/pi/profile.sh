# shellcheck shell=bash
# shellcheck disable=SC2034
# Harness profile for the pi coding agent. Sourced by lib/profile.sh; it only
# declares data, and the launcher keeps every enforcement decision (mounts,
# capabilities, egress, host-file protection).

H_NAME=pi
H_CMD=pi
# Image used when RAPUNZEL_IMAGE is not set.
H_IMAGE=rapunzel
# Where the harness keeps config, logins, and sessions in the container, and the
# variable that points it there. The per-project named volume mounts here.
H_STATE_DIR=/home/agent/.pi/agent
H_STATE_ENV=PI_CODING_AGENT_DIR

# Names that may enter the container, on top of the launcher's shared list
# (provider API keys and proxy settings).
H_ENV_ALLOW=(
    RAPUNZEL_PROVIDER RAPUNZEL_MODEL RAPUNZEL_MODEL_ID RAPUNZEL_MODEL_NAME
    RAPUNZEL_API_BASE_URL RAPUNZEL_BASE_URL RAPUNZEL_API RAPUNZEL_API_KEY
    RAPUNZEL_API_KEY_VARIABLE RAPUNZEL_REASONING RAPUNZEL_CONTEXT_WINDOW
    RAPUNZEL_MAX_TOKENS RAPUNZEL_COMPAT_JSON RAPUNZEL_HEADERS_JSON
    RAPUNZEL_AUTH_HEADER
    PI_OFFLINE PI_SKIP_VERSION_CHECK PI_TELEMETRY PI_CACHE_RETENTION
)
# In strict mode the agent gets only these; credentials go to the gateway.
H_ENV_ALLOW_GATEWAY=(
    RAPUNZEL_PROVIDER RAPUNZEL_MODEL RAPUNZEL_MODEL_ID RAPUNZEL_MODEL_NAME
    RAPUNZEL_API RAPUNZEL_REASONING RAPUNZEL_CONTEXT_WINDOW
    RAPUNZEL_MAX_TOKENS RAPUNZEL_COMPAT_JSON RAPUNZEL_AUTH_HEADER
    PI_CACHE_RETENTION
)
# Names that must never come from the host, on top of the shared denylist.
H_ENV_DENY=(PI_CODING_AGENT_DIR PI_CODING_AGENT_SESSION_DIR)
# Set in allowlist and strict mode, where pi.dev is not reachable.
H_OFFLINE_ENV=(PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 PI_TELEMETRY=0)
