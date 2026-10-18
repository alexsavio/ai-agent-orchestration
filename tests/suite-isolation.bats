#!/usr/bin/env bats

@test "suite setup protects a file without test helpers" {
  [ "$(command -v launchctl)" = "$BATS_SERVICE_STUB_BIN/launchctl" ]
  [ "$(command -v systemctl)" = "$BATS_SERVICE_STUB_BIN/systemctl" ]
  [ "$(command -v herdr)" = "$BATS_SERVICE_STUB_BIN/herdr" ]
}
