#!/bin/bash
set -e

state_dir=/usr/share/sangfor/.aTrust

# Persist databases, device identity, and cookies, but never carry Unix sockets
# or process locks across container recreations.
mkdir -p "${state_dir}/var/run" "${state_dir}/tmp"
find "${state_dir}" -maxdepth 1 -type s -delete
find "${state_dir}" -maxdepth 1 -type f -name 'sapp-*-lockfile' -delete
find "${state_dir}" -maxdepth 1 -type f -name 'Global*Lock*' -delete
rm -rf "${state_dir}/var/run"/* "${state_dir}/tmp"/*
chmod 0777 "${state_dir}" "${state_dir}/var" "${state_dir}/var/run" "${state_dir}/tmp"

# If the aTrust tunnel disappears, never let the verified HITSZ private ranges
# escape through a non-tunnel path and re-enter Surge on the host. Do not block
# 198.18/15 here: aTrust uses its FakeIP transport during pre-tunnel web login.
# Traffic routed through utun7 remains unaffected while online.
eval "$(detect-iptables.sh)"
private_cidr=10.248.0.0/15
iptables -w 5 -C OUTPUT -d "${private_cidr}" '!' -o utun7 -j REJECT \
  --reject-with icmp-net-unreachable 2>/dev/null ||
  iptables -w 5 -I OUTPUT 1 -d "${private_cidr}" '!' -o utun7 -j REJECT \
    --reject-with icmp-net-unreachable

# aTrust invokes xdg-open when a session expires. A trusted terminal can renew
# through that browser without credentials; close Chromium after the restored
# tunnel route stays stable so a daily renewal cannot leak VM memory.
(
  stable_seconds=0
  offline_seconds=0
  offline_browser_seconds=0
  offline_ttl_seconds="${ATRUST_BROWSER_OFFLINE_TTL_SECONDS:-600}"
  retry_backoff_seconds="${ATRUST_BROWSER_RETRY_BACKOFF_SECONDS:-300}"
  [[ "${offline_ttl_seconds}" =~ ^[0-9]+$ ]] || offline_ttl_seconds=600
  [[ "${retry_backoff_seconds}" =~ ^[0-9]+$ ]] || retry_backoff_seconds=300
  [[ "${offline_ttl_seconds}" -ge 60 ]] || offline_ttl_seconds=600
  while sleep 10; do
    if ip -4 addr show dev utun7 2>/dev/null | grep -q 'inet 10\.251\.' &&
      ip -4 route get "${HITSZ_JW_IP:-10.248.17.16}" 2>/dev/null | grep -q 'dev utun7'; then
      if ! /usr/local/bin/atrust-browser-control unlatch; then
        printf '[%s] WARNING: could not clear browser manual-login latch\n' \
          "$(date -Iseconds)" >>/tmp/atrust-browser-reaper.log
        continue
      fi
      offline_seconds=0
      offline_browser_seconds=0
      if /usr/local/bin/atrust-browser-control running >/dev/null 2>&1; then
        stable_seconds=$((stable_seconds + 10))
      else
        stable_seconds=0
      fi
    else
      stable_seconds=0
      if /usr/local/bin/atrust-browser-control running >/dev/null 2>&1; then
        offline_seconds=0
        offline_browser_seconds=$((offline_browser_seconds + 10))
      else
        if [[ "${offline_browser_seconds}" -gt 0 ]]; then
          if ! /usr/local/bin/atrust-browser-control latch; then
            printf '[%s] WARNING: could not set browser manual-login latch\n' \
              "$(date -Iseconds)" >>/tmp/atrust-browser-reaper.log
            offline_seconds=0
            continue
          fi
        fi
        offline_browser_seconds=0
        if /usr/local/bin/atrust-browser-control latched; then
          offline_seconds=0
        else
          offline_seconds=$((offline_seconds + 10))
        fi
      fi
    fi

    if [[ "${stable_seconds}" -ge 30 ]]; then
      if /usr/local/bin/atrust-browser-control stop; then
        printf '[%s] trusted-terminal renewal complete; Chromium stopped cleanly\n' \
          "$(date -Iseconds)" >>/tmp/atrust-browser-reaper.log
      else
        printf '[%s] WARNING: Chromium did not stop cleanly\n' \
          "$(date -Iseconds)" >>/tmp/atrust-browser-reaper.log
      fi
      stable_seconds=0
    fi

    if [[ "${offline_browser_seconds}" -ge "${offline_ttl_seconds}" ]]; then
      if /usr/local/bin/atrust-browser-control stop-and-latch; then
        printf '[%s] offline login TTL reached; Chromium stopped; manual login required\n' \
          "$(date -Iseconds)" \
          >>/tmp/atrust-browser-reaper.log
        offline_seconds=0
        offline_browser_seconds=0
      else
        printf '[%s] WARNING: offline Chromium did not stop cleanly\n' \
          "$(date -Iseconds)" >>/tmp/atrust-browser-reaper.log
        offline_browser_seconds=$((offline_ttl_seconds - 60))
      fi
    fi

    if [[ "${offline_seconds}" -ge 20 ]] &&
      ! /usr/local/bin/atrust-browser-control latched; then
      if DISPLAY=:1 /usr/local/bin/atrust-browser-control trigger-auto \
        >>/tmp/atrust-session-keeper.log 2>&1; then
        offline_seconds=0
      else
        offline_seconds=$((-retry_backoff_seconds))
      fi
    fi
  done
) &

# aTrustTray creates this file as root while aTrustCore runs as `sangfor`.
# Newer 2.5.16 clients need both processes to update it during web login.
(
  for _ in {1..600}; do
    if [[ -e /tmp/aTrustShell.conf ]]; then
      chmod a+rw /tmp/aTrustShell.conf
      exit 0
    fi
    sleep 0.1
  done
) &

exec /usr/local/bin/start.sh
