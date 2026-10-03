# syntax=docker/dockerfile:1
FROM node:24-bookworm-slim

ARG PI_PACKAGE=@earendil-works/pi-coding-agent
ARG PI_VERSION=1.0.1

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

# Separate layer so pi upgrades do not re-run apt and vice versa. Pruning must
# happen in this same layer, or the foreign-platform binaries stay in the image.
RUN --mount=type=bind,source=lib/prune-foreign-platforms.mjs,target=/tmp/prune-foreign-platforms.mjs \
    --mount=type=cache,target=/root/.npm \
    npm install -g --ignore-scripts "${PI_PACKAGE}@${PI_VERSION}" \
    && node /tmp/prune-foreign-platforms.mjs "$(npm root -g)"

# The runtime UID is the caller's, not 1001, so HOME must be writable by any
# UID (git config, npm and tool caches). Sticky like /tmp.
RUN groupadd --gid 1001 pi \
    && useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash pi \
    && mkdir -p /home/pi/.pi/agent \
    && chown -R pi:pi /home/pi/.pi \
    && chmod 1777 /home/pi /home/pi/.pi

# Root-owned so the runtime user cannot modify the entrypoint or helpers.
COPY --chmod=0755 bootstrap.sh /usr/local/bin/pi-docker-entrypoint
COPY --chmod=0755 pi-docker-shell /usr/local/bin/pi-docker-shell
# --chmod also applies to the directory COPY creates, so it must stay traversable.
COPY --chmod=0755 bootstrap-config.mjs setup-identity.sh verify-isolation-inner.sh /usr/local/lib/pi-docker/

ENV HOME=/home/pi \
    PI_CODING_AGENT_DIR=/home/pi/.pi/agent

WORKDIR /workspace
USER pi
ENTRYPOINT ["/usr/local/bin/pi-docker-entrypoint"]
CMD ["pi"]
