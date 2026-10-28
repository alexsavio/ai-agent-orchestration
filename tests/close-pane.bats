#!/usr/bin/env bats
# shellcheck disable=SC2154 # bats provides status and output after run.

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/ao-close-pane.XXXXXX")
  BIN="$TMP/bin" FX="$TMP/fx"
  mkdir -p "$BIN" "$FX" "$TMP/home/.claude/context-usage"
  : >"$TMP/none.toml"
  LEDGER="$TMP/home/.claude/coordinator/usage-ledger.tsv"
  cat >"$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HERDR_CALLS"
key=${3//:/_}
case "$1 $2" in
  'agent get')
    [ -z "${HERDR_SLOW:-}" ] || exec sleep "$HERDR_SLOW"
    if [ -n "${HERDR_NO_AGENT:-}" ]; then
      printf '{"id":"cli:agent:get","error":{"code":"agent_not_found","message":"no agent in pane"}}\n'
      exit 1
    fi
    [ -z "${HERDR_LOOKUP_FAIL:-}" ] && cat "$FX/agent-$key.json" ;;
  'workspace get') cat "$FX/ws-$key.json" ;;
  'pane close') [ -z "${HERDR_CLOSE_FAIL:-}" ] ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$BIN/herdr"
  python_bin=$(command -v python3)
  export HOME="$TMP/home" FX HERDR_CALLS="$TMP/herdr.calls" HERDR_BIN_PATH="$BIN/herdr" ORCH_CONFIG="$TMP/none.toml" \
    ORCH_CLOSED_DIR="$TMP/closed" ORCH_PYTHON3="$python_bin"
  printf '{"result":{"agent":{"pane_id":"wW:p1","name":"fix-it","workspace_id":"wW","agent_session":{"agent":"claude","value":"sess-1"}}}}\n' >"$FX/agent-wW_p1.json"
  printf '{"result":{"workspace":{"workspace_id":"wW","label":"fix the thing","tokens":{"owner":"wA"}}}}\n' >"$FX/ws-wW.json"
  printf '{"model":"claude-sonnet-5-5","cost_usd":1.5}\n' >"$HOME/.claude/context-usage/sess-1.usage"
}

teardown() {
  rm -rf "$TMP"
}

close_pane() {
  run "$ROOT/coordinator/watchers/close-pane.sh" "$@"
}

