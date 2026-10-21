# Worker recycle

Read this file before you act on a `RECYCLE-WORKER` message. A worker never recycles itself; you run this procedure.

**The signal.** The context watcher reads each Claude pane's `~/.claude/context-usage/<session-id>.tokens`. When a worker in a workspace tagged `owner=$HERDR_WORKSPACE_ID` reaches `$ORCH_RECYCLE_TOKENS` tokens (`$ORCH_RECYCLE_PCT` percent without that file), you get one native message per session: `context: RECYCLE-WORKER <pane> owner=<you> <name> <amount> (start). No reply needed.` It comes only while your binding `bindings/architect-$HERDR_WORKSPACE_ID.json` is live; without one the line stays in the Coordinator feed. Codex workers have no sensor and are not watched.

## Procedure

1. **Check.** `herdr agent get <name>`: the pane matches and the worker is yours. A worker whose PR has merged is closed (step 6), not recycled.
2. **Heavy slot.** `heavy-slot list`. While a `live` slot carries the worker's name (workers take `<architect>-<name>-<job>`), wait: never order a handoff mid-run. Check again at the worker's next status change.
3. **Order the handoff** with `herdr agent prompt <name> "<order>" --wait --timeout 120000`: *Finish your current call and start nothing new. Overwrite (never append) `<report dir>/<name>-handoff.md`, under 4,000 characters, with the worker handoff template in `~/.claude/skills/architect/references/worker-recycle.md`. Reply with only its path, then stop.*
4. **Read the handoff.** Under 4,000 characters (`wc -c`) and every field filled; ask once for what is missing.
5. **Start the successor** in the same workspace and worktree, on the same model (your dispatch note names it):
   - `herdr pane split <old pane> --direction down --cwd <worktree> --no-focus`; the new pane is `result.pane.pane_id`. Never `herdr worktree open` the worktree again: on an open path it renames the workspace.
   - `herdr agent start <name>-next --kind claude --pane <new pane> -- --model <model>` (any free name of at most 32 characters). Never `--resume` the old session: that loads its whole context again.
   - Prompt it once: *Read `<handoff path>` and only that, not the old transcript; it names your brief and rules. You own the review cycle of PR <n> from here. Write your report to `<report path>`.*
   - Wait until `herdr agent get <name>-next` shows it working from the handoff.
6. **Close the old pane** with `~/.claude/coordinator/watchers/close-pane.sh <old pane>`, then `herdr agent rename <name>-next <name>`, so slot names, reports and the Radar keep one name.
7. **Record** the new pane id in your status file and handoff. The workspace and its `owner` tag stay the same, so PR events and the next `RECYCLE-WORKER` still come to you. The feed gets `RECYCLE-WORKER <old pane> … cleared` when the old session leaves.

## Worker handoff template

Under 4,000 characters, overwritten (never appended), facts only:

- **Brief and rules:** brief path, common-rules path, report path.
- **Code:** repo, branch, worktree, head SHA, pushed to which remote.
- **PR:** number, state, CI, review decision; or "no PR yet".
- **Open review threads:** one line each: thread id or URL, what it asks, status (fixed in `<sha>`, replied, open).
- **Waits on:** the architect, CI, a bot review, a reviewer, or nothing.
- **Done:** one line each, with its proof (command and result).
- **Next step:** the first thing to do.
- **Decided, do not reopen:** choices made with the architect, dead ends.
- **Running:** heavy slot held (should be none), processes left running.
