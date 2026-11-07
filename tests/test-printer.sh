#!/bin/bash
set -euo pipefail
TEST_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/printer.sh
source "${TEST_ROOT}/lib/printer.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
SITE_ID=hitsz SITE_SOCKS_HOST=127.0.0.1 SITE_SOCKS_PORT=1080
managed=0 listening=0 upstream=200 starts=0
hitsz_printer_plist() { printf '%s/service.plist\n' "${TMP}"; }
hitsz_printer_service() { printf 'gui/100/test-printer\n'; }
lpstat() { printf 'device for M280nw_aTrust: ipp://127.0.0.1:8631/ipp/print\n'; }
socat() { :; }
mkdir() { :; } # Test directory exists; do not touch the host's Logs directory.
launchctl() {
  case "$1" in
    print) [[ "${managed}" == 1 ]] ;;
    bootstrap) managed=1; listening=1; starts=$((starts + 1)) ;;
    bootout) managed=0; listening=0 ;;
    *) return 1 ;;
  esac
}
nc() { [[ "${listening}" == 1 ]]; }
curl() { printf '%s' "${upstream}"; }
hitsz_printer_start
[[ "${starts}" == 1 ]]
hitsz_printer_start
[[ "${starts}" == 1 ]] # Idempotent, never restart an active print connection.
python3 - "${TMP}/service.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    p = plistlib.load(f)
assert p['KeepAlive'] and p['RunAtLoad']
assert p['ProgramArguments'][1] == 'TCP-LISTEN:8631,bind=127.0.0.1,reuseaddr,fork'
assert p['ProgramArguments'][2] == 'SOCKS5-CONNECT:127.0.0.1:1080:10.249.42.42:631'
PY
[[ "$(hitsz_printer_status)" == READY* ]]
upstream=000
[[ "$(hitsz_printer_status)" == UNREACHABLE* ]]
hitsz_printer_stop
[[ "${managed}" == 0 && ! -e "${TMP}/service.plist" ]]
[[ "$(hitsz_printer_status)" == OFF* ]]
listening=1
if hitsz_printer_start 2>/dev/null; then
  echo 'FAIL: adopted an unmanaged listener' >&2; exit 1
fi
[[ "${starts}" == 1 ]]
HITSZ_PRINTER_DISABLED=1
hitsz_printer_start
[[ "${starts}" == 1 ]]
echo 'PASS: printer supervision, idempotency, health, shutdown, port ownership, opt-out'
