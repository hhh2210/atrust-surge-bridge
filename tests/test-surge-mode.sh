#!/bin/bash
# shellcheck disable=SC2317,SC2329,SC2030,SC2031 # Mocks are called indirectly; each test is an isolated subshell.
set -euo pipefail

TEST_ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"

# shellcheck source=../lib/common.sh
source "${TEST_ROOT}/lib/common.sh"
# shellcheck source=../lib/surge_mode.sh
source "${TEST_ROOT}/lib/surge_mode.sh"
# shellcheck source=../lib/status.sh
source "${TEST_ROOT}/lib/status.sh"
# shellcheck source=../lib/ui.sh
source "${TEST_ROOT}/lib/ui.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

HITSZ_STATE_DIR="$(mktemp -d -t hitsz-test-state.XXXXXX)"
export HITSZ_STATE_DIR
trap 'rm -rf "${HITSZ_STATE_DIR}"' EXIT

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
  cas_login_form_visible() { return 1; }
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
  cas_login_form_visible() { return 1; }
  sleep() { :; }

  hitsz_wait_until_ready 1 >/dev/null
  assert_eq '2' "${opened_at}" 'noVNC grace attempt'
)

test_novnc_opens_early_on_waiting_cas_form() (
  local checks=0 opened_at=0 opens=0

  HITSZ_TRUSTED_LOGIN_GRACE_SECONDS=30
  HITSZ_LOGIN_WAIT_SECONDS=60
  hitsz_vpn_ready() {
    checks=$((checks + 1))
    [[ "${checks}" -ge 10 ]]
  }
  # The form appears on the third check and stays until a human submits it.
  cas_login_form_visible() { [[ "${checks}" -ge 3 ]]; }
  hitsz_open_login() {
    opens=$((opens + 1))
    opened_at="${checks}"
  }
  sleep() { :; }

  hitsz_wait_until_ready 1 >/dev/null
  assert_eq '4' "${opened_at}" 'early noVNC reveal check'
  assert_eq '1' "${opens}" 'noVNC opens once'
)

