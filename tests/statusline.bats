#!/usr/bin/env bats
# shellcheck disable=SC2154 # bats provides status and output after run.

@test "context segment includes remaining percentage and rounded used tokens" {
  run /bin/bash "$BATS_TEST_DIRNAME/../statusline-command.sh" <<'JSON'
{"model":{"display_name":"Claude"},"workspace":{"current_dir":"/tmp"},"context_window":{"remaining_percentage":81,"current_usage":{"input_tokens":120000,"cache_creation_input_tokens":30000,"cache_read_input_tokens":40500}}}
JSON

  [ "$status" -eq 0 ]
  plain=$(printf '%s' "$output" | sed $'s/\033\\[[0-9;]*m//g')
  [[ "$plain" == *"81% 191k"* ]]
}

# Links: OSC 8 hyperlinks on the repo name and the branch.
OSC=$'\033]8;;'
BEL=$'\a'

# make_repo <dir> <branch> [remote-url]: repo on <branch>, origin set to remote-url when given.
make_repo() {
  git init -q -b "$2" "$1"
  git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  if [ -n "${3:-}" ]; then git -C "$1" remote add origin "$3"; fi
}

# track <dir> <remote> <branch>: the current branch tracks <remote>/<branch>.
track() {
  git -C "$1" config "branch.$(git -C "$1" branch --show-current).remote" "$2"
  git -C "$1" config "branch.$(git -C "$1" branch --show-current).merge" "refs/heads/$3"
}

run_line() {
  run /bin/bash "$BATS_TEST_DIRNAME/../statusline-command.sh" <<JSON
{"model":{"display_name":"Claude"},"workspace":{"current_dir":"$1"}}
JSON
}

strip_all() {
  printf '%s' "$1" | sed -e $'s/\033\\[[0-9;]*m//g' -e $'s/\033\\]8;;[^\a]*\a//g'
}

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  REPO="$BATS_TEST_TMPDIR/proj"
}

@test "ssh remote: repo and branch link to github" {
  make_repo "$REPO" feat/x git@github.com:acme/proj.git
  track "$REPO" origin feat/x
  run_line "$REPO"
  [ "$status" -eq 0 ]
  [[ "$output" == *"${OSC}https://github.com/acme/proj${BEL}proj"* ]] || return 1
  [[ "$output" == *"${OSC}https://github.com/acme/proj/tree/feat/x${BEL}"*"feat/x"* ]] || return 1
}

@test "ssh:// remote with a port drops the port" {
  make_repo "$REPO" main ssh://git@github.com:2222/acme/proj.git
  track "$REPO" origin main
  run_line "$REPO"
  [[ "$output" == *"${OSC}https://github.com/acme/proj${BEL}proj"* ]] || return 1
  [[ "$output" == *"${OSC}https://github.com/acme/proj/tree/main${BEL}"* ]] || return 1
}

@test "https remote: credentials never reach the output" {
  make_repo "$REPO" main https://bob:s3cret@github.com/acme/proj.git
  track "$REPO" origin main
  run_line "$REPO"
  [[ "$output" == *"${OSC}https://github.com/acme/proj${BEL}proj"* ]] || return 1
  [[ "$output" != *s3cret* ]] || return 1
  [[ "$output" != *bob* ]] || return 1
}

@test "gitlab host uses /-/tree/" {
  make_repo "$REPO" main git@gitlab.example.com:acme/sub/proj.git
  track "$REPO" origin main
  run_line "$REPO"
  [[ "$output" == *"${OSC}https://gitlab.example.com/acme/sub/proj/-/tree/main${BEL}"* ]] || return 1
}

@test "bitbucket uses /src/" {
  make_repo "$REPO" main git@bitbucket.org:acme/proj.git
  track "$REPO" origin main
  run_line "$REPO"
  [[ "$output" == *"${OSC}https://bitbucket.org/acme/proj/src/main${BEL}"* ]] || return 1
}

@test "unknown remote forms stay plain text" {
  make_repo "$REPO" main git@github.com:acme/proj.git
  run_line "$REPO"
  [[ "$output" == *"$OSC"* ]] || return 1
  for url in /srv/git/proj.git file:///srv/git/proj.git "ftp://example.com/acme/proj.git" "https://example.com/proj"; do
    rm -rf "$REPO"
    make_repo "$REPO" main "$url"
    track "$REPO" origin main
    run_line "$REPO"
    [[ "$output" != *$'\033]8;'* ]] || return 1
  done
}

