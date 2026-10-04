# shellcheck shell=bash
# shellcheck disable=SC2034
# Harness profile for the OpenAI Codex CLI. Sourced by lib/profile.sh; it only
# declares data, and the launcher keeps every enforcement decision.

H_NAME=codex
H_CMD=codex
H_IMAGE=rapunzel:codex
# CODEX_HOME holds config.toml, auth.json (API key or ChatGPT login), and
# sessions, so one volume holds everything.
H_STATE_DIR=/home/agent/.codex
H_STATE_ENV=CODEX_HOME

# OPENAI_API_KEY is in the launcher's shared list.
H_ENV_ALLOW=(CODEX_API_KEY)
H_ENV_ALLOW_GATEWAY=()
H_ENV_DENY=(CODEX_HOME)
# Update checks and analytics are switched off in config.toml by the bootstrap.
H_OFFLINE_ENV=()

# API keys add api.openai.com through OPENAI_API_KEY. A ChatGPT subscription
# login needs RAPUNZEL_EGRESS_LOGINS=openai-codex (chatgpt.com, auth.openai.com).
H_EGRESS_HOSTS=()

# strict mode would need a gateway route for Codex's Responses API and a
# placeholder key; untested, so strict is refused for now.
H_STRICT_SUPPORTED=false
