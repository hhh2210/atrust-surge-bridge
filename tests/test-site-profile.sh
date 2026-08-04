#!/bin/bash
set -euo pipefail

TEST_ROOT="$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)"
ROOT_DIR="${TEST_ROOT}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

# shellcheck source=../lib/site_profile.sh
source "${TEST_ROOT}/lib/site_profile.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

(
  unset HITSZ_JW_HOST HITSZ_JW_URL HITSZ_JW_IP
  load_site_profile hitsz
  [[ "${SITE_PROFILE}" == 'hitsz' ]] || fail 'wrong profile slug'
  [[ "${SITE_SURGE_GROUP}" == 'HITSZ' ]] || fail 'wrong Surge group'
  [[ "${SITE_SURGE_BACKEND_POLICY}" == 'HITSZ-aTrust' ]] || fail 'wrong backend policy'
  [[ "${SITE_HEALTH_URL}" == 'https://jw.hitsz.edu.cn/' ]] || fail 'wrong health URL'
  [[ "${SITE_SOCKS_HOST}:${SITE_SOCKS_PORT}" == '127.0.0.1:1080' ]] || fail 'wrong SOCKS endpoint'
)

(
  # shellcheck disable=SC2034 # Read by the dynamically sourced site profile.
  HITSZ_JW_HOST='health.example.edu'
  # shellcheck disable=SC2034 # Read by the dynamically sourced site profile.
  HITSZ_JW_IP='10.0.0.8'
  unset HITSZ_JW_URL
  load_site_profile hitsz
  [[ "${SITE_HEALTH_URL}" == 'https://health.example.edu/' ]] || fail 'wrong derived URL'
  [[ "${SITE_HEALTH_REAL_IP}" == '10.0.0.8' ]] || fail 'wrong real IP override'
)

(
  if load_site_profile '../hitsz' >/dev/null 2>&1; then
    fail 'path traversal profile must be rejected'
  fi
  if load_site_profile missing >/dev/null 2>&1; then
    fail 'unknown profile must be rejected'
  fi
)

(
  temp_root="$(mktemp -d -t site-profile.XXXXXX)"
  trap 'rm -rf "${temp_root}"' EXIT
  mkdir -p "${temp_root}/sites"
  cp "${TEST_ROOT}/sites/hitsz.sh" "${temp_root}/sites/badport.sh"
  printf '\nSITE_SOCKS_PORT="65536"\n' >>"${temp_root}/sites/badport.sh"
  ROOT_DIR="${temp_root}"
  if load_site_profile badport >/dev/null 2>&1; then
    fail 'SOCKS port above 65535 must be rejected'
  fi
)

printf 'PASS: site profile loading and validation\n'
