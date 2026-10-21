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
  for arg in --provider --model=x --models deepseek/x DEEPSEEK/X; do
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

@test "a tracked .orchestration.local.toml does not opt in" {
  printf '[pi]\ndeepseek = true\n' >"$TMP/repo/.orchestration.local.toml"
  git -C "$TMP/repo" add -f .orchestration.local.toml
  run "$SCRIPT" w1 pane1 smart
  [ "$status" -eq 1 ]
  [[ "$output" == *"DeepSeek is off"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
}

@test "an exported GIT_DIR cannot point the opt-in at another repo" {
  git init -q "$TMP/opted"
  printf '[pi]\ndeepseek = true\n' >"$TMP/opted/.orchestration.local.toml"
  GIT_DIR="$TMP/opted/.git" run "$SCRIPT" w1 pane1 smart
  [ "$status" -eq 1 ]
  [ ! -e "$HERDR_CALLS" ]
}

@test "DeepSeek named in the model id of another provider needs the opt-in" {
  printf '[models]\npi_worker = "openrouter/DeepSeek/deepseek-v4-pro"\n' >"$ORCH_CONFIG"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 1 ]
  [[ "$output" == *"DeepSeek is off"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
  printf '[pi]\ndeepseek = true\n' >"$TMP/repo/.orchestration.local.toml"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 0 ]
}

@test "an empty provider is refused" {
  printf '[models]\npi_worker = "/deepseek-v4-pro"\n' >"$ORCH_CONFIG"
  run "$SCRIPT" w1 pane1 worker
  [ "$status" -eq 1 ]
  [[ "$output" == *"provider/model-id"* ]] || false
  [ ! -e "$HERDR_CALLS" ]
}

@test "the refusal tells the session not to edit the file" {
  run "$SCRIPT" w1 pane1 smart
  [[ "$output" == *"Only the user can opt a repo in"* ]] || false
  [[ "$output" == *"Ask the user; do not edit the file."* ]] || false
}

@test "extra args cannot load extensions, keys or old sessions" {
  for arg in -e --extension --extension=x --api-key --session --fork --resume --continue -r -c; do
    run "$SCRIPT" w1 pane1 worker "$arg"
    [ "$status" -eq 2 ]
  done
  [ ! -e "$HERDR_CALLS" ]
}
