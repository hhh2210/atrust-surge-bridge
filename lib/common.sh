#!/bin/bash

ROOT_DIR="$(unset CDPATH; cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="atrust-surge"
DOCKER_SOCKET="unix://${HOME}/.colima/${PROFILE}/docker.sock"
DOCKER_CONFIG_DIR="${ROOT_DIR}/docker-config"
COMPOSE_PROJECT="atrust-surge-bridge"
COMPOSE_FILE="${ROOT_DIR}/compose.yaml"
ENV_FILE="${ROOT_DIR}/.env"
CONTAINER_NAME="atrust-surge"
# shellcheck disable=SC2034 # consumed by scripts that source this library
SURGE_SOURCE="${SURGE_SOURCE:-${HOME}/Library/Mobile Documents/com~apple~CloudDocs/surge/Ash_origin.conf}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

ensure_tools() {
  require_command colima
  require_command docker
  require_command docker-buildx
  require_command docker-compose
  require_command nc
  require_command jq
  ensure_docker_config
}

ensure_docker_config() {
  mkdir -p "${DOCKER_CONFIG_DIR}"
  if [[ ! -f "${DOCKER_CONFIG_DIR}/config.json" ]]; then
    umask 077
    printf '{}\n' >"${DOCKER_CONFIG_DIR}/config.json"
  fi
}

native_atrust_tunnel() {
  ifconfig | awk '
    /^[[:alnum:]]+:/ {
      iface=$1
      sub(/:$/, "", iface)
    }
    $1 == "inet" && $2 ~ /^10\.251\./ {
      print iface " (" $2 ")"
      found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

native_atrust_fakeip_route() {
  netstat -rn -f inet | awk '
    $1 ~ /^198\.18(\/16|\.0\/16|\.0\.0\/16)$/ {
      print $0
      found=1
    }
    END { exit(found ? 0 : 1) }
  '
}

ensure_host_isolated() {
  local tunnel route
  tunnel="$(native_atrust_tunnel 2>/dev/null || true)"
  route="$(native_atrust_fakeip_route 2>/dev/null || true)"
  if [[ -n "${tunnel}" || -n "${route}" ]]; then
    printf 'Native aTrust tunnel detected. Log out of the macOS aTrust client first.\n' >&2
    [[ -z "${tunnel}" ]] || printf 'Tunnel: %s\n' "${tunnel}" >&2
    [[ -z "${route}" ]] || printf 'Route: %s\n' "${route}" >&2
    die "refusing to start a second aTrust tunnel on the host"
  fi
}

ensure_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    local password
    password="$(uuidgen | tr -d '-' | cut -c1-8)"
    umask 077
    printf 'ATRUST_VNC_PASSWORD=%s\n' "${password}" >"${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
  fi
}

vnc_password() {
  sed -n 's/^ATRUST_VNC_PASSWORD=//p' "${ENV_FILE}"
}

novnc_autologin_url() {
  local encoded nonce
  require_command jq
  ensure_env
  encoded="$(jq -rn --arg value "$(vnc_password)" '$value | @uri')"
  nonce="$(uuidgen | tr -d '-')"
  printf 'http://127.0.0.1:6080/atrust-vnc.html?autoconnect=true&resize=scale&bridge_nonce=%s#password=%s\n' \
    "${nonce}" "${encoded}"
}

colima_running() {
  colima status "${PROFILE}" >/dev/null 2>&1
}

start_colima() {
  colima start "${PROFILE}" \
    --runtime docker \
    --arch aarch64 \
    --vm-type vz \
    --cpus 1 \
    --memory 1 \
    --disk 8 \
    --mount none \
    --kubernetes=false \
    --activate=false \
    --binfmt=false \
    --ssh-config=false
}

docker_ctx() {
  DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" DOCKER_HOST="${DOCKER_SOCKET}" docker "$@"
}

compose() {
  DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" DOCKER_HOST="${DOCKER_SOCKET}" docker-compose \
    --project-name "${COMPOSE_PROJECT}" \
    --env-file "${ENV_FILE}" \
    --file "${COMPOSE_FILE}" \
    "$@"
}

build_atrust_image() {
  DOCKER_CONFIG="${DOCKER_CONFIG_DIR}" DOCKER_HOST="${DOCKER_SOCKET}" \
    docker-buildx build \
      --platform linux/arm64 \
      --load \
      --tag atrust-surge:2.5.16.20-chromium-arm64 \
      --build-arg ATRUST_BASE=hagb/docker-atrust@sha256:60a9114dc31a10b9a809ceb283697748fe325143c78689fc9300522f89af6875 \
      "${ROOT_DIR}"
}

wait_for_docker() {
  local _
  for _ in {1..60}; do
    docker_ctx info >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "Docker in Colima did not become ready"
}

wait_for_port() {
  local port="$1" _
  for _ in {1..90}; do
    nc -z -w 1 127.0.0.1 "${port}" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "127.0.0.1:${port} did not become ready"
}

container_running() {
  docker_ctx inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null | grep -q '^true$'
}

stop_login_browser() {
  container_running || return 0
  docker_ctx exec "${CONTAINER_NAME}" \
    /usr/local/bin/atrust-browser-control stop
}

login_browser_running() {
  container_running &&
    docker_ctx exec "${CONTAINER_NAME}" \
      /usr/local/bin/atrust-browser-control running >/dev/null 2>&1
}

trigger_atrust_login() {
  container_running || return 1
  docker_ctx exec -e DISPLAY=:1 "${CONTAINER_NAME}" \
    /usr/local/bin/atrust-browser-control trigger
}
