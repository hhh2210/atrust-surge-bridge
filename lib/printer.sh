#!/bin/bash

# The optional HITSZ CUPS queue uses a loopback IPP forward, not Surge routing.
# launchd owns it so closing a CLI session cannot strand queued print jobs.
HITSZ_PRINTER_LABEL="com.hitsz.atrust-printer"
HITSZ_PRINTER_QUEUE="M280nw_aTrust"
HITSZ_PRINTER_PORT=8631
HITSZ_PRINTER_TARGET="10.249.42.42"

hitsz_printer_plist() {
  printf '%s/Library/LaunchAgents/%s.plist\n' "${HOME}" "${HITSZ_PRINTER_LABEL}"
}

hitsz_printer_service() {
  printf 'gui/%s/%s\n' "$(id -u)" "${HITSZ_PRINTER_LABEL}"
}

hitsz_printer_enabled() {
  [[ "${HITSZ_PRINTER_DISABLED:-0}" != 1 && "${SITE_ID:-}" == hitsz ]] &&
    command -v launchctl >/dev/null 2>&1 &&
    lpstat -v "${HITSZ_PRINTER_QUEUE}" 2>/dev/null |
      grep -q "ipp://127.0.0.1:${HITSZ_PRINTER_PORT}/ipp/print"
}

hitsz_printer_start() {
  hitsz_printer_enabled || return 0
  local plist socat_bin log_dir _
  plist="$(hitsz_printer_plist)"
  if ! launchctl print "$(hitsz_printer_service)" >/dev/null 2>&1; then
    if nc -z -w 1 127.0.0.1 "${HITSZ_PRINTER_PORT}" >/dev/null 2>&1; then
      printf 'Printer: port %s is occupied by an unmanaged process; refusing to replace it.\n' "${HITSZ_PRINTER_PORT}" >&2
      return 1
    fi
    socat_bin="$(command -v socat)" || {
      printf 'Printer: socat is required for the configured CUPS queue.\n' >&2
      return 1
    }
    log_dir="${HOME}/Library/Logs/hitsz"
    mkdir -p "$(dirname "${plist}")" "${log_dir}"
    # plistlib escapes paths correctly, including spaces and XML characters.
    python3 - "${plist}" "${HITSZ_PRINTER_LABEL}" "${socat_bin}" \
      "${HITSZ_PRINTER_PORT}" "${SITE_SOCKS_HOST}" "${SITE_SOCKS_PORT}" \
      "${HITSZ_PRINTER_TARGET}" "${log_dir}" <<'PY'
import os, plistlib, sys
path, label, binary, port, socks_host, socks_port, target, logs = sys.argv[1:]
data = {'Label': label,
        'ProgramArguments': [binary, f'TCP-LISTEN:{port},bind=127.0.0.1,reuseaddr,fork',
                             f'SOCKS5-CONNECT:{socks_host}:{socks_port}:{target}:631'],
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 5,
        'StandardErrorPath': os.path.join(logs, 'printer.log')}
with open(path + '.tmp', 'wb') as f:
    plistlib.dump(data, f)
os.chmod(path + '.tmp', 0o600)
os.replace(path + '.tmp', path)
PY
    launchctl bootstrap "gui/$(id -u)" "${plist}" || return 1
  fi
  for _ in 1 2 3 4 5; do
    if nc -z -w 1 127.0.0.1 "${HITSZ_PRINTER_PORT}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  printf 'Printer: managed forward has not opened port %s; check ~/Library/Logs/hitsz/printer.log.\n' "${HITSZ_PRINTER_PORT}" >&2
  return 1
}

hitsz_printer_stop() {
  local plist
  plist="$(hitsz_printer_plist)"
  if command -v launchctl >/dev/null 2>&1 &&
      launchctl print "$(hitsz_printer_service)" >/dev/null 2>&1; then
    launchctl bootout "$(hitsz_printer_service)" || return 1
  fi
  # Removing registration prevents a deliberately stopped forward returning at login.
  rm -f "${plist}"
}

hitsz_printer_status() {
  hitsz_printer_enabled || { printf 'NOT CONFIGURED\n'; return 0; }
  if ! launchctl print "$(hitsz_printer_service)" >/dev/null 2>&1; then
    printf 'OFF (run hitsz printer up)\n'
    return 0
  fi
  if ! nc -z -w 1 127.0.0.1 "${HITSZ_PRINTER_PORT}" >/dev/null 2>&1; then
    printf 'STARTING (managed; port %s closed)\n' "${HITSZ_PRINTER_PORT}"
    return 0
  fi
  local code
  code="$(curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' \
    --connect-timeout 1 --max-time 3 "http://127.0.0.1:${HITSZ_PRINTER_PORT}/" || true)"
  if [[ "${code}" =~ ^[1-5][0-9][0-9]$ ]]; then
    printf 'READY (managed; 127.0.0.1:%s → %s:631)\n' "${HITSZ_PRINTER_PORT}" "${HITSZ_PRINTER_TARGET}"
  else
    printf 'UNREACHABLE (forward listening; check VPN/printer)\n'
  fi
}
