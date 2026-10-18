#!/usr/bin/env bash
# launchd does not rotate StandardErrorPath.  Each watcher restart caps its
# previous stderr before execing the actual watcher, so startup crashes cannot
# consume unbounded disk while KeepAlive is retrying.
set -euo pipefail

log=$1
shift
max_bytes=${WATCHER_STDERR_MAX_BYTES:-1048576}

case $max_bytes in
  ''|*[!0-9]*) printf 'WATCHER_STDERR_MAX_BYTES must be a non-negative integer\n' >&2; exit 64 ;;
esac

if [ -e "$log" ] && size=$(wc -c <"$log") && [ "$size" -ge "$max_bytes" ]; then
  : >"$log"
fi

exec "$@" 2>>"$log"