@test "a close appends one ledger line with the right columns and a header" {
  close_pane wW:p1
  [ "$status" -eq 0 ]
  grep -qx 'pane close wW:p1' "$HERDR_CALLS"
  [ "$(wc -l <"$LEDGER")" -eq 2 ]
  [ "$(sed -n 1p "$LEDGER")" = $'closed_at\towner\tworkspace_label\tagent_name\tpane\tsession_id\tmodel\tcost_usd' ]
  line=$(sed -n 2p "$LEDGER")
  IFS=$'\t' read -r at owner label name pane sid model cost <<<"$line"
  [[ "$at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}$ ]] || return 1
  [ "$owner|$label|$name|$pane|$sid|$model|$cost" = "wA|fix the thing|fix-it|wW:p1|sess-1|claude-sonnet-5-5|1.5" ]
}

@test "the header is written once" {
  close_pane wW:p1
  close_pane wW:p1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^closed_at' "$LEDGER")" -eq 1 ]
  [ "$(wc -l <"$LEDGER")" -eq 3 ]
}

@test "a missing usage file leaves model and cost empty" {
  rm "$HOME/.claude/context-usage/sess-1.usage"
  close_pane wW:p1
  [ "$status" -eq 0 ]
  [[ "$(sed -n 2p "$LEDGER")" == *$'\tsess-1\t\t' ]] || return 1
}

@test "a failed lookup warns, writes no line, still closes, and keeps the exit code" {
  HERDR_LOOKUP_FAIL=1 close_pane wW:p1
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: usage ledger line not written: "* ]] || return 1
  [ ! -e "$LEDGER" ]
  grep -qx 'pane close wW:p1' "$HERDR_CALLS"
  [ -f "$ORCH_CLOSED_DIR/wW:p1" ]
}

@test "a failed ledger write warns and the close still runs" {
  mkdir -p "$HOME/.claude/coordinator"
  mkdir "$LEDGER"
  close_pane wW:p1
  [ "$status" -eq 0 ]
  [[ "$output" == *warning* ]] || return 1
  grep -qx 'pane close wW:p1' "$HERDR_CALLS"
}

@test "a failed close still exits 1, removes the marker and writes no ledger row" {
  HERDR_CLOSE_FAIL=1 close_pane wW:p1
  [ "$status" -eq 1 ]
  [ ! -e "$ORCH_CLOSED_DIR/wW:p1" ]
  [ ! -e "$LEDGER" ]
}

@test "a pane with no agent gets no line and no warning (real agent_not_found reply)" {
  HERDR_NO_AGENT=1 close_pane wW:p1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$LEDGER" ]
  grep -qx 'pane close wW:p1' "$HERDR_CALLS"
}

@test "a missing ledger helper warns and the close still runs" {
  mkdir -p "$TMP/repo/coordinator/watchers" "$TMP/repo/lib"
  /bin/cp "$ROOT/coordinator/watchers/close-pane.sh" "$ROOT/coordinator/watchers/coord-lib.sh" "$TMP/repo/coordinator/watchers/"
  /bin/cp "$ROOT/lib/orch_settings.py" "$TMP/repo/lib/"
  run "$TMP/repo/coordinator/watchers/close-pane.sh" wW:p1
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: usage ledger line not written for wW:p1"* ]] || return 1
  grep -qx 'pane close wW:p1' "$HERDR_CALLS"
}

@test "a slow herdr lookup is cut off: the pane still closes, the exit code and the marker are unchanged" {
  start=$SECONDS
  HERDR_SLOW=30 close_pane wW:p1
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -lt 20 ]
  [[ "$output" == *"warning: usage ledger line not written: "* ]] || return 1
  [ ! -e "$LEDGER" ]
  grep -qx 'pane close wW:p1' "$HERDR_CALLS"
  [ -f "$ORCH_CLOSED_DIR/wW:p1" ]
}

@test "a label with a tab and a newline stays one 8-column row" {
  printf '{"result":{"workspace":{"workspace_id":"wW","label":"tab\\there\\nnewline","tokens":{"owner":"wA"}}}}\n' >"$FX/ws-wW.json"
  close_pane wW:p1
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$LEDGER")" -eq 2 ]
  [ "$(awk -F'\t' 'NR == 2 { print NF }' "$LEDGER")" -eq 8 ]
}

# A python3 stand-in: PY_FAIL=append fails the --append call, PY_FAIL=read prints half a row and fails the read.
fake_python() {
  cat >"$BIN/py" <<'PY'
#!/usr/bin/env bash
mode=read
for a in "$@"; do
  case "$a" in
    --append) mode=append ;;
  esac
done
for a in "$@"; do
  case "$a" in
    */usage_ledger.py)
      [ "$mode $PY_FAIL" != "append append" ] || exit 9
      [ "$mode $PY_FAIL" != "read read" ] || { printf 'partial\tcell\n'; exit 9; }
      ;;
  esac
done
exec "$REAL_PY" "$@"
PY
  chmod +x "$BIN/py"
  export REAL_PY="$python_bin" ORCH_PYTHON3="$BIN/py"
}

@test "a failed ledger append warns, the close still exits 0, and the pane was closed" {
  fake_python
  export PY_FAIL=append
  close_pane wW:p1
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: usage ledger line not written for wW:p1"* ]] || return 1
  grep -qx 'pane close wW:p1' "$HERDR_CALLS"
}

@test "a failed ledger read drops its partial row: nothing is appended" {
  fake_python
  export PY_FAIL=read
  close_pane wW:p1
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning: usage ledger line not written for wW:p1"* ]] || return 1
  [ ! -e "$LEDGER" ]
  grep -qx 'pane close wW:p1' "$HERDR_CALLS"
}

@test "an unwritable stderr does not stop the close after a failed ledger read" {
  HERDR_LOOKUP_FAIL=1 run bash -c '"$1" wW:p1 2>&-' _ "$ROOT/coordinator/watchers/close-pane.sh"
  [ "$status" -eq 0 ]
  grep -qx 'pane close wW:p1' "$HERDR_CALLS"
}

@test "an unwritable stderr does not turn a good close into a failure after a failed ledger append" {
  fake_python
  export PY_FAIL=append
  run bash -c '"$1" wW:p1 2>&-' _ "$ROOT/coordinator/watchers/close-pane.sh"
  [ "$status" -eq 0 ]
  grep -qx 'pane close wW:p1' "$HERDR_CALLS"
}
