#!/bin/bash

BRIDGE_ROUTE_STABLE_SECONDS="${HITSZ_ROUTE_STABLE_SECONDS:-${BRIDGE_ROUTE_STABLE_SECONDS:-30}}"
BRIDGE_ROUTE_STABLE_TIMEOUT_SECONDS="${HITSZ_ROUTE_STABLE_TIMEOUT_SECONDS:-${BRIDGE_ROUTE_STABLE_TIMEOUT_SECONDS:-75}}"
BRIDGE_ROUTE_STABLE_INTERVAL_SECONDS="${HITSZ_ROUTE_STABLE_INTERVAL_SECONDS:-${BRIDGE_ROUTE_STABLE_INTERVAL_SECONDS:-2}}"
BRIDGE_CLEANUP_LABEL="${BRIDGE_CLEANUP_LABEL:-browser shutdown}"
BRIDGE_SHUTDOWN_HINT="${BRIDGE_SHUTDOWN_HINT:-hitsz down}"

# shellcheck source=surge_lifecycle.sh
source "${ROOT_DIR}/lib/surge_lifecycle.sh"

hitsz_vpn_ready() {
  # shellcheck disable=SC2016 # $1 is expanded by the in-container shell.
  container_running &&
    docker_ctx exec "${CONTAINER_NAME}" sh -c \
      'ip -4 addr show dev utun7 2>/dev/null | grep -q "inet 10\.251\." &&
       ip -4 route get "$1" 2>/dev/null | grep -q "dev utun7"' \
      sh "${SITE_HEALTH_REAL_IP}"
}

hitsz_jw_via_socks() {
  local max_time="${1:-10}"
  /usr/bin/curl --socks5-hostname "${SITE_SOCKS_HOST}:${SITE_SOCKS_PORT}" \
    --connect-timeout 4 --max-time "${max_time}" --insecure --silent --show-error \
    --output /dev/null "${SITE_HEALTH_URL}"
}

hitsz_jw_via_real_ip() {
  local max_time="${1:-10}"
  /usr/bin/curl --socks5 "${SITE_SOCKS_HOST}:${SITE_SOCKS_PORT}" \
    --resolve "${SITE_HEALTH_HOST}:443:${SITE_HEALTH_REAL_IP}" \
    --connect-timeout 4 --max-time "${max_time}" --insecure --silent --show-error \
    --output /dev/null "${SITE_HEALTH_URL}"
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
  local reveal_checks="${HITSZ_CAS_FORM_REVEAL_CHECKS:-2}"
  local attempts=$((max_seconds / 2))
  local open_attempt=$(((grace_seconds + 1) / 2))
  local opened=0 form_checks=0 i

  [[ "${open_attempt}" -ge 1 ]] || open_attempt=1
  [[ "${reveal_checks}" =~ ^[1-9][0-9]*$ ]] || reveal_checks=2
  if [[ "${auto_open}" -eq 1 ]]; then
    printf 'Waiting for trusted-terminal renewal; noVNC opens once the CAS form needs input (at most %ss)...\n' \
      "${grace_seconds}"
  fi

  for ((i = 1; i <= attempts; i++)); do
    if hitsz_vpn_ready; then
      return 0
    fi

    if [[ "${auto_open}" -eq 1 && "${opened}" -eq 0 ]]; then
      if cas_login_form_visible; then
        form_checks=$((form_checks + 1))
      else
        form_checks=0
      fi
      if [[ "${form_checks}" -ge "${reveal_checks}" ]]; then
        printf 'The CAS login form is waiting for input; opening loopback-only noVNC...\n'
        hitsz_open_login
        opened=1
      elif [[ "${i}" -ge "${open_attempt}" ]]; then
        printf 'Trusted-terminal renewal needs attention; opening loopback-only noVNC...\n'
        hitsz_open_login
        opened=1
      fi
    fi
    sleep 2
  done

  printf 'Timed out waiting for the isolated aTrust tunnel.\n' >&2
  return 1
}

hitsz_retest_group() { bridge_surge_retest_group; }
hitsz_set_atrust_route() { bridge_surge_select_backend; }
hitsz_set_direct_route() { bridge_surge_select_direct; }
hitsz_normal_jw_probe() { bridge_site_http_probe; }
hitsz_normal_jw_code() { bridge_site_http_code "$@"; }
hitsz_wait_for_stable_route() { bridge_wait_for_stable_route; }
hitsz_surge_environment() { bridge_surge_environment; }
hitsz_current_selection() { bridge_surge_current_selection; }
hitsz_restore_direct_route() { bridge_surge_restore_direct; }

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

bridge_backend_ready() {
  hitsz_vpn_ready
}

bridge_backend_wait_ready() {
  hitsz_wait_until_ready "$@"
}

