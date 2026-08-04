#!/bin/bash
# shellcheck disable=SC2329 # Mock functions are called indirectly by sourced code.
set -euo pipefail

TEST_ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${TEST_ROOT}/lib/common.sh"
# shellcheck source=../lib/surge_mode.sh
source "${TEST_ROOT}/lib/surge_mode.sh"
# shellcheck source=../lib/status.sh
source "${TEST_ROOT}/lib/status.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${label}: expected '${expected}', got '${actual}'"
}

mock_running_container() {
  docker_ctx() {
    case "${1:-}" in
      info) return 0 ;;
      stats) printf '0.00%% · 400MiB / 956MiB\n' ;;
      *) return 1 ;;
    esac
  }
  container_running() { return 0; }
  nc() { return 0; }
}

test_selection_from_environment() (
  bridge_surge_environment() {
    printf '%s\n' '{"environment":{"ProxyGroupSelection":{"HITSZ":"HITSZ-aTrust"}}}'
  }
  assert_eq 'HITSZ-aTrust' "$(hitsz_current_selection)" 'live selection'

  bridge_surge_environment() { printf '%s\n' '{"environment":{}}'; }
  assert_eq 'UNKNOWN' "$(hitsz_current_selection)" 'missing selection'

  bridge_surge_environment() { printf '%s\n' 'not-json'; }
  assert_eq 'UNKNOWN' "$(hitsz_current_selection)" 'invalid environment JSON'

  bridge_surge_environment() { return 1; }
  assert_eq 'UNKNOWN' "$(hitsz_current_selection)" 'environment command failure'
)

test_disconnected_atrust_skips_probe() (
  local marker
  marker="$(mktemp -t hitsz-test-probe.XXXXXX)"
  rm -f "${marker}"
  trap 'rm -f "${marker}"' EXIT

  mock_running_container
  hitsz_current_selection() { printf 'HITSZ-aTrust\n'; }
  hitsz_vpn_ready() { return 1; }
  hitsz_status_jw_code() {
    : >"${marker}"
    printf '200\n'
  }

  hitsz_collect_status
  [[ ! -e "${marker}" ]] || fail 'disconnected aTrust must not probe JW'
  assert_eq 'SKIPPED' "${HITSZ_STATUS_JW_CODE}" 'disconnected JW state'
  assert_eq 'HITSZ-aTrust' "${HITSZ_STATUS_POLICY}" 'disconnected policy'
  assert_eq '待自动恢复' "${HITSZ_STATUS_MODE}" 'disconnected mode'
)

test_manual_latch_requires_login() (
  mock_running_container
  hitsz_current_selection() { printf 'HITSZ-aTrust\n'; }
  hitsz_vpn_ready() { return 1; }
  login_browser_running() {
    assert_eq '1' "${1:-}" 'status browser lock budget'
    return 1
  }
  manual_login_latched() {
    assert_eq '1' "${1:-}" 'status latch lock budget'
    return 0
  }

  hitsz_collect_status
  assert_eq 'SKIPPED' "${HITSZ_STATUS_JW_CODE}" 'manual latch JW state'
  assert_eq '需手动登录' "${HITSZ_STATUS_MODE}" 'manual latch mode'
)

test_active_login_browser_is_in_progress() (
  mock_running_container
  hitsz_current_selection() { printf 'HITSZ-aTrust\n'; }
  hitsz_vpn_ready() { return 1; }
  login_browser_running() {
    assert_eq '1' "${1:-}" 'active browser lock budget'
    return 0
  }
  manual_login_latched() { return 0; }

  hitsz_collect_status
  assert_eq '登录恢复中' "${HITSZ_STATUS_MODE}" 'active login browser mode'
)

test_direct_still_probes() (
  local marker
  marker="$(mktemp -t hitsz-test-probe.XXXXXX)"
  rm -f "${marker}"
  trap 'rm -f "${marker}"' EXIT

  mock_running_container
  hitsz_current_selection() { printf 'DIRECT\n'; }
  hitsz_vpn_ready() { return 1; }
  hitsz_status_jw_code() {
    : >"${marker}"
    printf '200\n'
  }

  hitsz_collect_status
  [[ -e "${marker}" ]] || fail 'DIRECT mode must probe JW'
  assert_eq '200' "${HITSZ_STATUS_JW_CODE}" 'DIRECT JW code'
  assert_eq '校园直连' "${HITSZ_STATUS_MODE}" 'DIRECT mode'
)

