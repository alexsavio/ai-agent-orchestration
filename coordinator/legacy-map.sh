#!/usr/bin/env bash
# Writes legacy-map.tsv: JSERB, ASSETJS and JQUERY files on origin/main of the repo in $1 (or $ORCH_LEGACY_MAP_REPO).
set -euo pipefail

repo=${1:-${ORCH_LEGACY_MAP_REPO:-}}
out=${ORCH_LEGACY_MAP_OUT:-$HOME/.claude/coordinator/legacy-map.tsv}
scan_paths="app lib clients"

[ -n "$repo" ] || { echo "usage: legacy-map.sh <repo> (or set ORCH_LEGACY_MAP_REPO)" >&2; exit 1; }
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "legacy-map.sh: $repo is not a git repository" >&2; exit 1; }
command -v rg >/dev/null 2>&1 || { echo "legacy-map.sh: rg not found" >&2; exit 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/legacy-map.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

git -C "$repo" fetch -q origin main
tree=$(git -C "$repo" ls-tree -r --name-only origin/main)

present=()
for p in $scan_paths; do
  [ -z "$(git -C "$repo" ls-tree --name-only origin/main "$p")" ] || present+=("$p")
done
jquery=""
if [ ${#present[@]} -gt 0 ]; then
  git -C "$repo" archive origin/main "${present[@]}" | tar -x -C "$tmp"
  rg_status=0
  jquery=$(cd "$tmp" && rg -l --glob '!**/tests/**' --glob '!**/*.spec.*' --glob '!**/app/assets/javascripts/**' \
    -e '\bjQuery\b|\$\(|\$\.ajax|ajax:(success|complete)|data-remote|remote: *true' "${present[@]}") || rg_status=$?
  [ "$rg_status" -le 1 ] || { echo "legacy-map.sh: rg failed with status $rg_status" >&2; exit 1; }
fi

kind() { awk -v k="$1" 'BEGIN { OFS = "\t" } { print k, $0 }'; }

mkdir -p "$(dirname "$out")"
{
  printf '%s\n' "$tree" | { grep -E '\.js\.erb$' || true; } | kind JSERB
  printf '%s\n' "$tree" | { grep -E '(^|/)app/assets/javascripts/.*\.(js|coffee)$' || true; } | kind ASSETJS
  [ -z "$jquery" ] || printf '%s\n' "$jquery" | kind JQUERY
} | LC_ALL=C sort -u >"$out.tmp"
mv "$out.tmp" "$out"
cut -f1 "$out" | sort | uniq -c
