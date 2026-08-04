#!/bin/bash
set -euo pipefail

TEST_ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
SURGE_CLI=/usr/bin/false
SITE_LABEL='Example University'
SITE_BACKEND_LABEL='native proxy'
SITE_HEALTH_LABEL='Portal'
SITE_SURGE_GROUP='EXAMPLE'
SITE_SURGE_DIRECT_POLICY='DIRECT'
SITE_SURGE_BACKEND_POLICY='EXAMPLE-native'
SITE_HEALTH_URL='https://portal.example.edu/'

# shellcheck source=../lib/surge_lifecycle.sh
source "${TEST_ROOT}/lib/surge_lifecycle.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail "${label}: expected '${expected}', got '${actual}'"
}

test_missing_backend_contract_fails_before_surge() (
  local marker
  marker="$(mktemp -t bridge-lifecycle.XXXXXX)"
  rm -f "${marker}"
  trap 'rm -f "${marker}"' EXIT

  bridge_surge_select_backend() { : >"${marker}"; }
  bridge_surge_restore_direct() { : >"${marker}"; }
  if bridge_surge_activate >/dev/null 2>&1; then
    fail 'missing backend callbacks must fail activation'
  fi
  [[ ! -e "${marker}" ]] || fail 'invalid backend contract must not touch Surge'
)

test_ready_backend_activates_without_wait() (
  local trace expected
  trace="$(mktemp -t bridge-lifecycle.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  bridge_backend_ready() { printf 'ready\n' >>"${trace}"; return 0; }
  bridge_backend_wait_ready() { printf 'wait\n' >>"${trace}"; return 0; }
  bridge_backend_prepare_proxy() { printf 'prepare\n' >>"${trace}"; return 0; }
  bridge_surge_select_backend() { printf 'select\n' >>"${trace}"; return 0; }
  bridge_surge_current_selection() {
    printf 'verify\n' >>"${trace}"
    printf '%s\n' "${SITE_SURGE_BACKEND_POLICY}"
  }
  bridge_site_http_probe() { printf 'probe\n' >>"${trace}"; return 0; }
  bridge_surge_restore_direct() { printf 'rollback\n' >>"${trace}"; return 0; }

  bridge_surge_activate >/dev/null
  expected=$'ready\nprepare\nselect\nverify\nprobe'
  assert_eq "${expected}" "$(cat "${trace}")" 'ready backend activation'
)

test_unverified_selection_rolls_back_before_probe() (
  local trace expected
  trace="$(mktemp -t bridge-lifecycle.XXXXXX)"
  trap 'rm -f "${trace}"' EXIT

  SITE_BACKEND_LABEL='container proxy'
  bridge_backend_ready() { printf 'ready\n' >>"${trace}"; return 0; }
  bridge_backend_wait_ready() { printf 'wait\n' >>"${trace}"; return 0; }
  bridge_backend_prepare_proxy() { printf 'prepare\n' >>"${trace}"; return 0; }
  bridge_surge_select_backend() { printf 'select\n' >>"${trace}"; return 0; }
  bridge_surge_current_selection() {
    printf 'verify\n' >>"${trace}"
    printf '%s\n' "${SITE_SURGE_DIRECT_POLICY}"
  }
  bridge_site_http_probe() { printf 'probe\n' >>"${trace}"; return 0; }
  bridge_surge_restore_direct() { printf 'rollback\n' >>"${trace}"; return 0; }

  if bridge_surge_activate >/dev/null 2>&1; then
    fail 'unverified backend selection must fail activation'
  fi
  expected=$'ready\nprepare\nselect\nverify\nrollback'
  assert_eq "${expected}" "$(cat "${trace}")" \
    'selection mismatch rollback before health probe'
)

tests=(
  test_missing_backend_contract_fails_before_surge
  test_ready_backend_activates_without_wait
  test_unverified_selection_rolls_back_before_probe
)

for test_name in "${tests[@]}"; do
  "${test_name}"
  printf 'PASS: %s\n' "${test_name}"
done
