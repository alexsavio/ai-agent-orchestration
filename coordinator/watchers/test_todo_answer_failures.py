import json
import os
import tempfile
from pathlib import Path
from unittest.mock import patch

from test_support import IsolatedTestCase

import alert_policy
import discovery
import todo_answers as a
import watchers as w

TEXT = "Deploy release [1: now] [2: later] -> Architect::Tooling"
OWNER = "Architect::Tooling"
SERVICE_DIR = Path(__file__).parent / "service"


def agents(*rows):
    return json.dumps(dict(result=dict(agents=list(rows))))


def architect(workspace):
    return dict(name=OWNER, workspace_id=workspace, tokens=dict(role="architect"))


class AnswerFailureTests(IsolatedTestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        env = patch.dict(
            os.environ,
            HOME=str(self.base),
            ORCH_USER_TODO_STATUS_DIR=str(self.base / "status"),
            ORCH_USER_QUESTIONS_DIR=str(self.base / "questions"),
            ORCH_USER_TODO_OUTPUT=str(self.base / "todo.md"),
            ORCH_USER_TODO_STATE=str(self.base / "todo.state.json"),
        )
        env.start()
        self.addCleanup(env.stop)
        (self.base / "status").mkdir()
        (self.base / "status" / f"{OWNER}.md").write_text(
            "## Waits on the user\n- " + TEXT + "\n"
        )

    def collect_with(self, owners=None, error=None, ambiguous=()):
        def fake(command, ambiguous_out=None):
            if error:
                raise discovery.Unavailable(error)
            if ambiguous_out is not None:
                ambiguous_out.update(ambiguous)
            return owners or {}

        with patch.object(a.discovery, "architect_owners", side_effect=fake):
            return a.collect(w.command)

    def test_herdr_error_is_the_reason_and_is_stored_on_the_record(self):
        a.submit(OWNER, TEXT, "now")
        ready, _, failures = self.collect_with(error="herdr agent list exited 1")
        self.assertEqual(ready, [])
        self.assertEqual(failures[0]["reason"], "herdr agent list exited 1")
        record = a.records()[0]
        self.assertEqual(record["failure"], "herdr agent list exited 1")
        self.assertEqual(record["failed_at"], failures[0]["failed_at"])

    def test_reason_is_one_line_and_at_most_200_characters(self):
        a.submit(OWNER, TEXT, "now")
        _, _, failures = self.collect_with(error="boom\n" + "x" * 500)
        self.assertNotIn("\n", failures[0]["reason"])
        self.assertEqual(len(failures[0]["reason"]), a.REASON_MAX)

    def test_name_missing_from_the_map_says_no_live_architect(self):
        a.submit(OWNER, TEXT, "now")
        _, _, failures = self.collect_with(owners={"Other": "w1"})
        self.assertEqual(failures[0]["reason"], f"no live architect named {OWNER}")

    def test_ambiguous_name_says_ambiguous(self):
        a.submit(OWNER, TEXT, "now")
        data = agents(architect("one"), architect("two"))
        ambiguous = set()
        self.assertEqual(
            discovery.architect_owners(lambda *_: data, ambiguous_out=ambiguous), {}
        )
        _, _, failures = self.collect_with(ambiguous=ambiguous)
        self.assertTrue(failures[0]["reason"].startswith("ambiguous:"))

    def test_first_failure_time_survives_later_failures_and_clears_on_ready(self):
        a.submit(OWNER, TEXT, "now")
        _, _, first = self.collect_with(owners={})
        with patch.object(a.time, "time", return_value=first[0]["failed_at"] + 900):
            _, _, again = self.collect_with(owners={})
        self.assertEqual(again[0]["failed_at"], first[0]["failed_at"])
        ready, _, failures = self.collect_with(owners={OWNER: "workspace"})
        self.assertEqual(len(ready), 1)
        self.assertEqual(failures, [])
        self.assertNotIn("failure", a.records()[0])
        self.assertNotIn("failed_at", a.records()[0])

    def test_delivery_clears_failure_fields(self):
        record = a.submit(OWNER, TEXT, "now")
        self.collect_with(owners={})
        self.assertIn("failure", a.records()[0])
        a.mark_delivered(a.event_line(dict(record, owner="workspace")))
        stored = a.records()[0]
        self.assertTrue(stored["delivered_at"])
        self.assertNotIn("failure", stored)
        self.assertNotIn("failed_at", stored)

    def test_record_without_failure_fields_still_delivers(self):
        a.submit(OWNER, TEXT, "now")
        self.assertNotIn("failure", a.records()[0])
        ready, _, failures = self.collect_with(owners={OWNER: "workspace"})
        self.assertEqual((len(ready), failures), (1, []))

    def test_answer_failure_stays_out_of_status_read_failures(self):
        a.submit(OWNER, TEXT, "now")
        with patch.object(
            a.discovery, "architect_owners", side_effect=discovery.Unavailable("down")
        ):
            raw = w.collect_todo(None)
        self.assertEqual(raw["unreadable"], [])
        self.assertEqual(raw["todo_answer_failures"][0]["architect"], OWNER)
        before = dict(now={}, unreadable=[], read=[OWNER + ".md"], scanned=True)
        after, events = w.reduce_todo(before, raw)
        self.assertEqual(after["unreadable"], [])
        self.assertEqual(after["read"], before["read"])
        self.assertEqual(events, [f"TODO READFAIL answer:{OWNER}: down"])

    def failure(self, reason="down"):
        return dict(architect=OWNER, reason=reason, failed_at=1)

    def raw(self, at, *failures):
        return dict(
            now=[],
            unreadable=[],
            read=[],
            observed_at=at,
            todo_answer_failures=failures,
        )

    def test_failure_line_repeats_at_the_wait_repeat_cadence_not_each_cycle(self):
        line = f"TODO READFAIL answer:{OWNER}: down"
        with patch.dict(os.environ, ORCH_WAIT_REPEAT_S="1800"):
            state, events = w.reduce_todo(None, self.raw(1000, self.failure()))
            self.assertEqual(events, [line])
            state, events = w.reduce_todo(state, self.raw(1060, self.failure()))
            self.assertEqual(events, [])
            state, events = w.reduce_todo(state, self.raw(2800, self.failure()))
            self.assertEqual(events, [line + " (repeat 1)"])
            _, events = w.reduce_todo(state, self.raw(2860, self.failure()))
            self.assertEqual(events, [])

    def test_failure_ending_or_changing_reason_emits_one_recovered_line(self):
        state, _ = w.reduce_todo(None, self.raw(1000, self.failure("down")))
        _, events = w.reduce_todo(state, self.raw(1060))
        self.assertEqual(events, [f"TODO READ RECOVERED answer:{OWNER}: down"])
        _, events = w.reduce_todo(state, self.raw(1060, self.failure("gone")))
        self.assertEqual(
            events,
            [
                f"TODO READ RECOVERED answer:{OWNER}: down",
                f"TODO READFAIL answer:{OWNER}: gone",
            ],
        )

    def test_notifier_shows_each_repeat_and_one_recovered_clears_them_all(self):
        lines = [
            f"TODO READFAIL answer:{OWNER}: down",
            f"TODO READFAIL answer:{OWNER}: down (repeat 1)",
        ]
        state, shown = {}, []
        for at, line in enumerate(lines + [lines[0]], start=1):
            shown += alert_policy.apply(
                state, [dict(mode="todo", events=[line], at=at)], at
            )
        self.assertEqual(len(shown), 2)
        cleared = alert_policy.apply(
            state,
            [
                dict(
                    mode="todo",
                    events=[f"TODO READ RECOVERED answer:{OWNER}: down"],
                    at=9,
                )
            ],
            9,
        )
        cleared += alert_policy.apply(state, [], 100000)
        self.assertEqual(len(cleared), 2)
        self.assertFalse(any(entry["active"] for entry in state["keys"].values()))

    def test_every_watcher_service_template_carries_the_herdr_block(self):
        templates = sorted(SERVICE_DIR.glob("*/*.template"))
        self.assertEqual(len(templates), 20)
        for template in templates:
            text = template.read_text()
            for variable in ("HERDR_BIN_PATH", "HERDR_ENV", "HERDR_SOCKET_PATH"):
                self.assertIn(variable, text, f"{template.name} lacks {variable}")
            self.assertIn("@ORCH_HERDR_BIN@", text, template.name)
            self.assertIn("@ORCH_HERDR_SOCKET@", text, template.name)
