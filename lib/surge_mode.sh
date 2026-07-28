#!/bin/bash

# shellcheck disable=SC2034 # status globals are consumed by sourced lib/ui.sh

SURGE_CLI="/Applications/Surge.app/Contents/Applications/surge-cli"
HITSZ_GROUP="HITSZ"
HITSZ_JW_HOST="${HITSZ_JW_HOST:-jw.hitsz.edu.cn}"
HITSZ_JW_URL="${HITSZ_JW_URL:-https://${HITSZ_JW_HOST}/}"
HITSZ_JW_REAL_IP="${HITSZ_JW_IP:-10.248.17.16}"

hitsz_vpn_ready() {
  colima_running && container_running &&
    docker_ctx exec "${CONTAINER_NAME}" sh -c \
      'ip -4 addr show dev utun7 2>/dev/null | grep -q "inet 10\.251\."'
}

hitsz_jw_via_socks() {
  /usr/bin/curl --socks5-hostname 127.0.0.1:1080 \
    --connect-timeout 4 --max-time 10 --insecure --silent --show-error \
    --output /dev/null "${HITSZ_JW_URL}"
}

hitsz_jw_via_real_ip() {
  /usr/bin/curl --socks5 127.0.0.1:1080 \
    --resolve "jw.hitsz.edu.cn:443:${HITSZ_JW_REAL_IP}" \
    --connect-timeout 4 --max-time 10 --insecure --silent --show-error \
    --output /dev/null "${HITSZ_JW_URL}"
}

hitsz_repair_dante_dns() {
  hitsz_jw_via_socks && return 0
  hitsz_jw_via_real_ip || return 1
  printf 'Refreshing Dante after an aTrust FakeDNS mapping change...\n'
  docker_ctx exec "${CONTAINER_NAME}" sh -c 'pkill -HUP danted'
  sleep 1
  hitsz_jw_via_socks
}

hitsz_wait_until_ready() {
  local max_seconds="${HITSZ_LOGIN_WAIT_SECONDS:-180}"
  local attempts=$((max_seconds / 2))
  local opened=0 i

  for ((i = 1; i <= attempts; i++)); do
    if hitsz_vpn_ready; then
      hitsz_repair_dante_dns && return 0
      printf 'aTrust tunnel is up, but JW still fails through SOCKS.\n' >&2
      return 1
    fi

    if [[ "${i}" -eq 5 && "${opened}" -eq 0 ]]; then
      printf 'aTrust needs login; opening loopback-only noVNC...\n'
      open 'http://127.0.0.1:6080/vnc.html?autoconnect=true&resize=scale'
      opened=1
    fi
    sleep 2
  done

  printf 'Timed out waiting for the isolated aTrust tunnel.\n' >&2
  return 1
}

hitsz_retest_group() {
  "${SURGE_CLI}" test-group "${HITSZ_GROUP}"
}

hitsz_normal_jw_probe() {
  local code
  code="$(hitsz_normal_jw_code 12)" || return 1
  printf 'JW HTTP %s\n' "${code}"
}

hitsz_normal_jw_code() {
  local max_time="${1:-5}"
  env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u http_proxy -u https_proxy -u all_proxy \
    /usr/bin/curl --connect-timeout 3 --max-time "${max_time}" --insecure \
      --silent --show-error --output /dev/null --write-out '%{http_code}' \
      "${HITSZ_JW_URL}"
}

hitsz_recent_jw_policy() {
  "${SURGE_CLI}" --raw dump request 2>/dev/null | jq -r '
    [.. | objects
      | select((((.hostname? // .host? // .remoteHost? // "") | tostring)
        | test("jw\\.hitsz\\.edu\\.cn"; "i")))
      | (.policyName? // .policy? // .finalPolicy? // empty)]
    | last // "UNKNOWN"
  '
}

hitsz_status_jw_code() {
  local code attempt
  for attempt in 1 2 3; do
    code="$(hitsz_normal_jw_code 5 2>/dev/null || true)"
    if [[ "${code}" =~ ^[0-9]{3}$ && "${code}" != "000" ]]; then
      printf '%s\n' "${code}"
      return 0
    fi
    sleep 0.2
  done
  printf '000\n'
}

hitsz_collect_status() {
  HITSZ_STATUS_JW_CODE="$(hitsz_status_jw_code)"
  HITSZ_STATUS_POLICY="$(hitsz_recent_jw_policy 2>/dev/null || printf 'UNKNOWN')"

  HITSZ_STATUS_DOCKER="OFF"
  HITSZ_STATUS_USAGE=""
  HITSZ_STATUS_VPN="DISCONNECTED"
  HITSZ_STATUS_SOCKS="CLOSED"

  if colima_running; then
    HITSZ_STATUS_DOCKER="ON"
    wait_for_docker
    if container_running; then
      HITSZ_STATUS_USAGE="$(docker_ctx stats --no-stream --format '{{.CPUPerc}} · {{.MemUsage}}' "${CONTAINER_NAME}")"
      hitsz_vpn_ready && HITSZ_STATUS_VPN="CONNECTED"
    fi
  fi
  nc -z -w 1 127.0.0.1 1080 >/dev/null 2>&1 && HITSZ_STATUS_SOCKS="OPEN"

  if [[ "${HITSZ_STATUS_JW_CODE}" != "000" && "${HITSZ_STATUS_POLICY}" == "DIRECT" ]]; then
    HITSZ_STATUS_MODE="校园直连"
  elif [[ "${HITSZ_STATUS_JW_CODE}" != "000" && "${HITSZ_STATUS_POLICY}" == "HITSZ-aTrust" ]]; then
    HITSZ_STATUS_MODE="校外 aTrust"
  else
    HITSZ_STATUS_MODE="不可用"
  fi
}

hitsz_mode_up() {
  "${ROOT_DIR}/bin/up" --no-open
  hitsz_wait_until_ready
  hitsz_retest_group
  hitsz_normal_jw_probe
  printf 'HITSZ outside mode is ready; Surge fallback may use aTrust.\n'
}

hitsz_mode_down() {
  "${ROOT_DIR}/bin/down"
  hitsz_retest_group || true
  if hitsz_normal_jw_probe; then
    printf 'HITSZ direct access is available on the current network.\n'
  else
    printf 'Docker is off; JW is not directly available on this network.\n'
  fi
}

hitsz_mode_status() {
  hitsz_collect_status
  if declare -F hitsz_ui_render_status >/dev/null 2>&1; then
    hitsz_ui_render_status
  else
    printf 'Mode: %s\nJW: HTTP %s via %s\nDocker: %s\n' \
      "${HITSZ_STATUS_MODE}" "${HITSZ_STATUS_JW_CODE}" \
      "${HITSZ_STATUS_POLICY}" "${HITSZ_STATUS_DOCKER}"
  fi
}
