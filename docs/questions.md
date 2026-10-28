# User questions

Every user question gets a pane that stacks below the to-do pane without taking focus.

![The Q panel with the reminder picker open](q-panel.png)

## Open and close

Create the question's Markdown file under `~/.claude/coordinator/questions/<slug>.md`, then run `ask-user-question <slug> <file>`. The pane is labelled `Q: <slug>`.

| Command | Effect |
| --- | --- |
| `ask-user-question <slug> <file>` | Opens the pane. |
| `ask-user-question close <slug>` | Finds the pane by its exact label, closes it through `close-pane.sh`, then removes the question's files. A failed close keeps the files for retry. |
| `ask-user-question hide <slug>` | Closes the pane and keeps the question files; the Q panel's Remind runs it. |

## Keys

| Key | Action |
| --- | --- |
| `1`-`9` | Picks that option id when the file has a `## Options` section, or records the number alone otherwise. |
| `t` | Type an answer; Enter sends it. |
| `d` | Dismiss: writes `answers: DISMISSED <slug>` to the feed, then closes the pane and removes the question. |
| `r` | Remind: opens the same picker as the to-do view's Reminder (`1` 15m, `2` 1h, `3` 2h, `4` 4h, `5` tomorrow 9:00, `t` a typed `30m` or `3h`). Esc cancels it. |

Answers reach the Coordinator through the shared feed Monitor as `answers: ANSWER <slug>: <text>`.

## File format

The asker writes `~/.claude/coordinator/questions/<slug>.md`; the Coordinator shows it unchanged:

```markdown
# <the question, one line>

<optional short context, Markdown>

## Options

1. <label>
2. <label>
```

The option id is the digit `1`-`9`, consecutive from `1`; the label is the rest of that one line after `<digit>. `. Duplicate ids are allowed: the last one wins. An empty label is allowed. The label is whitespace-normalised (leading and trailing whitespace stripped, inner runs collapsed to one space) to match the answers watcher's own collapse.

- With a `## Options` section, key `1`-`9` records `ANSWER <slug>: <id> "<label>"`. A digit with no option records nothing and shows a short status line.
- In that answer line the label is everything between the first double quote after the id and the last double quote of the line, so a parser uses `^([1-9]) "(.*)"$`.
- Key `t` records `ANSWER <slug>: <text>`.
- Without a `## Options` section, key `1`-`9` records the digit alone.

## Remind

A pick writes `answers: REMIND <slug> <YYYY-MM-DD HH:MM>` to the feed and stores the time (epoch seconds) in `<slug>.remind` next to the question. The pane then runs `ask-user-question hide <slug>`. On its next cycle after that time, the answers watcher reopens the pane and removes the file. A failed open retries on the next cycle. If the feed cannot be written, nothing changes and the panel stays open.

See [watchers.md](watchers.md) for how the answers watcher claims and publishes answers.
