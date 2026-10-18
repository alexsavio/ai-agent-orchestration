#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
case "$(uname -s)" in
  Darwin) . "$ROOT/tests/platform/macos.sh" ;;
  Linux) . "$ROOT/tests/platform/linux.sh" ;;
  *) printf 'Unsupported test platform\n' >&2; exit 1 ;;
esac
run_isolated_tests "$ROOT"
