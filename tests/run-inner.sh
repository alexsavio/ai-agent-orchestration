#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"
bats tests/
python3 tests/guard-bash.test.py
(cd coordinator/watchers && python3 run_tests.py)
node --test chrome/pr-tabs/test/*.test.js
