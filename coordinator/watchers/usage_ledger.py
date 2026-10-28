"""Appends one usage line for a pane that is about to be closed on purpose; best effort, never blocks the close."""

import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

COLUMNS = (
    "closed_at",
    "owner",
    "workspace_label",
    "agent_name",
    "pane",
    "session_id",
    "model",
    "cost_usd",
)


LOOKUP_TIMEOUT_S = 5
# The whole ledger step; callers such as question_lock.py allow a close only 30 s.
DEADLINE_S = 10


class NoAgent(Exception):
    """The pane has no agent: herdr answers agent_not_found."""


def herdr(*argv, deadline):
    binary = (
        os.environ.get("HERDR_BIN_PATH") or os.environ.get("ORCH_HERDR_BIN") or "herdr"
    )
    left = deadline - time.monotonic()
    done = subprocess.run(
        [binary, *argv],
        capture_output=True,
        text=True,
        check=False,
        timeout=max(min(LOOKUP_TIMEOUT_S, left), 0.1),
    )
    if done.returncode:
        try:
            code = (json.loads(done.stdout).get("error") or {}).get("code")
        except (ValueError, AttributeError):
            code = None
        if code == "agent_not_found":
            raise NoAgent(argv[-1])
        raise RuntimeError(
            f"herdr {' '.join(argv)} failed: {done.stderr.strip() or done.returncode}"
        )
    return json.loads(done.stdout)["result"]


def ledger_path():
    return Path.home() / ".claude/coordinator/usage-ledger.tsv"


def cell(value):
    """A TSV cell: tabs and line breaks become spaces."""
    return " ".join(str("" if value is None else value).split())


def usage_of(session):
    """The .usage object of a session; empty when the file is missing or unreadable."""
    path = Path.home() / ".claude/context-usage" / f"{session}.usage"
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def record(pane, now, deadline):
    """The ledger row for `pane`, or None when it has no agent."""
    agent = herdr("agent", "get", pane, deadline=deadline).get("agent") or {}
    session = (agent.get("agent_session") or {}).get("value")
    if not agent or not session:
        return None
    workspace = herdr("workspace", "get", agent["workspace_id"], deadline=deadline)[
        "workspace"
    ]
    usage = usage_of(session)
    return (
        now.isoformat(timespec="seconds"),
        (workspace.get("tokens") or {}).get("owner"),
        workspace.get("label"),
        agent.get("name"),
        pane,
        session,
        usage.get("model"),
        usage.get("cost_usd"),
    )


def append(row):
    path = ledger_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    header = "" if path.exists() and path.stat().st_size else "\t".join(COLUMNS) + "\n"
    with path.open("a") as out:
        out.write(header + "\t".join(cell(value) for value in row) + "\n")


def main(argv):
    try:
        row = record(
            argv[1], datetime.now().astimezone(), time.monotonic() + DEADLINE_S
        )
        if row:
            append(row)
    except NoAgent:
        pass
    except Exception as error:  # best effort: the close must still run
        print(f"warning: usage ledger line not written: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