bridge_backend_prepare_proxy() {
  if hitsz_wait_for_socks_path; then
    return 0
  fi
  printf 'The %s tunnel is ready, but the %s SOCKS path did not become usable.\n' \
    "${SITE_BACKEND_LABEL}" "${SITE_HEALTH_LABEL}" >&2
  return 1
}

bridge_backend_cleanup() {
  if ! stop_login_browser; then
    printf 'WARNING: failed to stop login Chromium; run bin/trim-browser.\n' >&2
    return 1
  fi
  printf 'Login Chromium stopped to release VM memory.\n'
}

# A newer activation supersedes any background settle before touching Surge.
# The interactive UI claims in its own process (activation runs in a gum child)
# and passes BRIDGE_SETTLE_TOKEN down; otherwise claim here.
hitsz_mode_activate_route() {
  if [[ -z "${BRIDGE_SETTLE_TOKEN:-}" ]]; then
    bridge_settle_claim || return 1
  fi
  bridge_surge_activate "${BRIDGE_SETTLE_TOKEN}" || return 1
  if ! bridge_settle_exclusive "${BRIDGE_SETTLE_TOKEN}" hitsz_printer_start; then
    printf 'WARNING: printer forward failed; VPN remains available. Run hitsz printer status.\n' >&2
  fi
}
# Foreground settles (plain mode, __core_settle, HITSZ_SETTLE_FOREGROUND=1)
# carry the claimed token too, so a newer activation still supersedes them.
hitsz_mode_settle() { bridge_surge_settle "${BRIDGE_SETTLE_TOKEN:-}"; }
hitsz_mode_settle_bg() { bridge_settle_run_bg "$@"; }

hitsz_settle_dispatch() {
  bridge_settle_dispatch "${ROOT_DIR}/bin/hitsz"
}

hitsz_mode_finish() {
  hitsz_mode_activate_route || return 1
  hitsz_mode_settle
}

hitsz_mode_finish_dispatch() {
  hitsz_mode_activate_route || return 1
  hitsz_settle_dispatch
}

hitsz_mode_up() {
  # Claim before the login flow can open a browser an old settle might close.
  if [[ -z "${BRIDGE_SETTLE_TOKEN:-}" ]]; then
    bridge_settle_claim || return 1
  fi
  if ! hitsz_mode_connect; then
    hitsz_mode_connect_failed
    return 1
  fi
  hitsz_mode_finish_dispatch
}

# The claim stopped any pending settle, which owned the DIRECT rollback for an
# unhealthy tunnel. A failed connect must not leave Surge on a backend nobody
# monitors, so fall back to DIRECT under this run's token. A settle is not
# re-armed instead: its cleanup would close a login the user may still finish.
hitsz_mode_connect_failed() {
  [[ "$(hitsz_current_selection)" == "${SITE_SURGE_BACKEND_POLICY}" ]] || return 0
  printf 'Connection setup failed; returning Surge %s to %s.\n' \
    "${SITE_SURGE_GROUP}" "${SITE_SURGE_DIRECT_POLICY}" >&2
  bridge_activation_rollback "${BRIDGE_SETTLE_TOKEN:-}"
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

hitsz_mode_down_superseded() {
  printf 'A newer hitsz command took over the route; leaving the bridge running.\n' >&2
}

hitsz_mode_down() {
  local rc=0
  # The lock also guards an in-flight activation's backend selection; without
  # the claim it could select the backend after our DIRECT write and leave
  # Surge on a tunnel we are about to stop.
  if ! bridge_settle_claim; then
    printf 'Refusing to stop the bridge while another hitsz command owns the Surge route.\n' >&2
    return 1
  fi
  # Keep ownership through the shutdown: both steps run under the lock and only
  # while this generation is current, so a newer `up` either waits for the VM
  # to stop or makes this `down` back off before it stops a live tunnel.
  bridge_settle_exclusive "${BRIDGE_SETTLE_TOKEN}" hitsz_restore_direct_route || rc=$?
  if [[ "${rc}" -eq 3 ]]; then
    hitsz_mode_down_superseded
    return 1
  fi
  if [[ "${rc}" -ne 0 ]]; then
    printf 'Refusing to stop the bridge because HITSZ=DIRECT was not verified.\n' >&2
    return 1
  fi
  bridge_settle_exclusive "${BRIDGE_SETTLE_TOKEN}" "${ROOT_DIR}/bin/down" || rc=$?
  if [[ "${rc}" -eq 3 ]]; then
    hitsz_mode_down_superseded
    return 1
  fi
  if [[ "${rc}" -ne 0 ]]; then
    printf 'Stopping the bridge failed; the container or Colima VM may still be running.\n' >&2
    return "${rc}"
  fi
  hitsz_retest_group || true
  if hitsz_normal_jw_probe; then
    printf 'HITSZ direct access is available on the current network.\n'
  else
    printf 'Docker is off; JW is not directly available on this network.\n'
  fi
}
