#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
. "$root/coord-lib.sh"
orch_load_config
orch_export_config
state="${1:?state directory required}"
"$root/coord-check.sh" --state-dir "$state"
# Dry-run preview only. Owner must explicitly enable delivery later.
exec "${ORCH_PYTHON3:-python3}" "$root/notify-inbox.py" --state-dir "$state" --cursor "$state/preview.cursor" --modes context workers hog balance host audit todo
