#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
. "$root/coord-lib.sh"
orch_load_config
orch_export_config
failed=0
for mode in context workers hog balance host audit todo; do
  if ! "${ORCH_PYTHON3:-python3}" "$root/watchers.py" "$mode" "$@"; then
    printf '%s check failed\n' "$mode" >&2
    failed=1
  fi
done
exit "$failed"