test_connected_atrust_probes() (
  local marker
  marker="$(mktemp -t hitsz-test-probe.XXXXXX)"
  rm -f "${marker}"
  trap 'rm -f "${marker}"' EXIT

  mock_running_container
  hitsz_current_selection() { printf 'HITSZ-aTrust\n'; }
  hitsz_vpn_ready() { return 0; }
  hitsz_status_jw_code() {
    : >"${marker}"
    printf '200\n'
  }

  hitsz_collect_status
  [[ -e "${marker}" ]] || fail 'connected aTrust must probe JW'
  assert_eq '200' "${HITSZ_STATUS_JW_CODE}" 'aTrust JW code'
  assert_eq '校外 aTrust' "${HITSZ_STATUS_MODE}" 'aTrust mode'
)

test_daemon_without_container_is_unavailable() (
  docker_ctx() {
    [[ "${1:-}" == "info" ]]
  }
  container_running() { return 1; }
  nc() { return 1; }
  hitsz_current_selection() { printf 'HITSZ-aTrust\n'; }

  hitsz_collect_status
  assert_eq 'IDLE' "${HITSZ_STATUS_DOCKER}" 'idle Docker daemon'
  assert_eq '不可用' "${HITSZ_STATUS_MODE}" 'absent container mode'
  assert_eq 'SKIPPED' "${HITSZ_STATUS_JW_CODE}" 'absent container JW state'
)

test_stats_race_does_not_abort_status() (
  docker_ctx() {
    case "${1:-}" in
      info) return 0 ;;
      stats) return 1 ;;
      *) return 1 ;;
    esac
  }
  container_running() { return 0; }
  nc() { return 1; }
  hitsz_current_selection() { printf 'HITSZ-aTrust\n'; }
  hitsz_vpn_ready() { return 1; }

  hitsz_collect_status
  assert_eq 'ON' "${HITSZ_STATUS_DOCKER}" 'container state during stats race'
  assert_eq '' "${HITSZ_STATUS_USAGE}" 'stats race usage'
  assert_eq '待自动恢复' "${HITSZ_STATUS_MODE}" 'stats race mode'
)

test_trusted_renewal_avoids_novnc() (
  local checks=0 marker
  marker="$(mktemp -t hitsz-test-novnc.XXXXXX)"
  rm -f "${marker}"
  trap 'rm -f "${marker}"' EXIT

  HITSZ_TRUSTED_LOGIN_GRACE_SECONDS=30
  HITSZ_LOGIN_WAIT_SECONDS=60
  hitsz_vpn_ready() {
    checks=$((checks + 1))
    [[ "${checks}" -ge 2 ]]
  }
  hitsz_open_login() { : >"${marker}"; }
  sleep() { :; }

  hitsz_wait_until_ready 1 >/dev/null
  [[ ! -e "${marker}" ]] || fail 'successful trusted renewal must not open noVNC'
)

test_novnc_opens_after_grace() (
  local checks=0 opened_at=0

  HITSZ_TRUSTED_LOGIN_GRACE_SECONDS=4
  HITSZ_LOGIN_WAIT_SECONDS=20
  hitsz_vpn_ready() {
    checks=$((checks + 1))
    [[ "${checks}" -ge 4 ]]
  }
  hitsz_open_login() { opened_at="${checks}"; }
  sleep() { :; }

  hitsz_wait_until_ready 1 >/dev/null
  assert_eq '2' "${opened_at}" 'noVNC grace attempt'
)

test_mode_up_triggers_client_login() (
  local trace expected
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  ensure_bridge_preflight() { printf 'preflight\n' >>"${trace}"; }
  atrust_bridge_running() { return 1; }
  hitsz_mode_start() { printf 'start\n' >>"${trace}"; }
  hitsz_vpn_ready() { printf 'vpn\n' >>"${trace}"; return 1; }
  trigger_atrust_login() { printf 'trigger\n' >>"${trace}"; }
  hitsz_wait_until_ready() { printf 'wait:%s\n' "$1" >>"${trace}"; }
  hitsz_mode_finish() { printf 'finish\n' >>"${trace}"; }

  hitsz_mode_up >/dev/null
  expected=$'preflight\nstart\nvpn\ntrigger\nwait:1\nfinish'
  assert_eq "${expected}" "$(cat "${trace}")" 'mode up login trigger order'
)

