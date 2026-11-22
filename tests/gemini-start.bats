#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2154 # Bats runs each test in a subshell and assigns status and output.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)
  SCRIPT="$ROOT/coordinator/gemini-start.sh"
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/gemini-start-bats.XXXXXX")
  export HOME="$TMP/home"
  export PATH="$TMP/bin:$PATH"
  export HERDR_CALLS="$TMP/herdr.calls"
  export ORCH_CONFIG="$TMP/orchestration.toml"
  unset ORCH_GEMINI_WORKER_MODEL ORCH_GEMINI_SMART_MODEL ORCH_PROVIDERS
  mkdir -p "$HOME" "$TMP/bin"
  printf '[models]\ngemini_worker = "gemini-3.8-flash-medium"\ngemini_smart = "gemini-3.8-flash-high"\n' >"$ORCH_CONFIG"
  cat >"$TMP/bin/herdr" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$HERDR_CALLS"
SH
  chmod +x "$TMP/bin/herdr"
  ln -s "$(command -v python3)" "$TMP/bin/python3"
}

teardown() {
  rm -rf "$TMP"
}

@test "worker tier starts agy with --model and --mode auto" {
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 0 ]
  [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind agy --pane pane1 -- --model gemini-3.8-flash-medium --mode auto" ]
}

@test "smart tier starts agy with the smart model" {
  run "$SCRIPT" w1 pane1 smart
  [ "$status" -eq 0 ]
  [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind agy --pane pane1 -- --model gemini-3.8-flash-high --mode auto" ]
}

@test "one set Gemini model serves both tiers" {
  printf '[models]\ngemini_worker = ""\ngemini_smart = "gemini-3.8-flash-high"\n' >"$ORCH_CONFIG"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 0 ]
  [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind agy --pane pane1 -- --model gemini-3.8-flash-high --mode auto" ]
}

@test "an empty tier setting with no fallback means gemini is not configured" {
  printf '[models]\ngemini_worker = ""\ngemini_smart = ""\n' >"$ORCH_CONFIG"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 1 ]
  [[ "$output" == *"gemini is not configured"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
}

@test "extra args cannot change the model or mode" {
  for arg in --model --model=x --mode --mode=plan --dangerously-skip-permissions --remote-agent --remote-control --sandbox --continue --conversation --settings --unknown; do
    run "$SCRIPT" w1 pane1 worker "$arg"
    [ "$status" -eq 2 ]
    [[ "$output" == *"takes no extra arguments"* ]] || false
  done
  [ ! -e "$HERDR_CALLS" ]
}

@test "sandbox and permission-bypass flags are refused" {
  run "$SCRIPT" w1 pane1 worker --dangerously-skip-permissions --remote-agent
  [ "$status" -eq 2 ]
  [[ "$output" == *"takes no extra arguments"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
}

@test "gemini left out of providers.enabled is refused" {
  printf '[providers]\nenabled = ["claude", "codex"]\n' >>"$ORCH_CONFIG"
  run "$SCRIPT" w1 p1 worker
  [ "$status" -eq 1 ]
  [[ "$output" == *"gemini is off; add \"gemini\" to providers.enabled (ORCH_PROVIDERS)"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
}

@test "empty providers.enabled turns gemini on when a model is set" {
  : >"$ORCH_CONFIG"
  printf '[models]\ngemini_worker = "gemini-3.8-flash-medium"\n' >"$ORCH_CONFIG"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 0 ]
  [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind agy --pane pane1 -- --model gemini-3.8-flash-medium --mode auto" ]
}
