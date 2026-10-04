# shellcheck shell=bash
# shellcheck disable=SC2034
# Harness profile for Claude Code. Sourced by lib/profile.sh; it only declares
# data, and the launcher keeps every enforcement decision.

H_NAME=claude
H_CMD=claude
H_IMAGE=rapunzel:claude
# CLAUDE_CONFIG_DIR relocates all of Claude Code's state, including the global
# .claude.json, so one volume holds everything.
H_STATE_DIR=/home/agent/.claude
H_STATE_ENV=CLAUDE_CONFIG_DIR

# ANTHROPIC_API_KEY is in the launcher's shared list. CLAUDE_CODE_OAUTH_TOKEN is
# the host's subscription login, from `claude setup-token` on the host; it is
# passed per run and never written to the volume.
H_ENV_ALLOW=(ANTHROPIC_MODEL CLAUDE_CODE_OAUTH_TOKEN)
H_ENV_ALLOW_GATEWAY=()
H_ENV_DENY=(CLAUDE_CONFIG_DIR)
# Auto-update, telemetry, error reporting, and feature-flag fetches have no
# route in allowlist mode; this switches them off instead of letting them fail.
H_OFFLINE_ENV=(CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 DISABLE_AUTOUPDATER=1)

# Needed in allowlist mode whatever the login method. A subscription login also
# needs RAPUNZEL_EGRESS_LOGINS=anthropic (platform.claude.com) and
# RAPUNZEL_EGRESS_ALLOW=claude.ai.
H_EGRESS_HOSTS=(api.anthropic.com)

# strict mode would need ANTHROPIC_BASE_URL pointed at the gateway's /anthropic
# route and a placeholder key. Whether Claude Code accepts that without a
# prompt is untested, so strict is refused for now.
H_STRICT_SUPPORTED=false
