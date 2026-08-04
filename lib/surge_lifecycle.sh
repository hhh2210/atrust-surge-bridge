#!/bin/bash

SURGE_CLI="${SURGE_CLI:-/Applications/Surge.app/Contents/Applications/surge-cli}"

bridge_require_callbacks() {
  local callback
  for callback in "$@"; do
    if ! declare -F "${callback}" >/dev/null 2>&1; then
      printf 'Backend contract is missing callback: %s\n' "${callback}" >&2
      return 1
    fi
  done
}

bridge_surge_environment() {
  "${SURGE_CLI}" --raw environment 2>/dev/null
}

bridge_surge_current_selection() {
  local selection
  selection="$(bridge_surge_environment | jq -er \
    --arg group "${SITE_SURGE_GROUP}" \
    '.environment.ProxyGroupSelection[$group] // "UNKNOWN"' 2>/dev/null)" ||
    selection="UNKNOWN"
  printf '%s\n' "${selection}"
}

bridge_surge_select_backend() {
  "${SURGE_CLI}" --raw set \
    "ProxyGroupSelection.${SITE_SURGE_GROUP}=${SITE_SURGE_BACKEND_POLICY}" \
    "AutoPolicyGroupOverride.${SITE_SURGE_GROUP}=<nil>" >/dev/null
}

bridge_surge_select_direct() {
  "${SURGE_CLI}" --raw set \
    "ProxyGroupSelection.${SITE_SURGE_GROUP}=${SITE_SURGE_DIRECT_POLICY}" \
    "AutoPolicyGroupOverride.${SITE_SURGE_GROUP}=<nil>" >/dev/null
}

bridge_surge_restore_direct() {
  local selection
  if ! bridge_surge_select_direct; then
    printf 'Failed to request the Surge %s %s policy.\n' \
      "${SITE_SURGE_GROUP}" "${SITE_SURGE_DIRECT_POLICY}" >&2
    return 1
  fi
  selection="$(bridge_surge_current_selection)"
  if [[ "${selection}" != "${SITE_SURGE_DIRECT_POLICY}" ]]; then
    printf 'Surge %s rollback was not verified; live selection is %s.\n' \
      "${SITE_SURGE_GROUP}" "${selection}" >&2
    return 1
  fi
}

bridge_surge_retest_group() {
  "${SURGE_CLI}" test-group "${SITE_SURGE_GROUP}"
}

bridge_site_http_code() {
  local max_time="${1:-5}"
  env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    -u http_proxy -u https_proxy -u all_proxy \
    /usr/bin/curl --connect-timeout 3 --max-time "${max_time}" --insecure \
      --silent --show-error --output /dev/null --write-out '%{http_code}' \
      "${SITE_HEALTH_URL}"
}

bridge_site_http_probe() {
  local code
  code="$(bridge_site_http_code 12)" || return 1
  printf '%s HTTP %s\n' "${SITE_HEALTH_LABEL}" "${code}"
}

bridge_wait_for_stable_route() {
  local required_seconds="${BRIDGE_ROUTE_STABLE_SECONDS:-30}"
  local timeout_seconds="${BRIDGE_ROUTE_STABLE_TIMEOUT_SECONDS:-75}"
  local interval_seconds="${BRIDGE_ROUTE_STABLE_INTERVAL_SECONDS:-2}"
  local elapsed=0 stable=0 code

  printf 'Verifying %ss of continuous %s route health...\n' \
    "${required_seconds}" "${SITE_BACKEND_LABEL}"
  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    sleep "${interval_seconds}"
    elapsed=$((elapsed + interval_seconds))
    if bridge_backend_ready; then
      stable=$((stable + interval_seconds))
    else
      stable=0
    fi

    if [[ "${stable}" -ge "${required_seconds}" ]]; then
      code="$(bridge_site_http_code 8 2>/dev/null || true)"
      if [[ "${code}" =~ ^[0-9]{3}$ && "${code}" != "000" ]]; then
        return 0
      fi
      stable=0
    fi
  done

  printf '%s route did not remain healthy for %ss within the %ss deadline.\n' \
    "${SITE_BACKEND_LABEL}" "${required_seconds}" "${timeout_seconds}" >&2
  return 1
}

bridge_surge_activate() {
  local selection
  bridge_require_callbacks bridge_backend_ready bridge_backend_wait_ready \
    bridge_backend_prepare_proxy || return 1
  if ! bridge_backend_ready; then
    if ! bridge_backend_wait_ready 0; then
      bridge_surge_restore_direct || true
      return 1
    fi
  fi
  if ! bridge_backend_prepare_proxy; then
    bridge_surge_restore_direct || true
    return 1
  fi
  if ! bridge_surge_select_backend; then
    bridge_surge_restore_direct || true
    printf 'Failed to select the Surge %s policy.\n' \
      "${SITE_SURGE_BACKEND_POLICY}" >&2
    return 1
  fi
  selection="$(bridge_surge_current_selection)"
  if [[ "${selection}" != "${SITE_SURGE_BACKEND_POLICY}" ]]; then
    bridge_surge_restore_direct || true
    printf 'Surge %s activation was not verified; live selection is %s.\n' \
      "${SITE_SURGE_GROUP}" "${selection}" >&2
    return 1
  fi
  if ! bridge_site_http_probe; then
    bridge_surge_restore_direct || true
    printf '%s SOCKS is ready, but the Surge %s route still failed.\n' \
      "${SITE_BACKEND_LABEL}" "${SITE_SURGE_GROUP}" >&2
    return 1
  fi
  printf '%s network is available; completing stability checks...\n' \
    "${SITE_LABEL}"
}

bridge_surge_settle() {
  bridge_require_callbacks bridge_backend_ready bridge_backend_cleanup || return 1
  if ! bridge_wait_for_stable_route; then
    bridge_surge_restore_direct || true
    return 1
  fi
  bridge_backend_cleanup || return 1
  if ! bridge_site_http_probe; then
    if bridge_surge_restore_direct; then
      printf 'The %s route failed after %s; reverted %s to %s.\n' \
        "${SITE_BACKEND_LABEL}" "${BRIDGE_CLEANUP_LABEL:-backend cleanup}" \
        "${SITE_SURGE_GROUP}" \
        "${SITE_SURGE_DIRECT_POLICY}" >&2
    else
      printf 'The %s route failed after %s; %s rollback was not verified.\n' \
        "${SITE_BACKEND_LABEL}" "${BRIDGE_CLEANUP_LABEL:-backend cleanup}" \
        "${SITE_SURGE_DIRECT_POLICY}" >&2
    fi
    return 1
  fi
  printf '%s outside mode is ready; Surge is pinned to %s until %s.\n' \
    "${SITE_LABEL}" "${SITE_BACKEND_LABEL}" \
    "${BRIDGE_SHUTDOWN_HINT:-shutdown}"
}