test_connect_reuses_running_container() (
  local trace expected
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  ensure_bridge_preflight() { printf 'preflight\n' >>"${trace}"; }
  atrust_bridge_running() { printf 'reuse\n' >>"${trace}"; return 0; }
  hitsz_mode_start() { printf 'start\n' >>"${trace}"; }
  hitsz_vpn_ready() { printf 'vpn\n' >>"${trace}"; return 0; }
  trigger_atrust_login() { printf 'trigger\n' >>"${trace}"; }
  hitsz_wait_until_ready() { printf 'wait\n' >>"${trace}"; }

  hitsz_mode_connect >/dev/null
  expected=$'preflight\nreuse\nvpn'
  assert_eq "${expected}" "$(cat "${trace}")" 'running bridge reuse'
)

test_preflight_failure_blocks_reuse() (
  local trace
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  ensure_bridge_preflight() { printf 'preflight-failed\n' >>"${trace}"; return 1; }
  atrust_bridge_running() { printf 'reuse\n' >>"${trace}"; return 0; }

  if hitsz_mode_connect >/dev/null 2>&1; then
    fail 'failed host-isolation preflight must block bridge reuse'
  fi
  assert_eq 'preflight-failed' "$(cat "${trace}")" 'preflight safety gate'
)

test_preflight_stops_at_first_failure() (
  local trace
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  ensure_tools() { printf 'tools-failed\n' >>"${trace}"; return 1; }
  ensure_host_isolated() { printf 'host\n' >>"${trace}"; return 0; }
  ensure_env() { printf 'env\n' >>"${trace}"; return 0; }

  if ensure_bridge_preflight; then
    fail 'preflight must propagate an ordinary tool setup failure'
  fi
  assert_eq 'tools-failed' "$(cat "${trace}")" 'preflight first failure boundary'
)

test_route_stability_requires_consecutive_health() (
  local checks=0
  BRIDGE_ROUTE_STABLE_SECONDS=6
  BRIDGE_ROUTE_STABLE_TIMEOUT_SECONDS=12
  BRIDGE_ROUTE_STABLE_INTERVAL_SECONDS=2
  sleep() { :; }
  hitsz_vpn_ready() {
    checks=$((checks + 1))
    [[ "${checks}" -ne 2 ]]
  }
  bridge_site_http_code() { printf '200\n'; }

  hitsz_wait_for_stable_route >/dev/null
  assert_eq '5' "${checks}" 'consecutive stability checks'
)

test_socks_path_retries_until_usable() (
  local attempts=0
  HITSZ_ROUTE_ACTIVATION_TIMEOUT_SECONDS=30
  HITSZ_ROUTE_ACTIVATION_INTERVAL_SECONDS=1
  hitsz_repair_dante_dns() {
    attempts=$((attempts + 1))
    [[ "${attempts}" -ge 3 ]]
  }
  sleep() { :; }

  hitsz_wait_for_socks_path
  assert_eq '3' "${attempts}" 'SOCKS path retry count'
)

test_activate_route_stops_at_usability_boundary() (
  local trace expected
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  hitsz_vpn_ready() { printf 'vpn\n' >>"${trace}"; return 0; }
  hitsz_repair_dante_dns() { printf 'repair\n' >>"${trace}"; }
  bridge_surge_select_backend() { printf 'route\n' >>"${trace}"; }
  bridge_surge_current_selection() { printf '%s\n' "${SITE_SURGE_BACKEND_POLICY}"; }
  bridge_site_http_probe() { printf 'probe\n' >>"${trace}"; return 0; }
  bridge_wait_for_stable_route() { printf 'stable\n' >>"${trace}"; return 0; }
  stop_login_browser() { printf 'trim\n' >>"${trace}"; return 0; }

  hitsz_mode_activate_route >/dev/null
  expected=$'vpn\nrepair\nroute\nprobe'
  assert_eq "${expected}" "$(cat "${trace}")" 'route usability boundary'
)

test_restore_direct_verifies_live_selection() (
  local mock_selection='HITSZ-aTrust'
  bridge_surge_select_direct() { return 0; }
  bridge_surge_current_selection() { printf '%s\n' "${mock_selection}"; }

  if hitsz_restore_direct_route >/dev/null 2>&1; then
    fail 'DIRECT rollback must fail when the live selection disagrees'
  fi
  mock_selection='DIRECT'
  hitsz_restore_direct_route
)

