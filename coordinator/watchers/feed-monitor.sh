#!/bin/bash
# The Coordinator's one feed Monitor: prints action lines appended after it starts, without PR text.
# feed_follow.py opens the feed before it touches the heartbeat, every 60 seconds.
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
. "$root/coord-lib.sh"
orch_load_config
state="${1:-$HOME/.claude/coordinator/watchers/prod-context}"
feed="$state/coordinator-feed.log"
beat="$state/coordinator-feed.monitor"
mkdir -p "$state"
(umask 077 && touch "$feed")
owner="$beat.owner"
printf '%s\n' "$$" >"$owner.$$" && mv -f "$owner.$$" "$owner"
"${ORCH_PYTHON3:-python3}" "$root/feed_follow.py" "$feed" "$beat" &
follower=$!
owns_beat() { [ "$(cat "$owner" 2>/dev/null)" = "$$" ]; }
trap 'kill "$follower" 2>/dev/null || true; wait "$follower" 2>/dev/null || true; ! owns_beat || rm -f "$beat"' EXIT
trap 'exit 143' TERM INT HUP
wait "$follower"