test_transient_cas_form_does_not_open_novnc() (
  local checks=0 marker
  marker="$(mktemp -t hitsz-test-novnc.XXXXXX)"
  rm -f "${marker}"
  trap 'rm -f "${marker}"' EXIT

  HITSZ_TRUSTED_LOGIN_GRACE_SECONDS=30
  HITSZ_LOGIN_WAIT_SECONDS=60
  hitsz_vpn_ready() {
    checks=$((checks + 1))
    [[ "${checks}" -ge 4 ]]
  }
  # CAS SSO redirects away from the form before a second check sees it.
  cas_login_form_visible() { [[ "${checks}" -eq 2 ]]; }
  hitsz_open_login() { : >"${marker}"; }
  sleep() { :; }

  hitsz_wait_until_ready 1 >/dev/null
  [[ ! -e "${marker}" ]] || fail 'a CAS SSO pass-through must not open noVNC'
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
  hitsz_mode_finish_dispatch() { printf 'finish-dispatch\n' >>"${trace}"; }

  hitsz_mode_up >/dev/null
  expected=$'preflight\nstart\nvpn\ntrigger\nwait:1\nfinish-dispatch'
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

test_background_settle_dispatch_records_generation() (
  local trace launched
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  nohup() { printf '%s\n' "$*" >"${trace}"; }
  bridge_surge_settle() { fail 'background dispatch must not settle in the foreground'; }

  bridge_settle_claim
  hitsz_settle_dispatch >/dev/null
  wait
  launched="$(cat "${trace}")"
  [[ "${launched}" == *"/bin/hitsz __core_settle_bg $(cat "${HITSZ_STATE_DIR}/settle.generation")" ]] ||
    fail "unexpected background settle command: ${launched}"
  assert_eq 'running' "$(cut -d' ' -f1 "${HITSZ_STATE_DIR}/settle.state")" 'dispatch state'
)

test_foreground_settle_env_keeps_blocking_path() (
  local trace
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  export HITSZ_SETTLE_FOREGROUND=1
  nohup() { fail 'foreground settle must not launch a background job'; }
  bridge_surge_settle() { printf 'settle:%s\n' "${1:-}" >>"${trace}"; }

  hitsz_settle_dispatch
  assert_eq 'settle:' "$(cat "${trace}")" 'foreground settle call'
)

test_superseded_settle_never_rolls_back() (
  local trace
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  printf 'newer-generation\n' >"${HITSZ_STATE_DIR}/settle.generation"
  bridge_wait_for_stable_route() { return 1; }
  bridge_surge_restore_direct() { printf 'direct\n' >>"${trace}"; }
  bridge_backend_cleanup() { printf 'trim\n' >>"${trace}"; }

  hitsz_mode_settle_bg 'old-generation' || fail 'superseded settle must exit quietly'
  assert_eq '' "$(cat "${trace}")" 'superseded settle side effects'
)

test_current_settle_failure_rolls_back_and_records() (
  local trace
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  printf 'gen-1\n' >"${HITSZ_STATE_DIR}/settle.generation"
  bridge_wait_for_stable_route() { return 1; }
  bridge_surge_restore_direct() { printf 'direct\n' >>"${trace}"; }

  if hitsz_mode_settle_bg 'gen-1' >/dev/null 2>&1; then
    fail 'an unstable current settle must fail'
  fi
  assert_eq 'direct' "$(cat "${trace}")" 'current settle rollback'
  assert_eq 'failed' "$(cut -d' ' -f1 "${HITSZ_STATE_DIR}/settle.state")" 'failed settle state'
)

test_activation_cancels_previous_settle() (
  printf 'gen-1\n' >"${HITSZ_STATE_DIR}/settle.generation"
  bridge_surge_activate() { return 0; }

  hitsz_mode_activate_route >/dev/null
  bridge_settle_superseded 'gen-1' || fail 'a new activation must supersede the old settle'
)

test_status_reports_failed_settle() (
  printf 'failed 0\n' >"${HITSZ_STATE_DIR}/settle.state"
  rm -f "${HITSZ_STATE_DIR}/settle.pid"
  docker_ctx() { return 1; }
  nc() { return 1; }
  hitsz_current_selection() { printf 'DIRECT\n'; }
  hitsz_status_jw_code() { printf '000\n'; }

  hitsz_collect_status
  assert_eq 'FAILED' "${HITSZ_STATUS_SETTLE}" 'failed settle status'
)

test_ui_renders_settle_row() (
  local output
  hitsz_ui_enabled() { return 0; }
  # Echo the last argument so rendered rows stay visible without gum.
  gum() { local last; for last in "$@"; do :; done; printf '%s\n' "${last}"; }
  HITSZ_STATUS_MODE='校外 aTrust'
  HITSZ_STATUS_JW_CODE='200'
  HITSZ_STATUS_POLICY='HITSZ-aTrust'
  HITSZ_STATUS_DOCKER='ON'
  HITSZ_STATUS_USAGE=''
  HITSZ_STATUS_VPN='CONNECTED'
  HITSZ_STATUS_SOCKS='OPEN'
  HITSZ_STATUS_SETTLE='RUNNING'

  output="$(hitsz_ui_render_status 2>&1)"
  [[ "${output}" == *'Settle'*'后台验收中'* ]] || fail "settle row missing: ${output}"
  [[ "${output}" != *'syntax error'* ]] || fail "status UI failed to parse: ${output}"
)

test_cancel_waits_for_inflight_rollback() (
  local trace bg
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  printf 'gen-1\n' >"${HITSZ_STATE_DIR}/settle.generation"
  slow_rollback() {
    command sleep 0.6
    printf 'direct\n' >>"${trace}"
  }
  bridge_settle_exclusive 'gen-1' slow_rollback &
  bg=$!
  command sleep 0.2
  # A new activation claims the route while the old rollback is in flight.
  bridge_settle_claim
  printf 'activate\n' >>"${trace}"
  wait "${bg}" || true
  assert_eq $'direct\nactivate' "$(cat "${trace}")" 'cancel waits for in-flight rollback'
  [[ ! -d "${HITSZ_STATE_DIR}/settle.lock" ]] || fail 'settle lock must be released'
)

test_superseded_exclusive_skips_side_effect() (
  local rc=0
  printf 'cancelled\n' >"${HITSZ_STATE_DIR}/settle.generation"
  side_effect() { fail 'superseded token must not run its side effect'; }
  bridge_settle_exclusive 'gen-1' side_effect || rc=$?
  assert_eq '3' "${rc}" 'superseded exclusive status'
)

test_stale_settle_lock_is_reclaimed() (
  mkdir -p "${HITSZ_STATE_DIR}/settle.lock"
  printf '999999\n' >"${HITSZ_STATE_DIR}/settle.lock/pid"
  export BRIDGE_SETTLE_LOCK_WAIT_TICKS=5
  bridge_settle_lock || fail 'a lock owned by a dead PID must be reclaimed'
  bridge_settle_unlock
)

test_cancel_timeout_blocks_new_activation() (
  local holder trace
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  command sleep 30 &
  holder=$!
  trap 'kill "${holder}" 2>/dev/null; rm -f "${trace}"' EXIT

  printf 'gen-1\n' >"${HITSZ_STATE_DIR}/settle.generation"
  mkdir -p "${HITSZ_STATE_DIR}/settle.lock"
  printf '%s\n' "${holder}" >"${HITSZ_STATE_DIR}/settle.lock/pid"
  export BRIDGE_SETTLE_LOCK_WAIT_TICKS=2
  bridge_surge_activate() { printf 'activate\n' >>"${trace}"; }

  if hitsz_mode_activate_route >/dev/null 2>&1; then
    fail 'activation must fail while an old side effect still holds the lock'
  fi
  assert_eq '' "$(cat "${trace}")" 'no activation behind a live settle lock'
  assert_eq 'gen-1' "$(cat "${HITSZ_STATE_DIR}/settle.generation")" 'old generation kept'
  rm -rf "${HITSZ_STATE_DIR}/settle.lock"
)

test_late_dispatch_from_older_activation_backs_off() (
  local trace token_a
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  nohup() {
    local last
    for last in "$@"; do :; done
    printf 'launch:%s\n' "${last}" >>"${trace}"
  }
  # Two overlapping `hitsz up` runs: A claims, then B claims and dispatches,
  # then A's dispatch arrives late.
  bridge_settle_claim
  token_a="${BRIDGE_SETTLE_TOKEN}"
  bridge_settle_claim
  hitsz_settle_dispatch >/dev/null
  wait
  BRIDGE_SETTLE_TOKEN="${token_a}" hitsz_settle_dispatch >/dev/null
  wait
  assert_eq "launch:$(cat "${HITSZ_STATE_DIR}/settle.generation")" "$(cat "${trace}")" \
    'only the newest activation launches a settle'
)

test_foreground_settle_respects_claimed_token() (
  local trace
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  bridge_settle_claim
  # A newer activation claims the route while this foreground check runs.
  ( bridge_settle_claim )
  bridge_wait_for_stable_route() { return 1; }
  bridge_surge_restore_direct() { printf 'direct\n' >>"${trace}"; }
  bridge_backend_cleanup() { printf 'trim\n' >>"${trace}"; }

  hitsz_mode_settle >/dev/null 2>&1 || fail 'superseded foreground settle must exit quietly'
  assert_eq '' "$(cat "${trace}")" 'superseded foreground settle side effects'
)

test_mode_up_claims_before_login_side_effects() (
  local trace expected
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  bridge_settle_claim() {
    printf 'claim\n' >>"${trace}"
    export BRIDGE_SETTLE_TOKEN=t1
  }
  hitsz_mode_connect() { printf 'connect\n' >>"${trace}"; }
  bridge_surge_activate() { printf 'activate\n' >>"${trace}"; }
  hitsz_settle_dispatch() { printf 'dispatch\n' >>"${trace}"; }

  hitsz_mode_up >/dev/null
  expected=$'claim\nconnect\nactivate\ndispatch'
  assert_eq "${expected}" "$(cat "${trace}")" 'claim precedes login and is not repeated'
)

test_overtaken_activation_never_selects_backend() (
  local trace token_a
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  bridge_backend_ready() { return 0; }
  bridge_backend_wait_ready() { return 0; }
  bridge_backend_prepare_proxy() { return 0; }
  bridge_surge_select_backend() { printf 'backend\n' >>"${trace}"; }
  bridge_surge_restore_direct() { printf 'direct\n' >>"${trace}"; }
  bridge_surge_current_selection() { printf 'HITSZ-aTrust\n'; }
  bridge_site_http_probe() { return 0; }

  # up A claims, then down B claims before A reaches the Surge write.
  bridge_settle_claim
  token_a="${BRIDGE_SETTLE_TOKEN}"
  ( bridge_settle_claim )
  if BRIDGE_SETTLE_TOKEN="${token_a}" hitsz_mode_activate_route >/dev/null 2>&1; then
    fail 'an overtaken activation must fail'
  fi
  assert_eq '' "$(cat "${trace}")" 'overtaken activation must not touch Surge'
)

test_concurrent_stale_lock_reclaim_is_exclusive() (
  local trace xdir i f overlap
  trace="$(mktemp -t hitsz-test-trace.XXXXXX)"
  xdir="$(mktemp -d -t hitsz-test-xtrace.XXXXXX)"
  trap 'rm -f "${trace}"; rm -rf "${xdir}"' EXIT

  mkdir -p "${HITSZ_STATE_DIR}/settle.lock"
  printf '999999\n' >"${HITSZ_STATE_DIR}/settle.lock/pid"
  critical() {
    # shellcheck disable=SC2012 # inode of a fixed path, portable to BSD and GNU
    printf 'in %s inode=%s\n' "$1" "$(ls -id "${HITSZ_STATE_DIR}/settle.lock" 2>/dev/null | awk '{print $1}')" >>"${trace}"
    command sleep 0.15
    printf 'out %s\n' "$1" >>"${trace}"
  }
  for i in 1 2 3 4; do
    (
      # TEMP diagnostics for the Linux CI overlap: per-waiter timed xtrace.
      if ((BASH_VERSINFO[0] >= 5)); then
        exec 9>"${xdir}/w${i}"
        BASH_XTRACEFD=9
        # shellcheck disable=SC2016 # expanded by xtrace at run time
        PS4='+ ${EPOCHREALTIME} ${BASHPID} '
        set -x
      fi
      bridge_settle_lock && { critical "${i}"; bridge_settle_unlock; }
    ) &
  done
  wait
  overlap="$(awk '$1=="in"{d++; if(d>m)m=d} $1=="out"{d--} END{print m+0}' "${trace}")"
  if [[ "${overlap}" != '1' ]]; then
    cat "${trace}" >&2
    for f in "${xdir}"/w*; do
      printf '== %s\n' "${f##*/}" >&2
      grep -v 'seq 1\|^+* *[0-9.]* [0-9]* local ' "${f}" | head -60 >&2
    done
  fi
  assert_eq '1' "${overlap}" 'at most one holder after a stale-lock reclaim'
  assert_eq '8' "$(wc -l <"${trace}" | tr -d ' ')" 'every waiter got the lock'
)

test_claim_without_uuidgen_still_locks() (
  local bin tool
  bin="$(mktemp -d -t hitsz-test-bin.XXXXXX)"
  trap 'rm -rf "${bin}"' EXIT
  for tool in cat date grep mkdir ps rm seq sleep; do
    ln -s "$(command -v "${tool}")" "${bin}/${tool}"
  done
  PATH="${bin}" bridge_settle_claim
  [[ -n "${BRIDGE_SETTLE_TOKEN}" ]] || fail 'claim must produce a token without uuidgen'
  assert_eq "${BRIDGE_SETTLE_TOKEN}" "$(cat "${HITSZ_STATE_DIR}/settle.generation")" \
    'generation without uuidgen'
)

test_reclaim_skips_lock_replaced_by_live_owner() (
  mkdir -p "${HITSZ_STATE_DIR}/settle.lock"
  printf '%s\n' "$$" >"${HITSZ_STATE_DIR}/settle.lock/pid"
  # A waiter that earlier saw a dead owner must not delete the live lock.
  bridge_settle_reclaim "${HITSZ_STATE_DIR}/settle.lock" 999999 || true
  [[ -d "${HITSZ_STATE_DIR}/settle.lock" ]] || fail 'reclaim deleted a live lock'
  rm -rf "${HITSZ_STATE_DIR}/settle.lock"
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
  test_novnc_opens_early_on_waiting_cas_form
  test_transient_cas_form_does_not_open_novnc
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
  test_background_settle_dispatch_records_generation
  test_foreground_settle_env_keeps_blocking_path
  test_superseded_settle_never_rolls_back
  test_current_settle_failure_rolls_back_and_records
  test_activation_cancels_previous_settle
  test_status_reports_failed_settle
  test_ui_renders_settle_row
  test_cancel_waits_for_inflight_rollback
  test_superseded_exclusive_skips_side_effect
  test_stale_settle_lock_is_reclaimed
  test_cancel_timeout_blocks_new_activation
  test_late_dispatch_from_older_activation_backs_off
  test_foreground_settle_respects_claimed_token
  test_mode_up_claims_before_login_side_effects
  test_overtaken_activation_never_selects_backend
  test_concurrent_stale_lock_reclaim_is_exclusive
  test_claim_without_uuidgen_still_locks
  test_reclaim_skips_lock_replaced_by_live_owner
)

for test_name in "${tests[@]}"; do
  "${test_name}"
  printf 'PASS: %s\n' "${test_name}"
done
