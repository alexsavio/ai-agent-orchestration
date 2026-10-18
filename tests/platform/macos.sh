#!/usr/bin/env bash
run_isolated_tests() {
  local profile path status=0
  local -a paths
  profile=$(mktemp "${TMPDIR:-/tmp}/ao-test-sandbox.XXXXXX") || return
  paths=(/bin/launchctl /usr/bin/systemctl "$HOME/.local/bin/herdr" /usr/local/bin/herdr /opt/homebrew/bin/herdr)
  path=$(command -v herdr 2>/dev/null || true)
  [ -z "$path" ] || paths+=("$path")
  printf '(version 1)(allow default)\n' >"$profile"
  for path in "${paths[@]}"; do
    # JSON quoting also escapes literal paths in the sandbox profile.
    printf '(deny process-exec (literal %s))\n' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$path")" >>"$profile"
  done
  AO_TEST_SANDBOX=macos sandbox-exec -f "$profile" /bin/bash "${2:-"$1/tests/run-inner.sh"}" || status=$?
  rm -f "$profile"
  return "$status"
}
