#!/bin/bash

HITSZ_UI_PURPLE="#A78BFA"
HITSZ_UI_GREEN="#34D399"
HITSZ_UI_YELLOW="#FBBF24"
HITSZ_UI_RED="#FB7185"
HITSZ_UI_MUTED="#94A3B8"

hitsz_ui_enabled() {
  [[ -t 1 ]] && [[ "${HITSZ_PLAIN:-0}" != "1" ]] &&
    [[ -z "${NO_COLOR:-}" ]] && command -v gum >/dev/null 2>&1
}

hitsz_ui_plain_status() {
  printf 'Mode: %s\n' "${HITSZ_STATUS_MODE}"
  printf 'JW: HTTP %s via %s\n' "${HITSZ_STATUS_JW_CODE}" "${HITSZ_STATUS_POLICY}"
  printf 'Docker: %s%s\n' "${HITSZ_STATUS_DOCKER}" "${HITSZ_STATUS_USAGE:+ (${HITSZ_STATUS_USAGE})}"
  printf 'VPN: %s\n' "${HITSZ_STATUS_VPN}"
  printf 'SOCKS: 127.0.0.1:1080 %s\n' "${HITSZ_STATUS_SOCKS}"
}

hitsz_ui_render_status() {
  if ! hitsz_ui_enabled; then
    hitsz_ui_plain_status
    return
  fi

  local mode_color jw_color docker_color vpn_color
  case "${HITSZ_STATUS_MODE}" in
    "校园直连") mode_color="${HITSZ_UI_GREEN}" ;;
    "校外 aTrust") mode_color="${HITSZ_UI_YELLOW}" ;;
    *) mode_color="${HITSZ_UI_RED}" ;;
  esac
  [[ "${HITSZ_STATUS_JW_CODE}" != "000" ]] && jw_color="${HITSZ_UI_GREEN}" || jw_color="${HITSZ_UI_RED}"
  [[ "${HITSZ_STATUS_DOCKER}" == "OFF" ]] && docker_color="${HITSZ_UI_MUTED}" || docker_color="${HITSZ_UI_YELLOW}"
  [[ "${HITSZ_STATUS_VPN}" == "CONNECTED" ]] && vpn_color="${HITSZ_UI_GREEN}" || vpn_color="${HITSZ_UI_MUTED}"

  local title mode jw_value docker_value vpn_value socks_value content
  title="$(gum style --bold --foreground "${HITSZ_UI_PURPLE}" 'HITSZ ACCESS')"
  mode="$(gum style --bold --foreground "${mode_color}" "● ${HITSZ_STATUS_MODE}")"
  jw_value="$(gum style --bold --foreground "${jw_color}" "HTTP ${HITSZ_STATUS_JW_CODE} · ${HITSZ_STATUS_POLICY}")"
  docker_value="$(gum style --foreground "${docker_color}" "${HITSZ_STATUS_DOCKER}${HITSZ_STATUS_USAGE:+ · ${HITSZ_STATUS_USAGE}}")"
  vpn_value="$(gum style --foreground "${vpn_color}" "${HITSZ_STATUS_VPN}")"
  socks_value="$(gum style --foreground "${docker_color}" "127.0.0.1:1080 · ${HITSZ_STATUS_SOCKS}")"

  content="$(
    printf '%s\n%s\n\n' "${title}" "${mode}"
    printf '  %-9s %s\n' 'JW' "${jw_value}"
    printf '  %-9s %s\n' 'Docker' "${docker_value}"
    printf '  %-9s %s\n' 'VPN' "${vpn_value}"
    printf '  %-9s %s\n' 'SOCKS' "${socks_value}"
  )"

  gum style --border rounded --border-foreground "${HITSZ_UI_PURPLE}" \
    --padding "1 2" "${content}"
  gum style --foreground "${HITSZ_UI_MUTED}" \
    '  hitsz up   校外启动    hitsz down   校内/关闭    hitsz   菜单'
}

hitsz_ui_show_vnc_credential() {
  local password="$1"
  if ! hitsz_ui_enabled; then
    printf 'noVNC password (127.0.0.1 only): %s\n' "${password}"
    return
  fi

  local title secret note content
  title="$(gum style --bold --foreground "${HITSZ_UI_YELLOW}" 'noVNC 自动鉴权')"
  secret="$(gum style --bold --foreground "${HITSZ_UI_GREEN}" "${password}")"
  note="$(gum style --foreground "${HITSZ_UI_MUTED}" '已自动交给 127.0.0.1 noVNC；下方仅作失败兜底')"
  content="$(printf '%s\n\n  兜底密码  %s\n  %s\n' "${title}" "${secret}" "${note}")"
  gum style --border rounded --border-foreground "${HITSZ_UI_YELLOW}" \
    --padding "1 2" "${content}"
}

hitsz_ui_confirm_login() {
  gum confirm --prompt.foreground "${HITSZ_UI_PURPLE}" \
    --selected.background "${HITSZ_UI_PURPLE}" \
    --affirmative '已登录，继续验证' --negative '稍后再说' \
    '请在 noVNC 中完成 aTrust 登录'
}

hitsz_ui_run_action() {
  local title="$1" script="$2" action="$3" log_file
  log_file="$(mktemp -t hitsz-ui.XXXXXX)"

  # shellcheck disable=SC2016 # $1-$3 belong to the child bash process.
  if gum spin --spinner dot --spinner.foreground "${HITSZ_UI_PURPLE}" \
      --title "${title}" -- /bin/bash -c '"$1" "$2" >"$3" 2>&1' \
      _ "${script}" "${action}" "${log_file}"; then
    rm -f "${log_file}"
    return 0
  fi

  gum log --level error '操作失败；底层日志如下'
  tail -30 "${log_file}" | sed -E \
    's/^(Password:).*/\1 <redacted; run hitsz login>/' >&2
  rm -f "${log_file}"
  return 1
}

hitsz_ui_choose_action() {
  local choice
  choice="$(gum choose --cursor.foreground "${HITSZ_UI_PURPLE}" \
    --header.foreground "${HITSZ_UI_PURPLE}" --header 'HITSZ 网络访问' \
    '查看状态' '校外：启动 aTrust' '登录：打开 noVNC' \
    '校内/不用：关闭 Docker')" || return 1
  case "${choice}" in
    '查看状态') printf 'status\n' ;;
    '校外：启动 aTrust') printf 'up\n' ;;
    '登录：打开 noVNC') printf 'login\n' ;;
    '校内/不用：关闭 Docker') printf 'down\n' ;;
  esac
}
