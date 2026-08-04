#!/bin/bash

load_site_profile() {
  local profile_name="${1:-${ATRUST_SITE:-hitsz}}" profile_path required

  if [[ ! "${profile_name}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
    die "invalid site profile name: ${profile_name}"
    return 1
  fi
  profile_path="${ROOT_DIR}/sites/${profile_name}.sh"
  if [[ ! -f "${profile_path}" ]]; then
    die "site profile not found: ${profile_name}"
    return 1
  fi

  unset SITE_ID SITE_LABEL SITE_BACKEND_LABEL SITE_HEALTH_LABEL \
    SITE_SURGE_GROUP SITE_SURGE_DIRECT_POLICY SITE_SURGE_BACKEND_POLICY \
    SITE_HEALTH_HOST SITE_HEALTH_URL SITE_HEALTH_REAL_IP \
    SITE_SOCKS_HOST SITE_SOCKS_PORT
  # shellcheck disable=SC1090 # Path is constrained to a bundled profile slug.
  source "${profile_path}"
  for required in \
    SITE_ID SITE_LABEL SITE_BACKEND_LABEL SITE_HEALTH_LABEL \
    SITE_SURGE_GROUP SITE_SURGE_DIRECT_POLICY SITE_SURGE_BACKEND_POLICY \
    SITE_HEALTH_HOST SITE_HEALTH_URL SITE_HEALTH_REAL_IP \
    SITE_SOCKS_HOST SITE_SOCKS_PORT; do
    if [[ -z "${!required:-}" ]]; then
      die "site profile ${profile_name} is missing ${required}"
      return 1
    fi
  done

  if [[ ! "${SITE_SOCKS_PORT}" =~ ^[1-9][0-9]{0,4}$ ]] ||
    ((10#${SITE_SOCKS_PORT} > 65535)); then
    die "site profile ${profile_name} has an invalid SOCKS port"
    return 1
  fi
  # shellcheck disable=SC2034 # Exposed to callers for diagnostics.
  SITE_PROFILE="${profile_name}"
}
