#!/bin/bash
ROOT_DIR="$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)"
"${ROOT_DIR}/bin/hitsz" status
status=$?
printf '\nPress Return to close this window...'
read -r _
exit "${status}"
