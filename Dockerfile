FROM node:24-bookworm-slim

ARG PI_PACKAGE=@earendil-works/pi-coding-agent
ARG PI_VERSION=0.87.1

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        git \
        libnss-wrapper \
        ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && nss_wrapper_so=$(dpkg-query -L libnss-wrapper | grep -E '/libnss_wrapper\.so$' | head -n1) \
    && ln -sf "$nss_wrapper_so" /usr/local/lib/libnss_wrapper.so

# Separate layer so pi upgrades do not re-run apt and vice versa.
RUN npm install -g --ignore-scripts "${PI_PACKAGE}@${PI_VERSION}" \
    && npm cache clean --force

RUN groupadd --gid 1001 pi \
    && useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash pi \
    && mkdir -p /home/pi/.pi/agent \
    && chown -R pi:pi /home/pi/.pi

COPY --chown=pi:pi bootstrap.sh /usr/local/bin/pi-docker-entrypoint
COPY --chown=pi:pi pi-docker-shell /usr/local/bin/pi-docker-shell
COPY --chown=pi:pi bootstrap-config.mjs /usr/local/lib/pi-docker/bootstrap-config.mjs
COPY --chown=pi:pi setup-identity.sh /usr/local/lib/pi-docker/setup-identity.sh
COPY --chown=pi:pi verify-isolation-inner.sh /usr/local/lib/pi-docker/verify-isolation-inner.sh
RUN chmod 0755 \
    /usr/local/bin/pi-docker-entrypoint \
    /usr/local/bin/pi-docker-shell \
    /usr/local/lib/pi-docker/verify-isolation-inner.sh

ENV HOME=/home/pi \
    PI_CODING_AGENT_DIR=/home/pi/.pi/agent

WORKDIR /workspace
USER pi
ENTRYPOINT ["/usr/local/bin/pi-docker-entrypoint"]
CMD ["pi"]