test_route_selection_failure_rolls_back() (
  local trace expected
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  hitsz_vpn_ready() { printf 'vpn\n' >>"${trace}"; return 0; }
  hitsz_wait_for_socks_path() { printf 'socks\n' >>"${trace}"; return 0; }
  bridge_surge_select_backend() { printf 'route-failed\n' >>"${trace}"; return 1; }
  bridge_surge_restore_direct() { printf 'direct\n' >>"${trace}"; return 0; }
  bridge_site_http_probe() { printf 'probe\n' >>"${trace}"; return 0; }

  if hitsz_mode_activate_route >/dev/null 2>&1; then
    fail 'failed HITSZ-aTrust selection must fail activation'
  fi
  expected=$'vpn\nsocks\nroute-failed\ndirect'
  assert_eq "${expected}" "$(cat "${trace}")" 'selection failure rollback'
)

test_tunnel_readiness_failure_rolls_back() (
  local trace expected
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  hitsz_vpn_ready() { printf 'vpn\n' >>"${trace}"; return 1; }
  hitsz_wait_until_ready() { printf 'wait:%s\n' "$1" >>"${trace}"; return 1; }
  bridge_surge_restore_direct() { printf 'direct\n' >>"${trace}"; return 0; }
  hitsz_wait_for_socks_path() { printf 'socks\n' >>"${trace}"; return 0; }

  if hitsz_mode_activate_route >/dev/null 2>&1; then
    fail 'failed tunnel readiness gate must fail activation'
  fi
  expected=$'vpn\nwait:0\ndirect'
  assert_eq "${expected}" "$(cat "${trace}")" 'tunnel readiness failure rollback'
)

test_down_requires_verified_direct() (
  local trace
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  bridge_surge_restore_direct() { printf 'direct-failed\n' >>"${trace}"; return 1; }
  hitsz_retest_group() { printf 'retest\n' >>"${trace}"; }
  bridge_site_http_probe() { printf 'probe\n' >>"${trace}"; }

  if hitsz_mode_down >/dev/null 2>&1; then
    fail 'down must fail closed when DIRECT cannot be verified'
  fi
  assert_eq 'direct-failed' "$(cat "${trace}")" 'down verified DIRECT gate'
)

test_finish_trims_after_success() (
  local trace expected
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  hitsz_vpn_ready() { printf 'vpn\n' >>"${trace}"; return 0; }
  hitsz_repair_dante_dns() { printf 'repair\n' >>"${trace}"; }
  bridge_surge_select_backend() { printf 'route\n' >>"${trace}"; }
  bridge_surge_current_selection() { printf '%s\n' "${SITE_SURGE_BACKEND_POLICY}"; }
  bridge_site_http_probe() { printf 'probe\n' >>"${trace}"; return 0; }
  bridge_wait_for_stable_route() { printf 'stable\n' >>"${trace}"; return 0; }
  stop_login_browser() { printf 'trim\n' >>"${trace}"; return 0; }

  hitsz_mode_finish >/dev/null
  expected=$'vpn\nrepair\nroute\nprobe\nstable\ntrim\nprobe'
  assert_eq "${expected}" "$(cat "${trace}")" 'successful finish order'
)

test_unstable_finish_reverts_direct_without_trim() (
  local trace expected
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  hitsz_vpn_ready() { printf 'vpn\n' >>"${trace}"; return 0; }
  hitsz_repair_dante_dns() { printf 'repair\n' >>"${trace}"; }
  bridge_surge_select_backend() { printf 'route\n' >>"${trace}"; }
  bridge_surge_current_selection() { printf '%s\n' "${SITE_SURGE_BACKEND_POLICY}"; }
  bridge_site_http_probe() { printf 'probe\n' >>"${trace}"; return 0; }
  bridge_wait_for_stable_route() { printf 'unstable\n' >>"${trace}"; return 1; }
  bridge_surge_restore_direct() { printf 'direct\n' >>"${trace}"; }
  stop_login_browser() { printf 'trim\n' >>"${trace}"; return 0; }

  if hitsz_mode_finish >/dev/null 2>&1; then
    fail 'unstable route must fail finish'
  fi
  expected=$'vpn\nrepair\nroute\nprobe\nunstable\ndirect'
  assert_eq "${expected}" "$(cat "${trace}")" 'unstable finish order'
)

