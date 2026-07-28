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
