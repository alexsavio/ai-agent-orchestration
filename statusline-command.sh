#!/bin/bash
# Claude Code status line: model, cwd, git branch, output style, context remaining.
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name // empty')
dir=$(echo "$input" | jq -r '.workspace.current_dir // empty')
style=$(echo "$input" | jq -r '.output_style.name // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')
tokens=$(echo "$input" | jq -r '.context_window.current_usage // empty | try (((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)) | if type == "number" and . == floor then . else empty end) catch empty')

# Context sensors for the Coordinator: token count and remaining percentage per session.
if [ -n "$session_id" ] && [ -n "$remaining" ]; then
  { mkdir -p "$HOME/.claude/context-usage" && printf '%s\n' "$remaining" > "$HOME/.claude/context-usage/$session_id"; } 2>/dev/null \
    || echo "statusline: cannot write $HOME/.claude/context-usage/$session_id" >&2
fi

if [ -n "$session_id" ] && [ -n "$tokens" ]; then
  { mkdir -p "$HOME/.claude/context-usage" && printf '%s\n' "$tokens" > "$HOME/.claude/context-usage/$session_id.tokens"; } 2>/dev/null \
    || echo "statusline: cannot write $HOME/.claude/context-usage/$session_id.tokens" >&2
fi

dir_name=$(basename "$dir" 2>/dev/null)

branch=""
worktree=""
if [ -n "$dir" ] && git -C "$dir" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$dir" --no-optional-locks branch --show-current 2>/dev/null)
  toplevel=$(git -C "$dir" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
  if [ -n "$toplevel" ]; then
    dir_name=$(basename "$toplevel")
    # Linked worktree: git-dir differs from git-common-dir; show repo/worktree
    git_dir=$(git -C "$dir" --no-optional-locks rev-parse --absolute-git-dir 2>/dev/null)
    common_dir=$(git -C "$dir" --no-optional-locks rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    if [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ]; then
      worktree=$dir_name
      dir_name=$(basename "$(dirname "$common_dir")")
    fi
  fi
fi

ctx=""
if [ -n "$remaining" ]; then
  pct=$(printf '%.0f' "$remaining" 2>/dev/null || echo "$remaining")
  if [ "$pct" -le 15 ] 2>/dev/null; then
    ctx_color='1;31'
  elif [ "$pct" -le 35 ] 2>/dev/null; then
    ctx_color='1;33'
  else
    ctx_color='0;37'
  fi
  ctx=$(printf '\033[%sm%s%%\033[0m' "$ctx_color" "$pct")
  if [ -n "$tokens" ]; then
    ctx="$ctx $(printf '\033[%sm%sk\033[0m' "$ctx_color" "$(( (tokens + 500) / 1000 ))")"
  fi
fi

segments=()
[ -n "$model" ] && segments+=("$(printf '\033[32m%s\033[0m' "$model")")
[ -n "$ctx" ] && segments+=("$ctx")
[ -n "$dir_name" ] && segments+=("$(printf '\033[33m%s\033[0m' "$dir_name")")
# \xef\x90\x82 = U+F402 Nerd Font oct-repo-forked (worktree)
[ -n "$worktree" ] && segments+=("$(printf '\033[34m\xef\x90\x82 %s\033[0m' "$worktree")")
# \xee\x9c\xa5 = U+E725 Nerd Font git-branch (devicons)
if [ -n "$branch" ] && [ -z "$worktree" ]; then
  segments+=("$(printf '\033[36m\xee\x9c\xa5 %s\033[0m' "$branch")")
fi
if [ -n "$style" ] && [ "$style" != "default" ]; then
  segments+=("$(printf '\033[35m%s\033[0m' "$style")")
fi

output=""
for segment in "${segments[@]}"; do
  if [ -z "$output" ]; then
    output="$segment"
  else
    output="$output $(printf '\033[2m|\033[0m') $segment"
  fi
done

printf '%s\n' "$output"
