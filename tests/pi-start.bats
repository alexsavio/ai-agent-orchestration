#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2154 # Bats runs each test in a subshell and assigns status and output.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)
  SCRIPT="$ROOT/coordinator/pi-start.sh"
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/pi-start-bats.XXXXXX")
  export HOME="$TMP/home"
  export PATH="$TMP/bin:$PATH"
  export HERDR_CALLS="$TMP/herdr.calls"
  export ORCH_CONFIG="$TMP/orchestration.toml"
  unset ORCH_PI_WORKER_MODEL ORCH_PI_SMART_MODEL ORCH_PI_DEEPSEEK
  mkdir -p "$HOME" "$TMP/bin" "$TMP/repo"
  git -C "$TMP/repo" init -q
  git -C "$TMP/repo" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
  git -C "$TMP/repo" worktree add -q -b side "$TMP/side"
  printf '[models]\npi_worker = "lmstudio/qwen/qwen3.6-35b-a3b"\npi_smart = "deepseek/some-model"\n' >"$ORCH_CONFIG"
  export PANE_CWD="$TMP/repo"
  # The fake herdr answers pane get with PANE_CWD and records every other call.
  cat >"$TMP/bin/herdr" <<'SH'
#!/bin/sh
if [ "$1 $2" = "pane get" ]; then
  printf '{"result":{"pane":{"cwd":"%s"}}}\n' "$PANE_CWD"
else
  printf '%s\n' "$*" >>"$HERDR_CALLS"
fi
SH
  chmod +x "$TMP/bin/herdr"
}

teardown() {
  rm -rf "$TMP"
}

@test "a local provider starts in any repo with the provider and model split" {
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 0 ]
  [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind pi --pane pane1 -- --provider lmstudio --model qwen/qwen3.6-35b-a3b" ]
}

@test "DeepSeek is refused in a repo that did not opt in" {
  run "$SCRIPT" w1 pane1 smart
  [ "$status" -eq 1 ]
  [[ "$output" == *"DeepSeek is off"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
}

@test "DeepSeek starts in a repo whose local file opts in" {
  printf '[pi]\ndeepseek = true\n' >"$TMP/repo/.orchestration.local.toml"
  run "$SCRIPT" w1 pane1 smart
  [ "$status" -eq 0 ]
  [ "$(cat "$HERDR_CALLS")" = "agent start w1 --kind pi --pane pane1 -- --provider deepseek --model some-model" ]
}

@test "a committed pi.deepseek does not opt in" {
  printf '[pi]\ndeepseek = true\n' >"$TMP/repo/.orchestration.toml"
  run "$SCRIPT" w1 pane1 smart
  [ "$status" -eq 1 ]
  [ ! -e "$HERDR_CALLS" ]
}

@test "an exported ORCH_PI_DEEPSEEK does not opt in" {
  ORCH_PI_DEEPSEEK=1 run "$SCRIPT" w1 pane1 smart
  [ "$status" -eq 1 ]
  [ ! -e "$HERDR_CALLS" ]
}

@test "a linked worktree uses the opt-in of its main checkout" {
  printf '[pi]\ndeepseek = true\n' >"$TMP/repo/.orchestration.local.toml"
  PANE_CWD="$TMP/side" run "$SCRIPT" w1 pane1 smart
  [ "$status" -eq 0 ]
  [[ "$(cat "$HERDR_CALLS")" == *"--provider deepseek"* ]] || false
}

@test "an empty tier setting means pi is not configured" {
  printf '[models]\npi_worker = ""\n' >"$ORCH_CONFIG"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 1 ]
  [[ "$output" == *"pi is not configured"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
}

@test "extra args cannot change the provider or name DeepSeek" {
  for arg in --provider --model=x --models deepseek/x; do
    run "$SCRIPT" w1 pane1 worker "$arg"
    [ "$status" -eq 2 ]
  done
  [ ! -e "$HERDR_CALLS" ]
}

@test "other extra args pass through" {
  run "$SCRIPT" w1 pane1 worker --thinking low
  [ "$status" -eq 0 ]
  [[ "$(cat "$HERDR_CALLS")" == *"--model qwen/qwen3.6-35b-a3b --thinking low" ]] || false
}

@test "a model without a provider prefix and a bad tier are refused" {
  printf '[models]\npi_worker = "qwen-only"\n' >"$ORCH_CONFIG"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 1 ]
  run "$SCRIPT" w1 pane1 big
  [ "$status" -eq 2 ]
}
