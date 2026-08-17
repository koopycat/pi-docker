FROM node:24-bookworm-slim

ARG PI_PACKAGE=@earendil-works/pi-coding-agent

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        git \
        ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g --ignore-scripts "${PI_PACKAGE}" \
    && npm cache clean --force

RUN groupadd --gid 1001 pi \
    && useradd --uid 1001 --gid 1001 --create-home --shell /bin/bash pi \
    && mkdir -p /home/pi/.pi/agent \
    && chown -R pi:pi /home/pi/.pi

COPY --chown=pi:pi bootstrap.sh /usr/local/bin/pi-docker-entrypoint
COPY --chown=pi:pi bootstrap-config.mjs /usr/local/lib/pi-docker/bootstrap-config.mjs
COPY --chown=pi:pi verify-isolation-inner.sh /usr/local/lib/pi-docker/verify-isolation-inner.sh
RUN chmod 0755 \
    /usr/local/bin/pi-docker-entrypoint \
    /usr/local/lib/pi-docker/verify-isolation-inner.sh

ENV HOME=/home/pi \
    PI_CODING_AGENT_DIR=/home/pi/.pi/agent

WORKDIR /workspace
USER pi
ENTRYPOINT ["/usr/local/bin/pi-docker-entrypoint"]
CMD ["pi"]
