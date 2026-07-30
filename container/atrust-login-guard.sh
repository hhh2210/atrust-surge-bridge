#!/bin/bash

# Sourced by atrust-browser-control while it holds the lifecycle flock.

atrust_window_metadata_matches() {
  local window="$1"
  local reference_width="${ATRUST_LOGIN_REFERENCE_WIDTH:-921}"
  local reference_height="${ATRUST_LOGIN_REFERENCE_HEIGHT:-570}"
  local size_tolerance="${ATRUST_LOGIN_SIZE_TOLERANCE:-2}"
  local geometry width height width_delta height_delta
  local wm_class wm_pid executable map_state

  [[ "${size_tolerance}" =~ ^[0-9]+$ ]] || size_tolerance=2
  geometry="$(xdotool getwindowgeometry --shell "${window}" 2>/dev/null || true)"
  width="$(printf '%s\n' "${geometry}" | sed -n 's/^WIDTH=//p')"
  height="$(printf '%s\n' "${geometry}" | sed -n 's/^HEIGHT=//p')"
  [[ "${width}" =~ ^[0-9]+$ && "${height}" =~ ^[0-9]+$ ]] || return 1
  width_delta=$((width - reference_width))
  height_delta=$((height - reference_height))
  ((width_delta < 0)) && width_delta=$((-width_delta))
  ((height_delta < 0)) && height_delta=$((-height_delta))
  [[ "${width_delta}" -le "${size_tolerance}" ]] || return 1
  [[ "${height_delta}" -le "${size_tolerance}" ]] || return 1

  wm_class="$(xprop -id "${window}" WM_CLASS 2>/dev/null || true)"
  [[ "${wm_class}" == *'"atrusttray", "aTrustTray"'* ]] || return 1
  wm_pid="$(xprop -id "${window}" _NET_WM_PID 2>/dev/null | sed -n 's/.* = //p')"
  [[ "${wm_pid}" =~ ^[0-9]+$ ]] || return 1
  executable="$(readlink -f "/proc/${wm_pid}/exe" 2>/dev/null || true)"
  [[ "${executable}" == '/usr/share/sangfor/aTrust/aTrustTray' ]] || return 1
  map_state="$(xwininfo -id "${window}" 2>/dev/null |
    sed -n 's/^[[:space:]]*Map State: //p')"
  [[ "${map_state}" == 'IsViewable' ]] || return 1

  ATRUST_WINDOW_WIDTH="${width}"
  ATRUST_WINDOW_HEIGHT="${height}"
}

atrust_find_login_target() {
  local wait_seconds="${ATRUST_CLICK_WAIT_SECONDS:-20}"
  local max_ocr_attempts="${ATRUST_LOGIN_MAX_OCR_ATTEMPTS:-3}"
  local reference_width="${ATRUST_LOGIN_REFERENCE_WIDTH:-921}"
  local reference_height="${ATRUST_LOGIN_REFERENCE_HEIGHT:-570}"
  local base_x="${ATRUST_LOGIN_BUTTON_X:-706}"
  local base_y="${ATRUST_LOGIN_BUTTON_Y:-357}"
  local base_crop_x="${ATRUST_LOGIN_CROP_X:-536}"
  local base_crop_y="${ATRUST_LOGIN_CROP_Y:-336}"
  local base_crop_width="${ATRUST_LOGIN_CROP_WIDTH:-340}"
  local base_crop_height="${ATRUST_LOGIN_CROP_HEIGHT:-40}"
  local attempt ocr_attempts=0 window
  local click_x click_y crop_x crop_y crop_width crop_height
  local screenshot button_region ocr
  local -a candidates=()

  [[ "${wait_seconds}" =~ ^[1-9][0-9]*$ ]] || wait_seconds=20
  [[ "${max_ocr_attempts}" =~ ^[1-9][0-9]*$ ]] || max_ocr_attempts=3
  for ((attempt = 1; attempt <= wait_seconds; attempt++)); do
    candidates=()
    while IFS= read -r window; do
      [[ -n "${window}" ]] || continue
      atrust_window_metadata_matches "${window}" || continue
      candidates+=("${window}")
    done < <(xdotool search --onlyvisible --name '^aTrust$' 2>/dev/null || true)

    if [[ "${#candidates[@]}" -ne 1 ]]; then
      sleep 1
      continue
    fi

    window="${candidates[0]}"
    atrust_window_metadata_matches "${window}" || continue
    click_x=$((base_x * ATRUST_WINDOW_WIDTH / reference_width))
    click_y=$((base_y * ATRUST_WINDOW_HEIGHT / reference_height))
    crop_x=$((base_crop_x * ATRUST_WINDOW_WIDTH / reference_width))
    crop_y=$((base_crop_y * ATRUST_WINDOW_HEIGHT / reference_height))
    crop_width=$((base_crop_width * ATRUST_WINDOW_WIDTH / reference_width))
    crop_height=$((base_crop_height * ATRUST_WINDOW_HEIGHT / reference_height))
    screenshot="$(mktemp /tmp/atrust-login-window.XXXXXX.png)"
    button_region="$(mktemp /tmp/atrust-login-button.XXXXXX.png)"

    if import -silent -window "${window}" "${screenshot}" 2>/dev/null &&
      convert "${screenshot}" \
        -crop "${crop_width}x${crop_height}+${crop_x}+${crop_y}" +repage \
        -colorspace Gray -negate -threshold 50% -resize 300% \
        "${button_region}" 2>/dev/null; then
      ocr="$(tesseract "${button_region}" stdout --psm 6 -l eng 2>/dev/null || true)"
    else
      ocr=""
    fi
    rm -f "${screenshot}" "${button_region}"

    if [[ "${ocr}" =~ [Ll]og[[:space:]]*[Ii]n ]]; then
      # These globals are the guard's return values for the sourcing controller.
      # shellcheck disable=SC2034
      ATRUST_VERIFIED_WINDOW="${window}"
      # shellcheck disable=SC2034
      ATRUST_VERIFIED_CLICK_X="${click_x}"
      # shellcheck disable=SC2034
      ATRUST_VERIFIED_CLICK_Y="${click_y}"
      return 0
    fi

    ocr_attempts=$((ocr_attempts + 1))
    if [[ "${ocr_attempts}" -ge "${max_ocr_attempts}" ]]; then
      printf 'The expected Log In label was not verified after %s OCR samples.\n' \
        "${ocr_attempts}" >&2
      return 1
    fi
    sleep 1
  done

  printf 'No uniquely verified aTrust Log In window was found after %ss.\n' \
    "${wait_seconds}" >&2
  return 1
}
