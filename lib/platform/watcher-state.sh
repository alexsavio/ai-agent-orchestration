#!/usr/bin/env bash
platform_copy_legacy_watcher_state() {
  local old new source target relative mode found=0 skipped_modes=""
  for old in "$CLAUDE_DIR/coordinator/v2/bindings" "$CLAUDE_DIR/coordinator/v2/prod-context"; do
    [ -d "$old" ] || continue
    found=1
    new=${old/coordinator\/v2/coordinator\/watchers}
    mkdir -p "$new"
    while IFS= read -r source; do
      relative=${source#"$old"/}
      target="$new/$relative"
      if [ -d "$source" ] && [ ! -L "$source" ]; then
        mkdir -p "$target"
      else
        case "$relative" in
          *.cursor) ;;
          *.json)
            if [ ! -e "$target" ] && [ ! -L "$target" ]; then
              mkdir -p "$(dirname "$target")"
              cp -p "$source" "$target"
            else
              mode=${relative##*/}
              skipped_modes="$skipped_modes ${mode%.json}"
            fi
            ;;
          *)
            if [ ! -e "$target" ] && [ ! -L "$target" ]; then
              mkdir -p "$(dirname "$target")"
              cp -p "$source" "$target"
            fi
            ;;
        esac
      fi
    done < <(find "$old" -mindepth 1 -print)
    while IFS= read -r source; do
      relative=${source#"$old"/}
      target="$new/$relative"
      for mode in $skipped_modes; do
        grep -q '"'"$mode"'"' "$source" && continue 2
      done
      [ -e "$target" ] || [ -L "$target" ] || cp -p "$source" "$target"
    done < <(find "$old" -type f -name '*.cursor' -print)
  done
  [ "$found" = 1 ]
}

platform_finish_legacy_watcher_migration() {
  local marker="$CLAUDE_DIR/coordinator/watchers/.migration-state-copied"
  [ -e "$marker" ] && return 0
  if platform_copy_legacy_watcher_state; then
    : >"$marker"
    say "copied state" "legacy watcher state is ready; old directories were kept"
  fi
}
