#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2154 # Bats runs each test in a subshell and assigns status and output.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)
  SCRIPT="$ROOT/coordinator/cursor-start.sh"
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/cursor-start-bats.XXXXXX")
  export HOME="$TMP/home"
  export PATH="$TMP/bin:$PATH"
  export HERDR_CALLS="$TMP/herdr.calls"
  export ORCH_CONFIG="$TMP/orchestration.toml"
  unset ORCH_CURSOR_WORKER_MODEL ORCH_CURSOR_SMART_MODEL ORCH_PROVIDERS
  mkdir -p "$HOME" "$TMP/bin"
  printf '[models]\ncursor_worker = "grok-4.7-medium"\ncursor_smart = "grok-4.7-high"\n' >"$ORCH_CONFIG"
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

@test "worker tier starts cursor with --model and --trust" {
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 0 ]
  [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind cursor --pane pane1 -- --model grok-4.7-medium --trust" ]
}

@test "smart tier starts cursor with the smart model" {
  run "$SCRIPT" w1 pane1 smart
  [ "$status" -eq 0 ]
  [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind cursor --pane pane1 -- --model grok-4.7-high --trust" ]
}

@test "one set Cursor model serves both tiers" {
  printf '[models]\ncursor_worker = ""\ncursor_smart = "grok-4.7-high"\n' >"$ORCH_CONFIG"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 0 ]
  [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind cursor --pane pane1 -- --model grok-4.7-high --trust" ]
}

@test "an empty tier setting with no fallback means cursor is not configured" {
  printf '[models]\ncursor_worker = ""\ncursor_smart = ""\n' >"$ORCH_CONFIG"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 1 ]
  [[ "$output" == *"cursor is not configured"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
}

@test "extra args cannot change the model or trust" {
  for arg in --model --model=x --trust -f --force --yolo --resume --continue -pf -fw --approve-mcps --print --workspace --plugin-dir --unknown; do
    run "$SCRIPT" w1 pane1 worker "$arg"
    [ "$status" -eq 2 ]
    [[ "$output" == *"takes no extra arguments except --no-trust"* ]] || false
  done
  [ ! -e "$HERDR_CALLS" ]
}

@test "sandbox disabling is refused" {
  run "$SCRIPT" w1 pane1 worker --sandbox disabled
  [ "$status" -eq 2 ]
  [[ "$output" == *"takes no extra arguments except --no-trust"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
}

@test "no-trust leaves workspace trust under review for either tier" {
  for tier in worker smart; do
    run /bin/bash "$SCRIPT" w1 pane1 "$tier" --no-trust
    [ "$status" -eq 0 ]
    model=grok-4.7-medium
    [ "$tier" = worker ] || model=grok-4.7-high
    [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind cursor --pane pane1 -- --model $model" ]
    rm "$HERDR_CALLS"
  done
}

@test "no-trust does not allow additional arguments" {
  for arg in --no-trust --yolo -pf; do
    run "$SCRIPT" w1 pane1 worker --no-trust "$arg"
    [ "$status" -eq 2 ]
    [ ! -e "$HERDR_CALLS" ]
  done
}

@test "cursor left out of providers.enabled is refused" {
  printf '[providers]\nenabled = ["claude", "codex"]\n' >>"$ORCH_CONFIG"
  run "$SCRIPT" w1 p1 worker
  [ "$status" -eq 1 ]
  [[ "$output" == *"cursor is off; add \"cursor\" to providers.enabled (ORCH_PROVIDERS)"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
}

@test "empty providers.enabled turns cursor on when a model is set" {
  : >"$ORCH_CONFIG"
  printf '[models]\ncursor_worker = "grok-4.7-medium"\n' >"$ORCH_CONFIG"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 0 ]
  [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind cursor --pane pane1 -- --model grok-4.7-medium --trust" ]
}