test_browser_stop_failure_is_visible() (
  local trace expected
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  hitsz_vpn_ready() { printf 'vpn\n' >>"${trace}"; return 0; }
  hitsz_repair_dante_dns() { printf 'repair\n' >>"${trace}"; }
  bridge_surge_select_backend() { printf 'route\n' >>"${trace}"; }
  bridge_surge_current_selection() { printf '%s\n' "${SITE_SURGE_BACKEND_POLICY}"; }
  bridge_site_http_probe() { printf 'probe\n' >>"${trace}"; return 0; }
  bridge_wait_for_stable_route() { printf 'stable\n' >>"${trace}"; return 0; }
  stop_login_browser() { printf 'trim-failed\n' >>"${trace}"; return 1; }

  if hitsz_mode_finish >/dev/null 2>&1; then
    fail 'browser stop failure must fail finish'
  fi
  expected=$'vpn\nrepair\nroute\nprobe\nstable\ntrim-failed'
  assert_eq "${expected}" "$(cat "${trace}")" 'browser stop failure order'
)

test_post_stop_probe_failure_reverts_direct() (
  local trace expected probes=0
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  hitsz_vpn_ready() { printf 'vpn\n' >>"${trace}"; return 0; }
  hitsz_repair_dante_dns() { printf 'repair\n' >>"${trace}"; }
  bridge_surge_select_backend() { printf 'route\n' >>"${trace}"; }
  bridge_surge_current_selection() { printf '%s\n' "${SITE_SURGE_BACKEND_POLICY}"; }
  bridge_site_http_probe() {
    probes=$((probes + 1))
    printf 'probe:%s\n' "${probes}" >>"${trace}"
    [[ "${probes}" -eq 1 ]]
  }
  bridge_wait_for_stable_route() { printf 'stable\n' >>"${trace}"; return 0; }
  stop_login_browser() { printf 'trim\n' >>"${trace}"; return 0; }
  bridge_surge_restore_direct() { printf 'direct\n' >>"${trace}"; }

  if hitsz_mode_finish >/dev/null 2>&1; then
    fail 'post-stop probe failure must fail finish'
  fi
  expected=$'vpn\nrepair\nroute\nprobe:1\nstable\ntrim\nprobe:2\ndirect'
  assert_eq "${expected}" "$(cat "${trace}")" 'post-stop failure order'
)

test_failed_finish_does_not_trim() (
  local trace expected
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  hitsz_vpn_ready() { printf 'vpn\n' >>"${trace}"; return 0; }
  hitsz_repair_dante_dns() { printf 'repair\n' >>"${trace}"; }
  bridge_surge_select_backend() { printf 'route\n' >>"${trace}"; }
  bridge_surge_current_selection() { printf '%s\n' "${SITE_SURGE_BACKEND_POLICY}"; }
  bridge_site_http_probe() { printf 'probe\n' >>"${trace}"; return 1; }
  bridge_surge_restore_direct() { printf 'direct\n' >>"${trace}"; }
  stop_login_browser() { printf 'trim\n' >>"${trace}"; return 0; }

  if hitsz_mode_finish >/dev/null 2>&1; then
    fail 'failed JW probe must fail finish'
  fi
  expected=$'vpn\nrepair\nroute\nprobe\ndirect'
  assert_eq "${expected}" "$(cat "${trace}")" 'failed finish order'
)

tests=(
  test_selection_from_environment
  test_disconnected_atrust_skips_probe
  test_manual_latch_requires_login
  test_active_login_browser_is_in_progress
  test_direct_still_probes
  test_connected_atrust_probes
  test_daemon_without_container_is_unavailable
  test_stats_race_does_not_abort_status
  test_trusted_renewal_avoids_novnc
  test_novnc_opens_after_grace
  test_mode_up_triggers_client_login
  test_connect_reuses_running_container
  test_preflight_failure_blocks_reuse
  test_preflight_stops_at_first_failure
  test_route_stability_requires_consecutive_health
  test_socks_path_retries_until_usable
  test_activate_route_stops_at_usability_boundary
  test_restore_direct_verifies_live_selection
  test_route_selection_failure_rolls_back
  test_tunnel_readiness_failure_rolls_back
  test_down_requires_verified_direct
  test_finish_trims_after_success
  test_unstable_finish_reverts_direct_without_trim
  test_browser_stop_failure_is_visible
  test_post_stop_probe_failure_reverts_direct
  test_failed_finish_does_not_trim
)

for test_name in "${tests[@]}"; do
  "${test_name}"
  printf 'PASS: %s\n' "${test_name}"
done
