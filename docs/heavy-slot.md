# Heavy jobs: `heavy-slot`

Many sessions share one machine. Too many test runs, browsers or builds at once can exhaust open files and memory. `heavy-slot` is a shared cap of `ORCH_HEAVY_SLOTS_MAX` jobs.

```bash
heavy-slot take acme-tests --note "first-run.bats for PR 106" -- npm test   # waits up to 1800 s for a free slot, then runs
heavy-slot count                         # slots in use
heavy-slot list                          # names, pids, ages, notes, stale records
```

`--note <text>` says what the job is. It shows in `list` and in every event line (`note=-` without it). The note is cut to one printable line of 60 characters.

A slot is a file in `~/.claude/heavy-slots/` that holds the job's pid. `take` removes it when the job ends.

- If the cap stays full, `take` prints `NEED SLOT`.
- `take` exits 73 when the slot directory is not writable (for example in a sandbox). Run it again with write access to that directory.
- Never create slot files by hand. Stop jobs by pid, not with `pkill`.
- The audit reports `STALESLOT` for a file whose pid is gone.
- The balance watcher uses the same cap.

## Feed lines

`take` appends one line per event to `<slot dir>/.events`. The balance watcher reads that file each pass, removes it, and turns each line into a feed line (`balance: SLOT ...`). Every line names the slot, the pid, and the note.

| Event | When | Example | Feed |
| --- | --- | --- | --- |
| `WAIT` | The job found no free slot (once per job) | `SLOT WAIT acme-tests pid=40 slots=4/4 note=first-run.bats for PR 106` | FYI log |
| `FAIL` | The job exited non-zero | `SLOT FAIL acme-tests pid=41 code=1 elapsed=93s note=...` | FYI log |
| `KILLED` | A signal ended the job (exit above 128), or `take` stopped it | `SLOT KILLED acme-tests pid=41 code=143 elapsed=12s note=...` | Action line |
| `RUNLONG` | The job ran past `heavy_slots.long_run` (once per job; 0 turns it off) | `SLOT RUNLONG acme-tests pid=41 elapsed=1800s note=...` | Action line |

Only action lines reach the Coordinator's Monitor and native delivery; see [watchers](watchers.md). One `write(2)` appends each line, so jobs that end together never interleave or lose a line. The watcher claims the file by rename, so a crash between the claim and the feed write drops those lines.

The rules for workers and the Coordinator are in [Architecture](architecture.md#-heavy-slots).
