#!/bin/bash

SURGE_CLI="${SURGE_CLI:-/Applications/Surge.app/Contents/Applications/surge-cli}"
HITSZ_GROUP="HITSZ"
HITSZ_JW_HOST="${HITSZ_JW_HOST:-jw.hitsz.edu.cn}"
HITSZ_JW_URL="${HITSZ_JW_URL:-https://${HITSZ_JW_HOST}/}"
HITSZ_JW_REAL_IP="${HITSZ_JW_IP:-10.248.17.16}"

hitsz_vpn_ready() {
  # shellcheck disable=SC2016 # $1 is expanded by the in-container shell.
  container_running &&
    docker_ctx exec "${CONTAINER_NAME}" sh -c \
      'ip -4 addr show dev utun7 2>/dev/null | grep -q "inet 10\.251\." &&
       ip -4 route get "$1" 2>/dev/null | grep -q "dev utun7"' \
      sh "${HITSZ_JW_REAL_IP}"
}

hitsz_jw_via_socks() {
  local max_time="${1:-10}"
  /usr/bin/curl --socks5-hostname 127.0.0.1:1080 \
    --connect-timeout 4 --max-time "${max_time}" --insecure --silent --show-error \
    --output /dev/null "${HITSZ_JW_URL}"
}

hitsz_jw_via_real_ip() {
  local max_time="${1:-10}"
  /usr/bin/curl --socks5 127.0.0.1:1080 \
    --resolve "jw.hitsz.edu.cn:443:${HITSZ_JW_REAL_IP}" \
    --connect-timeout 4 --max-time "${max_time}" --insecure --silent --show-error \
    --output /dev/null "${HITSZ_JW_URL}"
}

hitsz_repair_dante_dns() {
  local max_time="${1:-10}"
  hitsz_jw_via_socks "${max_time}" && return 0
  hitsz_jw_via_real_ip "${max_time}" || return 1
  printf 'Refreshing Dante after an aTrust FakeDNS mapping change...\n'
  docker_ctx exec "${CONTAINER_NAME}" sh -c 'pkill -HUP danted'
  sleep 1
  hitsz_jw_via_socks "${max_time}"
}