@test "link text with control characters is refused" {
  make_repo "$REPO" main git@github.com:acme/proj.git
  run_line "$REPO"
  [[ "$output" == *"$OSC"* ]] || return 1
  rm -rf "$REPO"
  make_repo "$REPO" main $'https://example.com/acme/pr\aoj'
  track "$REPO" origin main
  run_line "$REPO"
  [[ "$output" != *$'\033]8;'* ]] || return 1
}

@test "tracking a non-origin remote links that remote with the upstream branch name" {
  make_repo "$REPO" local-name git@github.com:me/fork.git
  git -C "$REPO" remote add upstream git@github.com:acme/proj.git
  track "$REPO" upstream main
  run_line "$REPO"
  [[ "$output" == *"${OSC}https://github.com/acme/proj${BEL}proj"* ]] || return 1
  [[ "$output" == *"${OSC}https://github.com/acme/proj/tree/main${BEL}"* ]] || return 1
}

@test "no upstream: repo links to origin, branch stays plain" {
  make_repo "$REPO" feat/x git@github.com:acme/proj.git
  run_line "$REPO"
  [[ "$output" == *"${OSC}https://github.com/acme/proj${BEL}proj"* ]] || return 1
  [[ "$output" != *"/tree/"* ]] || return 1
}

@test "no upstream and no origin: no links" {
  make_repo "$REPO" main git@github.com:acme/proj.git
  run_line "$REPO"
  [[ "$output" == *"$OSC"* ]] || return 1
  rm -rf "$REPO"
  make_repo "$REPO" main
  run_line "$REPO"
  [[ "$output" == *"proj"* ]] || return 1
  [[ "$output" != *$'\033]8;'* ]] || return 1
}

@test "upstream on the local repo (.) gives no branch link" {
  make_repo "$REPO" main git@github.com:acme/proj.git
  git -C "$REPO" branch other
  track "$REPO" . other
  run_line "$REPO"
  [[ "$output" == *"${OSC}https://github.com/acme/proj${BEL}proj"* ]] || return 1
  [[ "$output" != *"/tree/"* ]] || return 1
}

@test "detached HEAD: repo links, no branch link" {
  make_repo "$REPO" main git@github.com:acme/proj.git
  track "$REPO" origin main
  git -C "$REPO" checkout -q --detach
  run_line "$REPO"
  [[ "$output" == *"${OSC}https://github.com/acme/proj${BEL}proj"* ]] || return 1
  [[ "$output" != *"/tree/"* ]] || return 1
}

@test "linked worktree: the worktree segment links to the branch view" {
  make_repo "$REPO" main git@github.com:acme/proj.git
  git -C "$REPO" worktree add -q -b feat/wt "$BATS_TEST_TMPDIR/wt"
  track "$BATS_TEST_TMPDIR/wt" origin feat/wt
  run_line "$BATS_TEST_TMPDIR/wt"
  [[ "$output" == *"${OSC}https://github.com/acme/proj${BEL}proj"* ]] || return 1
  [[ "$output" == *"${OSC}https://github.com/acme/proj/tree/feat/wt${BEL}"*"wt"* ]] || return 1
}

@test "branch name special characters are percent-encoded, slash kept" {
  make_repo "$REPO" 'feat/a#b%d+e&f' git@github.com:acme/proj.git
  track "$REPO" origin 'feat/a#b%d+e&f'
  run_line "$REPO"
  [[ "$output" == *"${OSC}https://github.com/acme/proj/tree/feat/a%23b%25d%2Be%26f${BEL}"* ]] || return 1
}

@test "visible text is the same with and without links" {
  make_repo "$REPO" feat/x git@github.com:acme/proj.git
  track "$REPO" origin feat/x
  run_line "$REPO"
  linked_raw=$output
  linked=$(strip_all "$output")
  git -C "$REPO" remote remove origin
  run_line "$REPO"
  plain=$(strip_all "$output")
  [ "$linked" = "$plain" ]
  [ "$plain" = "Claude | proj | "$'\xee\x9c\xa5'" feat/x" ]
  [[ "$linked_raw" == *"$OSC"* ]] || return 1
}
