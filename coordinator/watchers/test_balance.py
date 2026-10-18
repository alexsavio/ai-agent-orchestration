import os
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

from test_support import IsolatedTestCase
from watcher_platform import LinuxBalance, MacBalance, balance_metrics, worktree_totals
from watchers import reduce, cycle, BALANCE_LIMITS


def own_ps(text):
    return "\n".join(row + " " + str(os.getuid()) for row in text.splitlines())


class BalanceTests(IsolatedTestCase):
    def healthy(self):
        return dict(load5=20, slots=4, heavy=4, free=30, top=[])

    def test_each_boundary(self):
        self.assertEqual(reduce('balance', None, self.healthy())[1], [])
        for key, value, label in [('load5', 20.01, 'LOAD5'), ('slots', 5, 'SLOTS'),
                                  ('heavy', 5, 'HEAVYWT'), ('free', 29.99, 'MEMFREE')]:
            raw = self.healthy()
            raw[key] = value
            self.assertIn(label, reduce('balance', None, raw)[1][0])

    def test_steps_slots_dedup_and_recovery(self):
        raw = self.healthy()
        raw.update(load5=21, slots=5, top=[dict(name='busy', cpu=123, mb=456)])
        before, events = reduce('balance', None, raw)
        self.assertIn('busy(123%,456MB)', events[0])
        raw['load5'] = 29.99
        self.assertEqual(reduce('balance', before, raw)[1], [])
        raw['load5'] = 30
        before, events = reduce('balance', before, raw)
        self.assertIn('LOAD5(30.00)', events[0])
        raw['slots'] = 6
        before, events = reduce('balance', before, raw)
        self.assertIn('SLOTS(6)', events[0])
        self.assertEqual(reduce('balance', before, self.healthy())[1], ['BALANCE RECOVERED'])

    def test_missing_active_metrics_and_processes_prevent_recovery(self):
        for key in ('load5', 'slots', 'heavy', 'free'):
            raw = self.healthy()
            raw[key] = 29 if key == 'free' else 30
            before, _ = reduce('balance', None, raw)
            raw = self.healthy()
            raw[key] = None
            before, events = reduce('balance', before, raw)
            self.assertIn('BALANCE READFAIL ' + key, events)
            self.assertNotIn('BALANCE RECOVERED', events)
            self.assertEqual(reduce('balance', before, raw)[1], [])
            other = 'slots' if key != 'slots' else 'load5'
            raw[other] = 31
            changed, events = reduce('balance', before, raw)
            self.assertTrue(any('unavailable' in event for event in events))
            events = reduce('balance', before, self.healthy())[1]
            self.assertIn('BALANCE RECOVERED', events)
        before, _ = reduce('balance', None, dict(self.healthy(), load5=21))
        before, events = reduce('balance', before, dict(self.healthy(), heavy=None, unreadable=['pid:7']))
        self.assertIn('BALANCE READFAIL heavy pid:7', events)
        self.assertNotIn('BALANCE RECOVERED', events)

    def test_all_missing_counts_failures(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw = dict.fromkeys(('load5', 'slots', 'heavy', 'free'))
            base = Path(tmp)
            cycle(base, 'balance', lambda _: raw)
            cycle(base, 'balance', lambda _: raw)
            self.assertIn('read failed 3 times', cycle(base, 'balance', lambda _: raw))

    def test_totals_sort_cpu_and_memory(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)/"worktrees"
            busy = base/"webapp/busy"
            (busy/"sub").mkdir(parents=True)
            (busy/".git").write_text("gitdir: /fixture/common/worktrees/busy\n")
            rows = [dict(cwd=str(busy/"sub"), cpu=40, rss=1024),
                    dict(cwd=str(busy), cpu=40, rss=2048),
                    dict(cwd=str(base/"other"), cpu=10, rss=1024)]
            totals = worktree_totals(rows)
            self.assertEqual(totals, [dict(name='busy', cpu=80, mb=3), dict(name='other', cpu=10, mb=1)])

    def test_linux_proc_cpu_cwd_and_isolated_bad_process(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp)
            (proc/'meminfo').write_text('MemTotal: 1000 kB\nMemAvailable: 300 kB\n')
            (proc/'loadavg').write_text('1 21 3')
            (proc/'uptime').write_text('100 0')
            slots = proc/'slots'
            slots.mkdir()
            values = ['0'] * 22
            values[0], values[11], values[19], values[21] = 'R', '8000', '0', '256'
            for pid in ('1', '2'):
                path = proc/pid
                path.mkdir()
                (path/'stat').write_text(pid+' (worker with spaces) '+ ' '.join(values))
                (path/'cwd').symlink_to('/repo/worktrees/busy/sub')
            adapter = LinuxBalance(proc, ticks=100)
            raw = balance_metrics(None, BALANCE_LIMITS, slots, adapter)
            self.assertEqual(raw['load5'], 21)
            self.assertEqual(raw['free'], 30)
            self.assertEqual(raw['heavy'], 1)
            before, _ = reduce('balance', None, raw)
            (proc/'uptime').write_text('101 0')
            for pid in ('1', '2'):
                values[11] = '8080'
                (proc/pid/'stat').write_text(pid+' (worker) '+ ' '.join(values))
            raw = balance_metrics(None, BALANCE_LIMITS, slots, adapter, before=before)
            self.assertEqual(raw['heavy'], 1)
            self.assertEqual(raw['top'], [dict(name='busy', cpu=160, mb=512 * os.sysconf('SC_PAGE_SIZE') / 1048576)])
            (proc/'2/stat').write_text('bad')
            before, _ = reduce('balance', before, raw)
            (proc/'uptime').write_text('102 0')
            values[11] = '8160'
            (proc/'1/stat').write_text('1 (worker) '+ ' '.join(values))
            raw = balance_metrics(None, BALANCE_LIMITS, slots, adapter, before=before)
            self.assertEqual(raw['heavy'], None)
            self.assertEqual(raw['unreadable'], ['pid:2'])
            self.assertEqual(raw['top'][0]['cpu'], 80)
            (proc/'meminfo').write_text('MemTotal: 0 kB\nMemAvailable: 0 kB\n')
            self.assertIsNone(balance_metrics(None, BALANCE_LIMITS, slots, adapter)['free'])
            (proc/'meminfo').unlink()
            raw = balance_metrics(None, BALANCE_LIMITS, proc/'absent', adapter)
            self.assertIsNone(raw['free'])
            self.assertEqual(raw['slots'], 0)
            self.assertEqual(raw['load5'], 21)

    def test_mac_cwd_mapping_without_command_path(self):
        def command(*args):
            return {('memory_pressure',): 'no metric',
                    ('sysctl', '-n', 'vm.loadavg'): '{ 1 21 3 }',
                    ('ps', '-U', str(os.getuid()), '-o', 'pid=,%cpu=,rss=,stat=,uid='): own_ps('7 80 1024 R\n8 20 2048 S\n9 1 10 R'),
                    ('lsof', '-n', '-d', 'cwd', '-Fpn'): 'p7\nn/repo/worktrees/busy\np8\nn/repo/worktrees/busy/sub'}[args]
        adapter = MacBalance()
        self.assertEqual(adapter.metrics(command), dict(free=None, load5=21))
        with patch("watcher_platform.process_alive", return_value=True):
            rows, errors = adapter.processes(command)
        self.assertEqual(errors, ['pid:9'])
        self.assertEqual(worktree_totals(rows), [dict(name='busy', cpu=100, mb=3)])

    def test_partial_process_scan_still_alerts_known_heavy_breach(self):
        class Adapter:
            def metrics(self, command):
                return dict(free=50, load5=1)
            def processes(self, command):
                return ([dict(cwd='/worktrees/job' + str(i), cpu=80, rss=1024)
                         for i in range(5)], ['pid:bad'])
        with tempfile.TemporaryDirectory() as tmp:
            raw = balance_metrics(None, BALANCE_LIMITS, Path(tmp), Adapter())
        self.assertEqual(raw['heavy'], 5)
        events = reduce('balance', None, raw)[1]
        self.assertIn('BALANCE READFAIL pid:bad', events)
        self.assertIn('HEAVYWT(5)', events[-1])

    def test_linux_kernel_threads_excluded_and_global_proc_failure_isolated(self):
        with tempfile.TemporaryDirectory() as tmp:
            proc = Path(tmp)
            (proc/'uptime').write_text('100 0')
            path = proc/'7'
            path.mkdir()
            values = ['0'] * 22
            values[0], values[6] = 'S', str(0x00200000)
            (path/'stat').write_text('7 (kernel) ' + ' '.join(values))
            adapter = LinuxBalance(proc, ticks=100)
            sample = adapter.sample(None)
            self.assertEqual((sample["rows"], sample["errors"]), ([], []))
            values[0], values[6] = 'Z', '0'
            (path/'stat').write_text('7 (zombie) ' + ' '.join(values))
            sample = adapter.sample(None)
            self.assertEqual((sample["rows"], sample["errors"]), ([], []))
            (proc/'uptime').write_text('bad')
            sample = adapter.sample(None)
            self.assertEqual((sample["rows"], sample["errors"]), ([], ['processes']))

    def test_mac_process_command_failure_keeps_metrics(self):
        import subprocess
        def command(*args):
            if args[0] == 'sysctl':
                return '{ 1 21 3 }'
            if args[0] == 'memory_pressure':
                return 'free percentage: 50%'
            raise subprocess.CalledProcessError(1, args)
        with tempfile.TemporaryDirectory() as tmp:
            raw = balance_metrics(command, BALANCE_LIMITS, Path(tmp), MacBalance())
        events = reduce('balance', None, raw)[1]
        self.assertIn('BALANCE READFAIL heavy processes', events)
        self.assertIn('LOAD5(21.00)', events[-1])

    def test_mac_exited_pid_skipped_permission_denied_pid_reported(self):
        def command(*args):
            if args[0] == 'ps':
                return own_ps('7 80 1024 R\n8 20 2048 S\n9 1 10 R')
            return 'p7\nn/repo/worktrees/busy'
        def signal(pid, sig):
            self.assertEqual(sig, 0)
            if pid == 8:
                raise ProcessLookupError()
            if pid == 9:
                raise PermissionError()
        with patch('watcher_platform.os.kill', side_effect=signal):
            rows, errors = MacBalance().processes(command)
        self.assertEqual(errors, ['pid:9'])
        self.assertEqual(worktree_totals(rows), [dict(name='busy', cpu=80, mb=1)])

    def test_slots_live_stale_invalid_and_partial_breach(self):
        from watcher_platform import live_slots
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory/'directory').mkdir()
            (directory/'live').write_text('101')
            (directory/'stale').write_text('102')
            (directory/'restricted').write_text('103')
            def signal(pid, sig):
                self.assertEqual(sig, 0)
                self.assertGreater(pid, 0)
                if pid > 2**31 - 1:
                    raise OverflowError()
                if pid == 102:
                    raise ProcessLookupError()
                if pid == 103:
                    raise PermissionError()
            with patch('watcher_platform.os.kill', side_effect=signal):
                self.assertEqual(live_slots(directory), (2, []))
                for value in ('garbage', '0', '-1', '9' * 100):
                    (directory/'bad').write_text(value)
                    self.assertEqual(live_slots(directory), (2, ['slot:bad']))
                for i in range(3):
                    (directory/str(i)).write_text(str(200 + i))
                self.assertEqual(live_slots(directory), (5, ['slot:bad']))

    def test_unreadable_slot_preserves_previous_slot_pressure(self):
        from watcher_platform import live_slots
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            slot = directory/'denied'
            slot.write_text('101')
            with patch.object(Path, 'read_text', side_effect=PermissionError()):
                count, errors = live_slots(directory)
            raw = dict(self.healthy(), slots=None, unreadable=errors)
            self.assertEqual(count, 0)
            before, _ = reduce('balance', None, dict(self.healthy(), slots=5))
            before, events = reduce('balance', before, raw)
            self.assertIn('BALANCE READFAIL slots slot:denied', events)
            self.assertNotIn('BALANCE RECOVERED', events)
            events = reduce('balance', before, self.healthy())[1]
            self.assertIn('BALANCE RECOVERED', events)

    def test_mac_zombie_skipped_before_liveness_probe(self):
        def command(*args):
            if args[0] == 'ps':
                return own_ps('7 80 1024 R\n8 0 0 Z+\n9 20 2048 S')
            return 'p7\nn/repo/worktrees/busy'
        adapter = MacBalance()
        with patch('watcher_platform.process_alive', return_value=True) as alive:
            rows, errors = adapter.processes(command)
        alive.assert_called_once_with(9)
        self.assertEqual(errors, ['pid:9'])
        self.assertEqual(worktree_totals(rows), [dict(name='busy', cpu=80, mb=1)])
