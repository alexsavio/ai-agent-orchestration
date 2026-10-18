#!/usr/bin/env bash
# Bats suite setup protects test execution, including helper-free files.

setup_suite() {
  [ "${AO_TEST_SANDBOX:-}" ] || { printf 'Run tests through tests/run.sh\n' >&2; return 1; }
  export BATS_SERVICE_STUB_BIN="$BATS_SUITE_TMPDIR/service-stubs"
  export BATS_SERVICE_STUB_SOURCE="$BATS_SERVICE_STUB_BIN"
  mkdir -p "$BATS_SERVICE_STUB_BIN"
  for tool in launchctl systemctl; do
    cat >"$BATS_SERVICE_STUB_BIN/$tool" <<'EOF'
#!/usr/bin/env bash
case "${0##*/}" in
  launchctl)
    printf '%s\n' "$*" >>"${LAUNCHCTL_CALLS:?}"
    if [ -n "${LAUNCHCTL_STATE:-}" ]; then
      touch "$LAUNCHCTL_STATE"
      case "$1" in
        print) grep -qxF "${2##*/}" "$LAUNCHCTL_STATE" ;;
        kickstart) [ -z "${LAUNCHCTL_KICKSTART_FAIL:-}" ] ;;
        bootstrap) label=${3##*/} && printf '%s\n' "${label%.plist}" >>"$LAUNCHCTL_STATE" ;;
        bootout)
          [ "${2##*/}" != "${LAUNCHCTL_STUCK:-}" ] || exit 1
          grep -vxF "${2##*/}" "$LAUNCHCTL_STATE" >"$LAUNCHCTL_STATE.new" || true
          mv "$LAUNCHCTL_STATE.new" "$LAUNCHCTL_STATE"
          ;;
      esac
      exit
    fi
    [ -z "${LAUNCHCTL_NOT_LOADED:-}" ] || exit 1
    case "$1 ${2:-}" in
      'print gui/'*) case "${2:-}" in *inbox*) [ -z "${LAUNCHCTL_CONTEXT_ONLY:-}" ;; *) exit 0 ;; esac ;;
      *) exit 0 ;;
    esac
    ;;
  systemctl)
    printf '%s\n' "$*" >>"${SYSTEMCTL_CALLS:?}"
    [ -z "${SYSTEMCTL_FAIL:-}" ] || exit 1
    if [ -n "${SYSTEMCTL_STATE:-}" ]; then
      touch "$SYSTEMCTL_STATE"
      case "$2 ${3:-}" in
        'is-enabled --quiet') grep -qxF "$4" "$SYSTEMCTL_STATE" ;;
        'is-active --quiet') [ "$4" != "${SYSTEMCTL_INACTIVE:-}" ] && grep -qxF "$4" "$SYSTEMCTL_STATE" ;;
        'restart '*) [ -z "${SYSTEMCTL_RESTART_FAIL:-}" ] ;;
        'enable --now') printf '%s\n' "${4##*/}" >>"$SYSTEMCTL_STATE" ;;
        link\ *) mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" && ln -sf "$3" "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/" ;;
        'disable --now')
          [ "$4" != "${SYSTEMCTL_STUCK:-}" ] || exit 1
          grep -vxF "$4" "$SYSTEMCTL_STATE" >"$SYSTEMCTL_STATE.new" || true
          mv "$SYSTEMCTL_STATE.new" "$SYSTEMCTL_STATE"
          ;;
      esac
    else
      [ "${2:-}" != is-active ] || exit 1
    fi
    ;;
esac
EOF
    chmod +x "$BATS_SERVICE_STUB_BIN/$tool"
  done
  cat >"$BATS_SERVICE_STUB_BIN/herdr" <<'EOF'
#!/usr/bin/env bash
if [ -n "${HERDR_TEST_STUB:-}" ] && [ -z "${HERDR_STUB_DIRECT:-}" ] && [ -x "$HOME/.local/bin/herdr" ]; then
  exec "$HOME/.local/bin/herdr" "$@"
fi
exec "${HERDR_TEST_STUB:?}" "$@"
EOF
  chmod +x "$BATS_SERVICE_STUB_BIN/herdr"
  for tool in $(compgen -v HERDR_); do unset "$tool"; done
  export PATH="$BATS_SERVICE_STUB_BIN:$PATH"
  [ "$(command -v launchctl)" = "$BATS_SERVICE_STUB_BIN/launchctl" ]
  [ "$(command -v systemctl)" = "$BATS_SERVICE_STUB_BIN/systemctl" ]
  [ "$(command -v herdr)" = "$BATS_SERVICE_STUB_BIN/herdr" ]
}
