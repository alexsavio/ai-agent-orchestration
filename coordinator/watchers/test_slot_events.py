import json
import os
import subprocess
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

from test_support import IsolatedTestCase

import alert_policy
import feed_actions
import watcher_platform
import watchers as w

HEAVY_SLOT = w.ROOT.parent.parent / "heavy-slot"
ACTION = [
    "SLOT KILLED agent-tests pid=41 code=137 elapsed=12s note=first-run.bats for PR 106",
    "SLOT RUNLONG agent-tests pid=41 elapsed=1800s note=-",
]
FYI = [
    "SLOT WAIT agent-tests pid=40 slots=4/4 note=-",
    "SLOT FAIL agent-tests pid=41 code=1 elapsed=3s note=-",
]


def stamped(lines, age=0):
    return "".join(f"{int(time.time()) - age} {line}\n" for line in lines)


def feed(line):
    return f"2026-10-27T12:00:00+00:00 balance: {line} (start)"


class SlotEventsTest(IsolatedTestCase):
    def spool(self, tmp, text):
        (Path(tmp) / ".events").write_text(text)

    def test_producer_claims_valid_lines_and_trims_the_spool(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spool(
                tmp,
                stamped(ACTION)
                + "junk\n"
                + stamped(["SLOT NOPE x pid=1 a"])
                + "SLOT FAIL a-b pid=1 x\n",
            )
            self.assertEqual(watcher_platform.take_slot_events(tmp), (ACTION, []))
            self.assertEqual(os.listdir(tmp), [])
            self.assertEqual(watcher_platform.take_slot_events(tmp), ([], []))

    def test_producer_keeps_the_newest_lines_when_the_spool_is_large(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spool(
                tmp,
                stamped([f"SLOT FAIL a-b pid={n} code=1 note=-" for n in range(150)]),
            )
            lines, _ = watcher_platform.take_slot_events(tmp)
            self.assertEqual(len(lines), watcher_platform.SLOT_EVENTS_KEPT)
            self.assertTrue(lines[-1].endswith("code=1 note=-"))
            self.assertIn("pid=149 ", lines[-1])

    def test_producer_reads_the_configured_slot_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spool(tmp, stamped(ACTION[:1]))
            with patch.dict(os.environ, ORCH_HEAVY_SLOTS_DIR=tmp):
                self.assertEqual(watcher_platform.take_slot_events(), ([ACTION[0]], []))

    def test_balance_collect_adds_the_claimed_slot_lines(self):
        base = dict(free=60, load5=1.0, slots=0, heavy=0, unreadable=[], top=[])
        with tempfile.TemporaryDirectory() as tmp:
            self.spool(tmp, stamped(ACTION[:1]))
            with (
                patch.dict(os.environ, ORCH_HEAVY_SLOTS_DIR=tmp),
                patch.object(w, "balance_metrics", return_value=base),
            ):
                raw = w.collect("balance", None)
            self.assertEqual(raw["slot_events"], [ACTION[0]])
            self.assertEqual(os.listdir(tmp), [])

    def test_old_spool_lines_are_dropped_and_fresh_ones_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spool(
                tmp,
                stamped(ACTION[:1], age=watcher_platform.SLOT_EVENT_MAX_AGE + 5)
                + stamped(ACTION[1:], age=watcher_platform.SLOT_EVENT_MAX_AGE - 60),
            )
            self.assertEqual(watcher_platform.take_slot_events(tmp), (ACTION[1:], []))

    def test_unreadable_spool_is_reported_and_leaves_the_claim(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / ".events").mkdir()
            self.assertEqual(
                watcher_platform.take_slot_events(tmp),
                ([], [watcher_platform.SLOT_EVENTS_SOURCE]),
            )
            self.assertEqual(
                [p.name for p in Path(tmp).iterdir()],
                [f".events.claim.{os.getpid()}"],
            )

    def test_spool_that_cannot_be_claimed_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.spool(tmp, stamped(ACTION))
            with patch.object(
                watcher_platform.os, "rename", side_effect=PermissionError
            ):
                self.assertEqual(
                    watcher_platform.take_slot_events(tmp),
                    ([], [watcher_platform.SLOT_EVENTS_SOURCE]),
                )
            self.assertTrue((Path(tmp) / ".events").exists())

    def test_missing_spool_is_not_a_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(watcher_platform.take_slot_events(tmp), ([], []))
            self.assertEqual(
                watcher_platform.take_slot_events(Path(tmp) / "none"), ([], [])
            )

    def test_old_claims_are_removed_and_young_ones_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            old, young = Path(tmp) / ".events.claim.1", Path(tmp) / ".events.claim.2"
            old.write_text("x")
            young.write_text("x")
            aged = time.time() - watcher_platform.SLOT_EVENT_MAX_AGE - 5
            os.utime(old, (aged, aged))
            watcher_platform.take_slot_events(tmp)
            self.assertFalse(old.exists())
            self.assertTrue(young.exists())

    def test_balance_reports_an_unreadable_spool_as_a_readfail(self):
        base = dict(free=60, load5=1.0, slots=0, heavy=0, unreadable=[], top=[])
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / ".events").mkdir()
            with (
                patch.dict(os.environ, ORCH_HEAVY_SLOTS_DIR=tmp),
                patch.object(w, "balance_metrics", return_value=dict(base)),
            ):
                raw = w.collect("balance", None)
        self.assertEqual(raw["unreadable"], [watcher_platform.SLOT_EVENTS_SOURCE])
        state, events = None, []
        for _ in range(w.READ_FAILURES):
            state, events = w.reduce("balance", state, dict(raw))
        self.assertIn("BALANCE READFAIL slot-events", events)

    def test_slot_lines_survive_the_first_pass_after_a_state_reset(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / "balance.json").write_text("{broken")
            raw = dict(free=60, load5=1.0, slots=0, heavy=0, unreadable=[], top=[])
            raw["slot_events"] = ACTION + FYI
            alert = json.loads(w.cycle(base, "balance", lambda before: raw))
            self.assertEqual(
                [e for e in alert["events"] if e.startswith("SLOT ")], ACTION + FYI
            )

    def test_balance_reduce_emits_the_slot_lines_after_its_own(self):
        raw = dict(free=60, load5=1.0, slots=1, heavy=0, unreadable=[], top=[])
        raw["slot_events"] = ACTION + FYI
        _, events = w.reduce("balance", None, raw)
        self.assertEqual(events, ACTION + FYI)

    def test_host_reduce_ignores_slot_events(self):
        raw = dict(free=60, swap=0, procs=1, files=1, load=1.0, unreadable=[])
        raw["slot_events"] = ACTION
        _, events = w.reduce("host", None, raw)
        self.assertEqual(events, ACTION)

    def test_policy_keeps_each_slot_line_as_a_one_shot_alert(self):
        for line in ACTION + FYI:
            [item] = alert_policy.facts(dict(mode="balance", events=[line]))
            self.assertEqual(item["kind"], "alert", line)
            self.assertTrue(item["terminal"], line)
            self.assertTrue(item["text"].startswith("SLOT "), line)

    def test_kill_and_long_run_lines_are_actions_wait_and_fail_are_fyi(self):
        actions, fyi = feed_actions.action_patterns(), feed_actions.fyi_patterns()
        for line in ACTION:
            self.assertTrue(feed_actions.is_action(feed(line), actions), line)
            self.assertFalse(feed_actions.is_action(feed(line), fyi), line)
        for line in FYI:
            self.assertFalse(feed_actions.is_action(feed(line), actions), line)
            self.assertTrue(feed_actions.is_action(feed(line), fyi), line)

    def test_each_kind_matches_its_pattern_alone(self):
        for kind, patterns in (
            ("KILLED", feed_actions.action_patterns()),
            ("RUNLONG", feed_actions.action_patterns()),
            ("WAIT", feed_actions.fyi_patterns()),
            ("FAIL", feed_actions.fyi_patterns()),
        ):
            line = feed(f"SLOT {kind} agent-x pid=1 note=-")
            self.assertTrue(feed_actions.is_action(line, patterns), kind)
        other = feed("SLOT DONE agent-x pid=1 note=-")
        for patterns in (feed_actions.action_patterns(), feed_actions.fyi_patterns()):
            self.assertFalse(feed_actions.is_action(other, patterns))

    def test_slot_text_from_another_mode_is_not_an_action(self):
        line = "2026-10-27T12:00:00+00:00 audit: SLOT KILLED a-b pid=1 note=- (start)"
        self.assertFalse(feed_actions.is_action(line, feed_actions.action_patterns()))

    def test_heavy_slot_lines_reach_the_balance_reducer(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(
                os.environ,
                ORCH_HEAVY_SLOTS_DIR=tmp,
                ORCH_HEAVY_SLOTS_MAX="4",
                HOME=tmp,
            )
            subprocess.run(
                [HEAVY_SLOT, "take", "agent-fail", "--note", "unit run", "--", "false"],
                env=env,
                check=False,
            )
            raw = dict(free=60, load5=1.0, slots=0, heavy=0, unreadable=[], top=[])
            raw["slot_events"], _ = watcher_platform.take_slot_events(tmp)
            _, events = w.reduce("balance", None, raw)
            [line] = events
            self.assertRegex(
                line,
                r"^SLOT FAIL agent-fail pid=\d+ code=1 elapsed=\d+s note=unit run$",
            )
