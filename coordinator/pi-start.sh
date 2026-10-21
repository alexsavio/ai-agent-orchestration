#!/usr/bin/env bash
# Starts a pi worker in an existing herdr pane: pi-start.sh <agent-name> <pane-id> <worker|smart> [extra pi args]
# The model comes from models.pi_worker or models.pi_smart (provider/model-id). A DeepSeek provider starts only in a repo
# whose personal .orchestration.local.toml sets pi.deepseek = true; a local provider (LM Studio) starts anywhere.
case ${ZSH_EVAL_CONTEXT:-} in *:file*) echo "run it, do not source it" >&2; return 1 ;; esac
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
. "$root/watchers/coord-lib.sh"

[ $# -ge 3 ] || { echo "usage: pi-start.sh <agent-name> <pane-id> <worker|smart> [extra pi args]" >&2; exit 2; }
name=$1 pane=$2 tier=$3
shift 3
case "$tier" in worker | smart) ;; *) echo "pi-start.sh: tier must be worker or smart, not '$tier'" >&2; exit 2 ;; esac
for arg in "$@"; do
  case "$arg" in
    --provider | --provider=* | --model | --model=* | --models | --models=* | *[Dd]eep[Ss]eek*)
      echo "pi-start.sh: '$arg' is not allowed in extra args; the provider and model come from the pi settings" >&2
      exit 2
      ;;
  esac
done
orch_need_cmd herdr jq

orch_load_config
setting=ORCH_PI_WORKER_MODEL
[ "$tier" = worker ] || setting=ORCH_PI_SMART_MODEL
model=${!setting:-}
case "$model" in "" | "<"*">") echo "pi-start.sh: pi is not configured; set models.pi_$tier ($setting) in $(orch_config_path)" >&2; exit 1 ;; esac
case "$model" in */?*) ;; *) echo "pi-start.sh: $setting must be provider/model-id, for example lmstudio/qwen/qwen3.6-35b-a3b" >&2; exit 1 ;; esac
provider=${model%%/*}
pi_model=${model#*/}

cwd=$(herdr pane get "$pane" | jq -er '.result.pane.cwd') || { echo "pi-start.sh: cannot read the directory of pane $pane" >&2; exit 1; }
# The opt-in comes from the repo files only; an exported ORCH_PI_DEEPSEEK must not grant it.
unset ORCH_PI_DEEPSEEK
orch_load_repo_config "$cwd"
if [ "$(printf '%s' "$provider" | tr '[:upper:]' '[:lower:]')" = deepseek ] && [ "${ORCH_PI_DEEPSEEK:-0}" != 1 ]; then
  echo "pi-start.sh: DeepSeek is off for $cwd; set pi.deepseek = true in the repo's .orchestration.local.toml to allow it" >&2
  exit 1
fi

exec herdr agent start "$name" --kind pi --pane "$pane" -- --provider "$provider" --model "$pi_model" "$@"
