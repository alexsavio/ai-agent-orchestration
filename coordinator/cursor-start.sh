#!/usr/bin/env bash
# Starts a Cursor CLI worker in an existing herdr pane:
#   cursor-start.sh <agent-name> <pane-id> <worker|smart> [--no-trust]
# The model comes from models.cursor_worker or models.cursor_smart (Cursor CLI model ids, e.g. grok-4.7-medium).
# --no-trust leaves workspace trust prompts enabled for foreign PR reviews.
case ${ZSH_EVAL_CONTEXT:-} in *:file*) echo "run it, do not source it" >&2; return 1 ;; esac
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
. "$root/watchers/coord-lib.sh"

[ $# -ge 3 ] || { echo "usage: cursor-start.sh <agent-name> <pane-id> <worker|smart> [--no-trust]" >&2; exit 2; }
name=$1 pane=$2 tier=$3
shift 3
case "$tier" in worker | smart) ;; *) echo "cursor-start.sh: tier must be worker or smart, not '$tier'" >&2; exit 2 ;; esac
trust=(--trust)
if [ $# -gt 0 ]; then
  if [ $# -eq 1 ] && [ "$1" = --no-trust ]; then
    trust=()
  else
    echo "cursor-start.sh: takes no extra arguments except --no-trust" >&2
    exit 2
  fi
fi

orch_load_config
setting=ORCH_CURSOR_WORKER_MODEL
[ "$tier" = worker ] || setting=ORCH_CURSOR_SMART_MODEL
# One Cursor model serves both tiers (same rule as Codex).
model=${!setting:-}
case "$model" in "" | "<"*">")
  other=ORCH_CURSOR_SMART_MODEL
  [ "$tier" = worker ] || other=ORCH_CURSOR_WORKER_MODEL
  model=${!other:-}
  ;;
esac
not_configured="cursor-start.sh: cursor is not configured; set models.cursor_worker or models.cursor_smart (ORCH_CURSOR_WORKER_MODEL, ORCH_CURSOR_SMART_MODEL) in $(orch_config_path)"
if ! orch_provider_enabled cursor; then
  [ -z "${ORCH_PROVIDERS:-}" ] || { echo "cursor-start.sh: cursor is off; add \"cursor\" to providers.enabled (ORCH_PROVIDERS) in $(orch_config_path)" >&2; exit 1; }
  echo "$not_configured" >&2
  exit 1
fi
case "$model" in "" | "<"*">") echo "$not_configured" >&2; exit 1 ;; esac

herdr_bin=${ORCH_HERDR_BIN:-herdr}
orch_need_cmd "$herdr_bin"

exec "$herdr_bin" agent start "$name" --kind cursor --pane "$pane" -- --model "$model" ${trust[@]+"${trust[@]}"}
