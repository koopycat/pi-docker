# shellcheck shell=bash
# shellcheck disable=SC2034
# Harness profile for opencode. Sourced by lib/profile.sh; it only declares
# data, and the launcher keeps every enforcement decision.

H_NAME=opencode
H_CMD=opencode
H_IMAGE=rapunzel:opencode
# opencode has no single home variable. The image points XDG_CONFIG_HOME,
# XDG_DATA_HOME, XDG_STATE_HOME, and XDG_CACHE_HOME into this directory, so
# opencode.json, auth.json, sessions, and plugin caches share one volume.
H_STATE_DIR=/home/agent/.opencode-state
H_STATE_ENV=

# Provider keys, including OPENCODE_API_KEY for opencode Zen, are in the
# launcher's shared list. OPENCODE_CONFIG_CONTENT carries host-side config such
# as a default model; OPENCODE_PERMISSION can tighten tool approvals.
H_ENV_ALLOW=(OPENCODE_CONFIG_CONTENT OPENCODE_PERMISSION)
H_ENV_ALLOW_GATEWAY=()
# These would move opencode's state out of the volume or load config from
# elsewhere.
H_ENV_DENY=(
    XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
    OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_DB OPENCODE_TEST_HOME
)
# The models.dev catalog and LSP server downloads have no route in the
# restricted modes; opencode falls back to its bundled catalog.
H_OFFLINE_ENV=(OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_LSP_DOWNLOAD=1)

# Provider hosts come from keys (ANTHROPIC_API_KEY, OPENAI_API_KEY) or
# RAPUNZEL_EGRESS_ALLOW; opencode Zen needs opencode.ai.
H_EGRESS_HOSTS=()

# strict mode would need opencode's providers pointed at the gateway routes
# with placeholder keys; untested, so strict is refused for now.
H_STRICT_SUPPORTED=false
