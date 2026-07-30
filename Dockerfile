ARG ATRUST_BASE=hagb/docker-atrust@sha256:60a9114dc31a10b9a809ceb283697748fe325143c78689fc9300522f89af6875
FROM ${ATRUST_BASE}

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends -t bookworm-security \
      chromium imagemagick tesseract-ocr tesseract-ocr-eng xdotool \
    && rm -rf /var/lib/apt/lists/*

COPY container/xdg-open /usr/bin/xdg-open
COPY container/atrust-browser-control /usr/local/bin/atrust-browser-control
COPY container/atrust-login-guard.sh /usr/local/lib/atrust-login-guard.sh
COPY container/entrypoint.sh /usr/local/bin/atrust-surge-entrypoint
COPY container/autologin-extension /opt/atrust-autologin-extension
COPY patches/patch-novnc-ui.awk /tmp/patch-novnc-ui.awk
COPY patches/patch-novnc-entry.awk /tmp/patch-novnc-entry.awk
RUN awk -f /tmp/patch-novnc-ui.awk /usr/local/share/novnc/app/ui.js \
      > /usr/local/share/novnc/app/ui.js.patched \
    && mv /usr/local/share/novnc/app/ui.js.patched /usr/local/share/novnc/app/ui.js \
    && awk -f /tmp/patch-novnc-entry.awk /usr/local/share/novnc/vnc.html \
      > /usr/local/share/novnc/atrust-vnc.html \
    && rm /tmp/patch-novnc-ui.awk /tmp/patch-novnc-entry.awk \
    && chmod 0755 /usr/bin/xdg-open /usr/local/bin/atrust-browser-control \
      /usr/local/bin/atrust-surge-entrypoint \
    && chmod 0644 /usr/local/lib/atrust-login-guard.sh

LABEL org.opencontainers.image.title="aTrust Surge bridge" \
      org.opencontainers.image.description="Pinned aTrust 2.5.16.20 arm64 image with an in-container login browser"

CMD ["/usr/local/bin/atrust-surge-entrypoint"]
