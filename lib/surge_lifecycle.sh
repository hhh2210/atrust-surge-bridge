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

# TOKEN (optional) is the generation this activation claimed. Every Surge
# write runs under the settle lock and only while TOKEN is current, so an
# activation overtaken by a newer up or a down neither selects the backend
# nor rolls the newer owner back to DIRECT.
bridge_activation_rollback() {
  bridge_settle_exclusive "$1" bridge_surge_restore_direct || true
}

bridge_surge_activate() {
  local token="${1:-}" selection rc=0
  bridge_require_callbacks bridge_backend_ready bridge_backend_wait_ready \
    bridge_backend_prepare_proxy || return 1
  if ! bridge_backend_ready; then
    if ! bridge_backend_wait_ready 0; then
      bridge_activation_rollback "${token}"
      return 1
    fi
  fi
  if ! bridge_backend_prepare_proxy; then
    bridge_activation_rollback "${token}"
    return 1
  fi
  bridge_settle_exclusive "${token}" bridge_surge_select_backend || rc=$?
  if [[ "${rc}" -eq 3 ]]; then
    printf 'A newer %s command took over; leaving the Surge %s selection alone.\n' \
      "${SITE_LABEL}" "${SITE_SURGE_GROUP}" >&2
    return 1
  fi
  if [[ "${rc}" -ne 0 ]]; then
    bridge_activation_rollback "${token}"
    printf 'Failed to select the Surge %s policy.\n' \
      "${SITE_SURGE_BACKEND_POLICY}" >&2
    return 1
  fi
  selection="$(bridge_surge_current_selection)"
  if [[ "${selection}" != "${SITE_SURGE_BACKEND_POLICY}" ]]; then
    bridge_activation_rollback "${token}"
    printf 'Surge %s activation was not verified; live selection is %s.\n' \
      "${SITE_SURGE_GROUP}" "${selection}" >&2
    return 1
  fi
  if ! bridge_site_http_probe; then
    bridge_activation_rollback "${token}"
    printf '%s SOCKS is ready, but the Surge %s route still failed.\n' \
      "${SITE_BACKEND_LABEL}" "${SITE_SURGE_GROUP}" >&2
    return 1
  fi
  printf '%s network is available; completing stability checks...\n' \
    "${SITE_LABEL}"
}

bridge_state_dir() {
  printf '%s\n' "${HITSZ_STATE_DIR:-${BRIDGE_STATE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/atrust-surge-bridge/${SITE_ID}}}"
}

# A background settle owns the route only while its generation token is the
# current one; any newer activation or a shutdown cancels it before acting.
bridge_settle_superseded() {
  local token="${1:-}" current
  [[ -n "${token}" ]] || return 1
  current="$(cat "$(bridge_state_dir)/settle.generation" 2>/dev/null || true)"
  [[ "${current}" != "${token}" ]]
}

bridge_settle_job_alive() {
  local pid
  pid="$(cat "$(bridge_state_dir)/settle.pid" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ ]] &&
    ps -p "${pid}" -o command= 2>/dev/null | grep -q '__core_settle_bg'
}

# mkdir is atomic on every filesystem we target; macOS ships no flock(1).
# The owner PID lets a later caller reclaim a lock left by a killed process.
bridge_settle_lock() {
  local lock owner _
  lock="$(bridge_state_dir)/settle.lock"
  # 60 s covers the slowest guarded side effect: a Chromium stop that may wait
  # 25 s for the in-container browser lock and 20 s for a clean exit.
  for _ in $(seq 1 "${BRIDGE_SETTLE_LOCK_WAIT_TICKS:-600}"); do
    if mkdir "${lock}" 2>/dev/null; then
      printf '%s\n' "$$" >"${lock}/pid"
      return 0
    fi
    owner="$(cat "${lock}/pid" 2>/dev/null || true)"
    if [[ "${owner}" =~ ^[0-9]+$ ]] && ! kill -0 "${owner}" 2>/dev/null &&
      bridge_settle_reclaim "${lock}" "${owner}"; then
      continue
    fi
    sleep 0.1
  done
  printf 'Timed out waiting for the settle lock.\n' >&2
  return 1
}

# Only the waiter holding the reclaim guard may delete a dead owner's lock,
# and it re-reads the owner under the guard, so a second waiter that saw the
# same dead PID cannot delete the fresh lock the first one just created.
# Nobody else can replace the lock meanwhile: it only disappears through this
# guarded removal, and its dead owner will never unlock it.
bridge_settle_reclaim() {
  local lock="$1" dead_owner="$2" guard guard_owner
  guard="${lock}.reclaim"
  if ! mkdir "${guard}" 2>/dev/null; then
    guard_owner="$(cat "${guard}/pid" 2>/dev/null || true)"
    if [[ "${guard_owner}" =~ ^[0-9]+$ ]] && ! kill -0 "${guard_owner}" 2>/dev/null; then
      rm -rf "${guard}"
    fi
    return 1
  fi
  printf '%s\n' "$$" >"${guard}/pid"
  if [[ "$(cat "${lock}/pid" 2>/dev/null || true)" == "${dead_owner}" ]]; then
    rm -rf "${lock}"
  fi
  rm -rf "${guard}"
}

