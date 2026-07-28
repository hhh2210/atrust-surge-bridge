ARG ATRUST_BASE=hagb/docker-atrust@sha256:60a9114dc31a10b9a809ceb283697748fe325143c78689fc9300522f89af6875
FROM ${ATRUST_BASE}

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends -t bookworm-security chromium \
    && rm -rf /var/lib/apt/lists/*

COPY container/xdg-open /usr/bin/xdg-open
COPY container/entrypoint.sh /usr/local/bin/atrust-surge-entrypoint
RUN chmod 0755 /usr/bin/xdg-open /usr/local/bin/atrust-surge-entrypoint

LABEL org.opencontainers.image.title="aTrust Surge bridge" \
      org.opencontainers.image.description="Pinned aTrust 2.5.16.20 arm64 image with an in-container login browser"

CMD ["/usr/local/bin/atrust-surge-entrypoint"]
