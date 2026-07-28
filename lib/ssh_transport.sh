#!/bin/bash

# Select a usable path for HITSZ SSH without assuming the current network.
# A TCP handshake alone is insufficient: Surge may accept the connection even
# when the selected route never reaches an SSH server. Require a host key reply.

ssh_transport_log() {
  [[ "${HITSZ_SSH_DEBUG:-0}" == "1" ]] || return 0
  printf 'hitsz-ssh: %s\n' "$*" >&2
}

ssh_direct_ready() {
  local host="$1" port="$2" timeout="$3"
  /usr/bin/ssh-keyscan -T "${timeout}" -p "${port}" "${host}" 2>/dev/null |
    /usr/bin/grep -qE '^[^#].*[[:space:]](ssh-(ed25519|rsa)|ecdsa-sha2-)'
}

ssh_socks_ready() {
  local socks_host="$1" socks_port="$2"
  /usr/bin/nc -z -G 1 -w 1 "${socks_host}" "${socks_port}" >/dev/null 2>&1
}

ssh_transport_main() {
  if [[ "$#" -ne 2 ]]; then
    printf 'usage: ssh-connect <host> <port>\n' >&2
    return 64
  fi

  local host="$1" port="$2"
  local timeout="${HITSZ_DIRECT_PROBE_TIMEOUT:-2}"
  local socks_host="${ATRUST_SOCKS_HOST:-127.0.0.1}"
  local socks_port="${ATRUST_SOCKS_PORT:-1080}"

  if ssh_direct_ready "${host}" "${port}" "${timeout}"; then
    ssh_transport_log "route=direct target=${host}:${port}"
    exec /usr/bin/nc "${host}" "${port}"
  fi

  if ssh_socks_ready "${socks_host}" "${socks_port}"; then
    ssh_transport_log "route=atrust-socks target=${host}:${port}"
    exec /usr/bin/nc -x "${socks_host}:${socks_port}" -X 5 "${host}" "${port}"
  fi

  printf 'hitsz-ssh: direct SSH is unavailable and aTrust SOCKS %s:%s is offline\n' \
    "${socks_host}" "${socks_port}" >&2
  return 69
}
