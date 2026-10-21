# The Bash guard

`hooks/guard-bash.py` runs before every Bash tool call in Claude Code. It reads the command and never runs it. It denies:

- `git push` to `main` or `master` (including `--all`, `--mirror`, `:` and glob refspecs). Push a branch and open a PR. GitHub wiki remotes are allowed.
- AI attribution in commit messages, PR titles and PR bodies, such as `Co-Authored-By: Claude` or "Generated with Claude Code".
- Broad process kills: `pkill`, or `pgrep -f` fed into `kill`. Stop your own pid.
- Broad process kills: `killall` with a dev-server name (`node`, `ruby`, `puma`, `vite`, `rails`, `bundle`, `sidekiq`, `esbuild`, `foreman`, `overmind`, `bin/dev`, `dev-instance`) or with `-m`.
- In a repo that has linked worktrees: `git fetch` or `git pull` with `--depth`, `--deepen`, `--shallow-*` or `--unshallow`, and any `git stash` except `list` and `show`. Both change history or state the worktrees share.
- In repos whose `.orchestration.toml` or `.orchestration.local.toml` sets `guard.big_repo = true`: every `git grep`, even with a path, and bulk `git cat-file --batch`, `--batch-check` or `--batch-all-objects` reads. The installed session instructions say to use directory-scoped `rg` and `git show <ref>:<path>` for another ref.
- pi outside the start step, because a pi start with no provider uses pi's own default and DeepSeek is off unless the repo opted in. Denied: `herdr agent start … --kind pi` (the kind compared in lowercase; a `$` expansion in the kind value is denied too), any `herdr agent start` of any kind whose arguments name DeepSeek in any case, `herdr pane run` and `herdr pane send-text` whose text starts a `pi` command, a `/model` text sent with `herdr agent prompt`, `herdr pane run` or `herdr pane send-text` (a live pi never changes model), and any `pi` command naming DeepSeek. The skill always uses `~/.claude/coordinator/pi-start.sh`, which runs herdr outside the Bash tool. `pi --list-models <provider>` and a direct `pi` run on a local provider are allowed. The pi rules also look inside `bash -c`, `sh -c`, `zsh -c`, `eval` and quoted `$(…)` bodies.
- Known limits of the pi rules: this is a tripwire, not a sandbox. Still open: `npx` or `node <path>` running pi, `mise exec -- pi`, `xargs pi`, a provider or kind spliced from shell variables (`${P}seek`, `$'\x64…'`), a custom `models.json` provider that points at DeepSeek's API under another name (the start step cannot see it), a pi extension that switches model, and an exported `ORCH_PI_WORKER_MODEL` that names a non-DeepSeek provider routed to DeepSeek.

If the guard itself breaks, it lets the command through and logs the error to `~/.claude/hooks/guard-bash.log`. The installer checks after linking that the guard denies a forbidden command.