hitsz_wait_for_socks_path() {
  local timeout_seconds="${HITSZ_ROUTE_ACTIVATION_TIMEOUT_SECONDS:-30}"
  local probe_seconds="${HITSZ_ROUTE_ACTIVATION_PROBE_SECONDS:-4}"
  local interval_seconds="${HITSZ_ROUTE_ACTIVATION_INTERVAL_SECONDS:-2}"
  local deadline remaining attempt_probe sleep_seconds

  [[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || timeout_seconds=30
  [[ "${probe_seconds}" =~ ^[1-9][0-9]*$ ]] || probe_seconds=4
  [[ "${interval_seconds}" =~ ^[1-9][0-9]*$ ]] || interval_seconds=2
  deadline=$((SECONDS + timeout_seconds))

  while [[ "${SECONDS}" -lt "${deadline}" ]]; do
    remaining=$((deadline - SECONDS))
    # One repair attempt can perform up to three curls plus a one-second HUP pause.
    [[ "${remaining}" -ge 4 ]] || break
    attempt_probe=$(((remaining - 1) / 3))
    [[ "${attempt_probe}" -le "${probe_seconds}" ]] || attempt_probe="${probe_seconds}"
    if hitsz_repair_dante_dns "${attempt_probe}"; then
      return 0
    fi
    remaining=$((deadline - SECONDS))
    [[ "${remaining}" -gt 0 ]] || break
    sleep_seconds="${interval_seconds}"
    [[ "${sleep_seconds}" -le "${remaining}" ]] || sleep_seconds="${remaining}"
    sleep "${sleep_seconds}"
  done
  return 1
}

hitsz_wait_until_ready() {
  local auto_open="${1:-1}"
  local max_seconds="${HITSZ_LOGIN_WAIT_SECONDS:-180}"
  local grace_seconds="${HITSZ_TRUSTED_LOGIN_GRACE_SECONDS:-30}"
  local attempts=$((max_seconds / 2))
  local open_attempt=$(((grace_seconds + 1) / 2))
  local opened=0 i

  [[ "${open_attempt}" -ge 1 ]] || open_attempt=1
  if [[ "${auto_open}" -eq 1 ]]; then
    printf 'Waiting up to %ss for trusted-terminal renewal before showing noVNC...\n' \
      "${grace_seconds}"
  fi

  for ((i = 1; i <= attempts; i++)); do
    if hitsz_vpn_ready; then
      return 0
    fi

    if [[ "${auto_open}" -eq 1 && "${i}" -eq "${open_attempt}" && "${opened}" -eq 0 ]]; then
      printf 'Trusted-terminal renewal needs attention; opening loopback-only noVNC...\n'
      hitsz_open_login
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

hitsz_set_atrust_route() {
  "${SURGE_CLI}" --raw set \
    "ProxyGroupSelection.${HITSZ_GROUP}=HITSZ-aTrust" \
    "AutoPolicyGroupOverride.${HITSZ_GROUP}=<nil>" >/dev/null
}

hitsz_set_direct_route() {
  "${SURGE_CLI}" --raw set \
    "ProxyGroupSelection.${HITSZ_GROUP}=DIRECT" \
    "AutoPolicyGroupOverride.${HITSZ_GROUP}=<nil>" >/dev/null
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

hitsz_wait_for_stable_route() {
  local required_seconds="${HITSZ_ROUTE_STABLE_SECONDS:-30}"
  local timeout_seconds="${HITSZ_ROUTE_STABLE_TIMEOUT_SECONDS:-75}"
  local interval_seconds="${HITSZ_ROUTE_STABLE_INTERVAL_SECONDS:-2}"
  local elapsed=0 stable=0 code

  printf 'Verifying %ss of continuous aTrust route health...\n' \
    "${required_seconds}"
  while [[ "${elapsed}" -lt "${timeout_seconds}" ]]; do
    sleep "${interval_seconds}"
    elapsed=$((elapsed + interval_seconds))
    if hitsz_vpn_ready; then
      stable=$((stable + interval_seconds))
    else
      stable=0
    fi

    if [[ "${stable}" -ge "${required_seconds}" ]]; then
      code="$(hitsz_normal_jw_code 8 2>/dev/null || true)"
      if [[ "${code}" =~ ^[0-9]{3}$ && "${code}" != "000" ]]; then
        return 0
      fi
      stable=0
    fi
  done

  printf 'aTrust route did not remain healthy for %ss within the %ss deadline.\n' \
    "${required_seconds}" "${timeout_seconds}" >&2
  return 1
}

hitsz_surge_environment() {
  "${SURGE_CLI}" --raw environment 2>/dev/null
}

hitsz_current_selection() {
  local selection
  selection="$(hitsz_surge_environment | jq -er \
    --arg group "${HITSZ_GROUP}" \
    '.environment.ProxyGroupSelection[$group] // "UNKNOWN"' 2>/dev/null)" || selection="UNKNOWN"
  printf '%s\n' "${selection}"
}

hitsz_restore_direct_route() {
  local selection
  if ! hitsz_set_direct_route; then
    printf 'Failed to request the Surge HITSZ DIRECT policy.\n' >&2
    return 1
  fi
  selection="$(hitsz_current_selection)"
  if [[ "${selection}" != "DIRECT" ]]; then
    printf 'Surge HITSZ rollback was not verified; live selection is %s.\n' \
      "${selection}" >&2
    return 1
  fi
}

hitsz_mode_connect() {
  ensure_bridge_preflight || return 1
  if atrust_bridge_running; then
    printf 'The isolated aTrust container is already running; reusing it.\n'
  else
    hitsz_mode_start || return 1
  fi
  if hitsz_vpn_ready; then
    return 0
  fi
  printf 'Triggering the aTrust client login flow...\n'
  trigger_atrust_login ||
    printf 'WARNING: could not trigger aTrust Log In automatically.\n' >&2
  hitsz_wait_until_ready 1
}

hitsz_mode_start() {
  "${ROOT_DIR}/bin/up" --no-open
}

hitsz_mode_activate_route() {
  if ! hitsz_vpn_ready; then
    if ! hitsz_wait_until_ready 0; then
      hitsz_restore_direct_route || true
      return 1
    fi
  fi
  if ! hitsz_wait_for_socks_path; then
    hitsz_restore_direct_route || true
    printf 'The aTrust tunnel is ready, but the JW SOCKS path did not become usable.\n' >&2
    return 1
  fi
  if ! hitsz_set_atrust_route; then
    hitsz_restore_direct_route || true
    printf 'Failed to select the Surge HITSZ-aTrust policy.\n' >&2
    return 1
  fi
  if ! hitsz_normal_jw_probe; then
    hitsz_restore_direct_route || true
    printf 'aTrust SOCKS is ready, but the Surge HITSZ route still failed.\n' >&2
    return 1
  fi
  printf 'HITSZ network is available; completing stability checks...\n'
}

hitsz_mode_settle() {
  if ! hitsz_wait_for_stable_route; then
    hitsz_restore_direct_route || true
    return 1
  fi
  if ! stop_login_browser; then
    printf 'WARNING: failed to stop login Chromium; run bin/trim-browser.\n' >&2
    return 1
  fi
  printf 'Login Chromium stopped to release VM memory.\n'
  if ! hitsz_normal_jw_probe; then
    if hitsz_restore_direct_route; then
      printf 'The aTrust route failed after browser shutdown; reverted HITSZ to DIRECT.\n' >&2
    else
      printf 'The aTrust route failed after browser shutdown; DIRECT rollback was not verified.\n' >&2
    fi
    return 1
  fi
  printf 'HITSZ outside mode is ready; Surge is pinned to aTrust until hitsz down.\n'
}

hitsz_mode_finish() {
  hitsz_mode_activate_route || return 1
  hitsz_mode_settle
}

hitsz_mode_up() {
  hitsz_mode_connect || return 1
  hitsz_mode_finish
}

hitsz_open_login() {
  nc -z -w 1 127.0.0.1 6080 >/dev/null 2>&1 || {
    printf 'noVNC is offline; run hitsz up first.\n' >&2
    return 1
  }
  if ! hitsz_vpn_ready && ! login_browser_running; then
    trigger_atrust_login ||
      printf 'WARNING: could not reopen the guarded aTrust login flow.\n' >&2
  fi
  open "$(novnc_autologin_url)"
}

hitsz_mode_down() {
  if ! hitsz_restore_direct_route; then
    printf 'Refusing to stop the bridge because HITSZ=DIRECT was not verified.\n' >&2
    return 1
  fi
  "${ROOT_DIR}/bin/down"
  hitsz_retest_group || true
  if hitsz_normal_jw_probe; then
    printf 'HITSZ direct access is available on the current network.\n'
  else
    printf 'Docker is off; JW is not directly available on this network.\n'
  fi
}