bridge_settle_unlock() {
  rm -rf "$(bridge_state_dir)/settle.lock"
}

# Run "$@" only while TOKEN is current, holding the settle lock across both
# the generation check and the side effect so a cancel cannot slip between
# them. Returns 3 without running anything when the token is superseded.
bridge_settle_exclusive() {
  local token="$1" rc=0
  shift
  if [[ -z "${token}" ]]; then
    "$@"
    return
  fi
  bridge_settle_lock || return 1
  if bridge_settle_superseded "${token}"; then
    bridge_settle_unlock
    return 3
  fi
  "$@" || rc=$?
  bridge_settle_unlock
  return "${rc}"
}

# Claims route ownership for a new activation: under the settle lock (which
# waits for any in-flight background side effect) it publishes a fresh
# generation in BRIDGE_SETTLE_TOKEN, then stops the old job. Killing the old
# job afterwards cannot leave an orphaned surge-cli/docker child that later
# overwrites the newer route, and a late dispatch from an older activation
# sees a different generation and backs off. Fails closed: without the lock
# the old job keeps ownership and nothing is killed. Call it directly, not in
# a command substitution, so the exported token reaches the caller.
bridge_settle_claim() {
  local dir pid token
  dir="$(bridge_state_dir)"
  (umask 077 && mkdir -p "${dir}") || return 1
  if ! bridge_settle_lock; then
    printf 'A previous stability check is still changing Surge; retry shortly.\n' >&2
    return 1
  fi
  token="$(uuidgen)"
  printf '%s\n' "${token}" >"${dir}/settle.generation"
  if bridge_settle_job_alive; then
    pid="$(cat "${dir}/settle.pid")"
    kill "${pid}" 2>/dev/null || true
  fi
  rm -f "${dir}/settle.pid"
  bridge_settle_unlock
  export BRIDGE_SETTLE_TOKEN="${token}"
}

# Prints RUNNING or FAILED when a background settle needs attention.
bridge_settle_status() {
  if bridge_settle_job_alive; then
    printf 'RUNNING\n'
  elif [[ "$(cut -d' ' -f1 "$(bridge_state_dir)/settle.state" 2>/dev/null)" == "failed" ]]; then
    printf 'FAILED\n'
  fi
}

bridge_surge_settle() {
  local token="${1:-}" rc=0
  bridge_require_callbacks bridge_backend_ready bridge_backend_cleanup || return 1
  if ! bridge_wait_for_stable_route; then
    bridge_settle_exclusive "${token}" bridge_surge_restore_direct || rc=$?
    [[ "${rc}" -ne 3 ]] || return 0
    return 1
  fi
  bridge_settle_exclusive "${token}" bridge_backend_cleanup || rc=$?
  [[ "${rc}" -ne 3 ]] || return 0
  [[ "${rc}" -eq 0 ]] || return 1
  if ! bridge_site_http_probe; then
    bridge_settle_exclusive "${token}" bridge_surge_restore_direct || rc=$?
    [[ "${rc}" -ne 3 ]] || return 0
    if [[ "${rc}" -eq 0 ]]; then
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

bridge_settle_run_bg() {
  local token="$1" dir rc=0
  dir="$(bridge_state_dir)"
  bridge_surge_settle "${token}" || rc=$?
  bridge_settle_superseded "${token}" && return 0
  if [[ "${rc}" -eq 0 ]]; then
    printf 'ok %s\n' "$(date +%s)" >"${dir}/settle.state"
  else
    printf 'failed %s\n' "$(date +%s)" >"${dir}/settle.state"
  fi
  rm -f "${dir}/settle.pid"
  return "${rc}"
}

# The route is already usable after activation; keep the stability window and
# its DIRECT rollback, but stop blocking the command on it. $1 is the CLI that
# implements the `__core_settle_bg <token>` entry point. The job is published
# only if BRIDGE_SETTLE_TOKEN (claimed by this activation) is still current.
bridge_settle_dispatch() {
  local cli="$1" token="${BRIDGE_SETTLE_TOKEN:-}" dir log
  if [[ "${BRIDGE_SETTLE_FOREGROUND:-${HITSZ_SETTLE_FOREGROUND:-0}}" == "1" ]]; then
    bridge_surge_settle "${token}"
    return
  fi
  if [[ -z "${token}" ]]; then
    printf 'No claimed settle generation; activation must claim the route first.\n' >&2
    return 1
  fi
  dir="$(bridge_state_dir)"
  log="${dir}/settle.log"
  bridge_settle_lock || return 1
  if bridge_settle_superseded "${token}"; then
    bridge_settle_unlock
    printf 'A newer activation owns the route; skipping this stability check.\n'
    return 0
  fi
  printf 'running %s\n' "$(date +%s)" >"${dir}/settle.state"
  nohup "${cli}" __core_settle_bg "${token}" >"${log}" 2>&1 </dev/null &
  printf '%s\n' "$!" >"${dir}/settle.pid"
  bridge_settle_unlock
  printf 'Stability check continues in the background (log: %s).\n' "${log}"
}
