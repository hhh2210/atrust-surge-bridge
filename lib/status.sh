#!/bin/bash

# shellcheck disable=SC2034 # Status globals are consumed by sourced lib/ui.sh.

hitsz_status_jw_code() {
  local code
  code="$(hitsz_normal_jw_code "${HITSZ_STATUS_TIMEOUT:-1}" 2>/dev/null || true)"
  if [[ "${code}" =~ ^[0-9]{3}$ && "${code}" != "000" ]]; then
    printf '%s\n' "${code}"
    return 0
  fi
  printf '000\n'
}

hitsz_collect_status() {
  HITSZ_STATUS_DOCKER="OFF"
  HITSZ_STATUS_USAGE=""
  HITSZ_STATUS_VPN="DISCONNECTED"
  HITSZ_STATUS_SOCKS="CLOSED"
  HITSZ_STATUS_JW_CODE="SKIPPED"
  HITSZ_STATUS_POLICY="$(hitsz_current_selection)"

  if docker_ctx info >/dev/null 2>&1; then
    HITSZ_STATUS_DOCKER="IDLE"
    if container_running; then
      HITSZ_STATUS_DOCKER="ON"
      HITSZ_STATUS_USAGE="$(docker_ctx stats --no-stream \
        --format '{{.CPUPerc}} · {{.MemUsage}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
      hitsz_vpn_ready && HITSZ_STATUS_VPN="CONNECTED"
    fi
  fi
  nc -z -w 1 "${SITE_SOCKS_HOST}" "${SITE_SOCKS_PORT}" >/dev/null 2>&1 &&
    HITSZ_STATUS_SOCKS="OPEN"

  if [[ "${HITSZ_STATUS_POLICY}" == "${SITE_SURGE_DIRECT_POLICY}" ||
    ("${HITSZ_STATUS_POLICY}" == "${SITE_SURGE_BACKEND_POLICY}" &&
      "${HITSZ_STATUS_VPN}" == "CONNECTED") ]]; then
    HITSZ_STATUS_JW_CODE="$(hitsz_status_jw_code)"
  fi

  if [[ "${HITSZ_STATUS_JW_CODE}" =~ ^[0-9]{3}$ && "${HITSZ_STATUS_JW_CODE}" != "000" && "${HITSZ_STATUS_POLICY}" == "${SITE_SURGE_DIRECT_POLICY}" ]]; then
    HITSZ_STATUS_MODE="校园直连"
  elif [[ "${HITSZ_STATUS_JW_CODE}" =~ ^[0-9]{3}$ && "${HITSZ_STATUS_JW_CODE}" != "000" && "${HITSZ_STATUS_POLICY}" == "${SITE_SURGE_BACKEND_POLICY}" ]]; then
    HITSZ_STATUS_MODE="校外 aTrust"
  elif [[ "${HITSZ_STATUS_POLICY}" == "${SITE_SURGE_BACKEND_POLICY}" && "${HITSZ_STATUS_DOCKER}" == "ON" && "${HITSZ_STATUS_VPN}" == "DISCONNECTED" ]]; then
    if login_browser_running 1; then
      HITSZ_STATUS_MODE="登录恢复中"
    elif manual_login_latched 1; then
      HITSZ_STATUS_MODE="需手动登录"
    else
      HITSZ_STATUS_MODE="待自动恢复"
    fi
  else
    HITSZ_STATUS_MODE="不可用"
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
