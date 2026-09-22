"""Session integrity, provenance, comparison, and actual Linux child-process tests."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import tkinter
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEST_TMP_ROOT = Path(os.environ.get("ANALOG_LENS_TEST_TMP", str(ROOT.parent)))


class Workflow(unittest.TestCase):
    def setUp(self):
        self.t = tkinter.Tcl()
        self.t.call('source', str(ROOT / 'tests/mock_xschem.tcl'))
        self.t.call('source', str(ROOT / 'analog_lens.tcl'))
        self.t.eval('rename ::analog_lens::render {}; proc ::analog_lens::render {} {}; '
                    'rename ::analog_lens::update_run_controls {}; proc ::analog_lens::update_run_controls {} {}')
        self.call('refresh')

    def call(self, name, *args):
        return self.t.call('::analog_lens::' + name, *args)

    def get(self, name):
        return self.t.getvar('::analog_lens::' + name)

    def set(self, name, value):
        self.t.setvar('::analog_lens::' + name, value)

    def pump_until(self, predicate, timeout=5):
        until = time.monotonic() + timeout
        while not predicate() and time.monotonic() < until:
            self.t.eval('update')
            time.sleep(.01)
        self.assertTrue(predicate(), 'Timed out waiting for child process')

    def test_session_roundtrip_with_named_baselines_and_literal_text(self):
        name = '[set ::injected 1]; $HOME'
        self.set('baseline_name', name)
        self.call('keep_baseline')
        with tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT) as temp:
            path = Path(temp) / 'saved.alsession'
            self.call('save_session', str(path))
            self.set('baselines', '')
            self.set('baseline_choice', '')
            self.call('open_session', str(path))
            self.assertEqual(self.get('baseline_choice'), name)
            self.assertEqual(len(self.get('snapshot')), 2)
            self.assertEqual(self.t.call('info', 'exists', '::injected'), 0)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(Path(temp).glob('*.tmp')), [])

    def test_corrupt_session_does_not_change_existing_state(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT) as temp:
            path = Path(temp) / 'saved.alsession'
            self.call('save_session', str(path))
            self.t.setvar('data', path.read_text())
            self.t.eval('dict set data limits gmid_max bogus')
            path.write_text(str(self.t.eval('set data')))
            before = str(self.get('limits'))
            with self.assertRaises(tkinter.TclError):
                self.call('open_session', str(path))
            self.assertEqual(str(self.get('limits')), before)

    def test_duplicate_baseline_names_are_preserved(self):
        for _ in range(2):
            self.set('baseline_name', 'bias A')
            self.call('keep_baseline')
        self.assertEqual(self.t.call('dict', 'keys', self.get('baselines')), ('bias A', 'bias A (2)'))

    def test_comparison_tracks_added_removed_and_signed_current(self):
        self.t.eval('''
            set a [dict create name M1 model p hierarchy {} values [dict create id -2e-5 gmid 10]]
            set b [dict create name M1 model p hierarchy {} values [dict create id -3e-5 gmid 15]]
            set gone [dict create name M2 model n hierarchy {} values {}]
            set added [dict create name M3 model n hierarchy {} values {}]
            set comparison [::analog_lens::comparison_data [list $a $gone] [list $b $added]]
        ''')
        rows = self.t.getvar('comparison')
        self.assertEqual([self.t.call('dict', 'get', row, 'state') for row in rows], ['Matched', 'Removed', 'Added'])
        self.assertAlmostEqual(float(self.t.call('dict', 'get', rows[0], 'change_id')), -1e-5)
        self.assertAlmostEqual(float(self.t.call('dict', 'get', rows[0], 'percent_gmid')), 50)

    def test_refresh_preserves_recorded_conditions(self):
        self.t.eval('dict set ::analog_lens::result_metadata corner tt; dict set ::analog_lens::declared corner ss')
        self.call('refresh')
        self.assertEqual(self.t.call('dict', 'get', self.get('result_metadata'), 'corner'), 'tt')

    def test_known_conditions_differ_unknown_are_not_invented(self):
        differences = self.call('condition_differences', 'corner tt temp_c 27 vds_v {}', 'corner ss temp_c 27.0 vds_v 0.9')
        self.assertEqual(differences, ('Corner: tt → ss',))

    def test_raw_sidecar_restores_conditions_and_rejects_stale_file(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT) as temp:
            raw = Path(temp) / 'saved.raw'
            raw.write_text('fixture data')
            metadata = self.call('capture_metadata')
            self.t.setvar('metadata', metadata)
            self.t.setvar('signature', self.call('file_signature', str(raw)))
            self.t.eval('dict set metadata raw $signature; dict set metadata corner ss')
            raw.with_suffix('.metadata').write_text(self.t.eval('set metadata'))
            self.call('read_results', str(raw), 'op')
            self.assertEqual(self.t.call('dict', 'get', self.get('result_metadata'), 'corner'), 'ss')
            raw.write_text('different fixture data, so this is a different result')
            self.call('read_results', str(raw), 'op')
            self.assertEqual(str(self.get('result_metadata')), '')

    def test_linux_cancel_escalates_and_keeps_previous_results(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT) as temp:
            directory = Path(temp)
            exe = directory / 'ngspice'
            exe.write_text('#!' + sys.executable + '\nimport signal,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nprint("ready",flush=True)\ntime.sleep(30)\n')
            exe.chmod(0o755)
            old_path = self.t.getvar('env(PATH)')
            self.t.setvar('env(PATH)', str(directory) + os.pathsep + old_path)
            self.t.setvar('netlist_dir', str(directory))
            before = self.get('records')
            unrelated = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
            try:
                self.call('run_op')
                self.pump_until(lambda: 'ready' in str(self.get('run_log')))
                self.call('cancel_run')
                self.assertEqual(self.get('run_state'), 'cancelling')
                self.pump_until(lambda: not int(self.t.call('string', 'length', self.get('run_channel'))))
                self.assertEqual(self.get('run_state'), 'cancelled')
                self.assertEqual(self.get('records'), before)
                self.assertIn('Partial results were not loaded', str(self.get('run_log')))
                self.assertIsNone(unrelated.poll())
            finally:
                if int(self.t.call('string', 'length', self.get('run_channel'))):
                    self.call('signal_run', 'KILL')
                    self.pump_until(lambda: not int(self.t.call('string', 'length', self.get('run_channel'))))
                unrelated.terminate(); unrelated.wait(timeout=5)
                self.t.setvar('env(PATH)', old_path)

    def test_segment_clipping(self):
        clipped = self.call('clip_segment', -10, 5, 20, 5, (0, 10, 0, 10))
        self.assertEqual(tuple(map(float, clipped)), (0, 5, 10, 5))
        self.assertEqual(str(self.call('clip_segment', -1, -1, -2, -2, (0, 10, 0, 10))), '')

    def test_observed_conditions_override_conflicting_declarations(self):
        meta = self.t.call('dict', 'create', 'corner', 'ss', 'temp_c', 85,
                           'observed_conditions', self.t.call('dict', 'create', 'corner', 'tt', 'temp_c', 27))
        actual = self.call('recorded_conditions', meta)
        self.assertEqual(self.t.call('dict', 'get', actual, 'corner'), 'tt')
        self.assertEqual(int(self.t.call('dict', 'get', actual, 'temp_c')), 27)


if __name__ == '__main__':
    unittest.main()
