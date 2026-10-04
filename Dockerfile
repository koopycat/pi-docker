# syntax=docker/dockerfile:1

# Shared base: everything a harness needs except the harness itself. Each
# harness is its own final stage, so one harness's dependencies never ship in
# another's image. `docker build -t rapunzel .` builds the last stage, so pi stays last; build
# another harness with `--target <name>`.
FROM node:24-bookworm-slim AS base

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        git \
        libnss-wrapper \
        ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && nss_wrapper_so=$(dpkg-query -L libnss-wrapper | grep -E '/libnss_wrapper\.so$' | head -n1) \
    && ln -sf "$nss_wrapper_so" /usr/local/lib/libnss_wrapper.so \
    # Docker Desktop shows the bind-mount root as owned by root, which trips
    # git's ownership check. /workspace is always the caller's own project.
    && git config --system --add safe.directory /workspace

# The runtime UID is the caller's, not 1001, so HOME must be writable by any
# UID (git config, npm and tool caches). Sticky like /tmp.
RUN groupadd --gid 1001 agent \
    && useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash agent \
    && chmod 1777 /home/agent

# Root-owned so the runtime user cannot modify the entrypoint or helpers.
COPY --chmod=0755 bootstrap.sh /usr/local/bin/rapunzel-entrypoint
COPY --chmod=0755 rapunzel-shell /usr/local/bin/rapunzel-shell
# --chmod also applies to the directory COPY creates, so it must stay traversable.
COPY --chmod=0755 setup-identity.sh verify-isolation-inner.sh /usr/local/lib/rapunzel/

ENV HOME=/home/agent

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/rapunzel-entrypoint"]

# ---------------------------------------------------------------------------
# claude: profiles/claude/profile.sh
# ---------------------------------------------------------------------------
FROM base AS claude

ARG CLAUDE_PACKAGE=@anthropic-ai/claude-code
ARG CLAUDE_VERSION=2.1.289

# The package ships a placeholder binary and a postinstall that links in the
# platform's native one from an optional dependency. --ignore-scripts keeps
# every other package's scripts off, so run only this package's script by hand.
RUN --mount=type=cache,target=/root/.npm \
    npm install -g --ignore-scripts "${CLAUDE_PACKAGE}@${CLAUDE_VERSION}" \
    && (cd "$(npm root -g)/${CLAUDE_PACKAGE}" && node install.cjs) \
    && claude --version

# Claude Code writes its config, logins, and sessions here, as the caller's UID.
RUN mkdir -p /home/agent/.claude \
    && chown agent:agent /home/agent/.claude

COPY --chmod=0755 profiles/claude/bootstrap.mjs /usr/local/lib/rapunzel/bootstrap-harness.mjs

ENV RAPUNZEL_STATE_DIR=/home/agent/.claude \
    CLAUDE_CONFIG_DIR=/home/agent/.claude

USER agent
CMD ["claude"]

# ---------------------------------------------------------------------------
# pi: profiles/pi/profile.sh
# ---------------------------------------------------------------------------
FROM base AS pi

ARG PI_PACKAGE=@earendil-works/pi-coding-agent
ARG PI_VERSION=1.0.1

# Separate layer so pi upgrades do not re-run apt and vice versa. Pruning must
# happen in this same layer, or the foreign-platform binaries stay in the image.
RUN --mount=type=bind,source=lib/prune-foreign-platforms.mjs,target=/tmp/prune-foreign-platforms.mjs \
    --mount=type=cache,target=/root/.npm \
    npm install -g --ignore-scripts "${PI_PACKAGE}@${PI_VERSION}" \
    && node /tmp/prune-foreign-platforms.mjs "$(npm root -g)"

# /home/agent/.pi is mode 1777 because extensions write caches such as
# ~/.pi/cache there as the caller's UID. The state directory is the volume mount.
RUN mkdir -p /home/agent/.pi/agent \
    && chown -R agent:agent /home/agent/.pi \
    && chmod 1777 /home/agent/.pi

COPY --chmod=0755 profiles/pi/bootstrap.mjs /usr/local/lib/rapunzel/bootstrap-harness.mjs

ENV RAPUNZEL_STATE_DIR=/home/agent/.pi/agent \
    PI_CODING_AGENT_DIR=/home/agent/.pi/agent

USER agent
CMD ["pi"]
