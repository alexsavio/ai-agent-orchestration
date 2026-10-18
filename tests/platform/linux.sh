#!/usr/bin/env bash
run_isolated_tests() {
  local runtime mask path status=0 command
  local -a binds
  command -v bwrap >/dev/null || {
    printf 'bubblewrap is required for isolated Linux tests; install bubblewrap\n' >&2
    return 1
  }
  runtime=$(mktemp -d "${TMPDIR:-/tmp}/ao-test-runtime.XXXXXX") || return
  mask="$runtime/tripwire"
  cat >"$mask" <<'EOF'
#!/bin/sh
printf '%s\n' "$0 $*" >>"$AO_TEST_REACHED"
exit 1
EOF
  chmod 0755 "$mask"
  for path in /usr/bin/systemctl /bin/systemctl "$HOME/.local/bin/herdr" /usr/local/bin/herdr /opt/homebrew/bin/herdr; do
    [ -e "$path" ] && binds+=(--ro-bind "$mask" "$path")
  done
  path=$(command -v herdr 2>/dev/null || true)
  [ -z "$path" ] || binds+=(--ro-bind "$mask" "$path")
  command=${2:-"$1/tests/run-inner.sh"}
  AO_TEST_SANDBOX=linux AO_TEST_REACHED="$runtime/reached" XDG_RUNTIME_DIR="$runtime" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus" bwrap --dev-bind / / "${binds[@]}" /bin/bash "$command" || status=$?
  if [ -s "$runtime/reached" ]; then cat "$runtime/reached" >&2; status=1; fi
  rm -rf "$runtime"
  return "$status"
}
