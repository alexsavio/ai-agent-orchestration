#!/usr/bin/env bats
# shellcheck disable=SC2154 # bats provides status and output after run.

@test "context segment includes remaining percentage and rounded used tokens" {
  run /bin/bash "$BATS_TEST_DIRNAME/../statusline-command.sh" <<'JSON'
{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"context_window":{"remaining_percentage":81,"current_usage":{"input_tokens":120000,"cache_creation_input_tokens":30000,"cache_read_input_tokens":40500}}}
JSON

  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed $'s/\033\\[[0-9;]*m//g')
  [[ "$plain" == *"81% 191k"* ]]
}
