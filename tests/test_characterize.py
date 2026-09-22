"""Characterization parsing, request limits and real subprocess cancellation."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEST_TMP_ROOT = Path(os.environ.get('ANALOG_LENS_TEST_TMP', str(ROOT.parent)))
sys.path.insert(0, str(ROOT/'tools'))
from characterize import make_deck, parse_ascii_sweep, validate_request


class Characterization(unittest.TestCase):
    def request(self, **changes):
        values = dict(pdk='sky130A', model='pfet_01v8', corner=None, width=10., temp=27.,
                      vds=None, vsb=0., vgs_start=.1, vgs_stop=None, vgs_step=.05, lengths=[.5, 1.])
        values.update(changes)
        return argparse.Namespace(**values)

    def test_pmos_polarity_width_and_body_bias_are_explicit(self):
        args = self.request(vsb=-.1); validate_request(args)
        deck, _, _, _ = make_deck(args, Path('/installed/sky130A'), .5, 'sweep.raw')
        self.assertIn('vd d 0 -0.9', deck)
        self.assertIn('vb b 0 0.1', deck)
        self.assertIn('dc vg -0.1 -1.8 -0.05', deck)
        self.assertIn('w=10 l=0.5', deck)
        self.assertIn('write sweep.raw', deck)

    def test_rejects_invalid_profile_limits_and_injected_corner(self):
        for changes in ({'model':'custom'}, {'corner':'tt\n.end'}, {'lengths':[.1]},
                        {'vds':.9}, {'width':float('inf')}, {'vgs_step':.00000001}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_request(self.request(**changes))

    def test_all_ascii_points_are_parsed_and_truncation_rejected(self):
        raw = ('Title: fixture\nFlags: real\nNo. Variables: 2\nNo. Points: 2\nVariables:\n'
               '0 v(v-sweep) voltage\n1 i(@m.xm1.m0[id]) current\nValues:\n0 0.1\n-1e-6\n1 0.2\n-2e-6\n')
        points = parse_ascii_sweep(raw)
        self.assertEqual(points[1]['@m.xm1.m0[id]'], -2e-6)
        with self.assertRaises(ValueError): parse_ascii_sweep(raw.rsplit('-2e-6', 1)[0])

    def test_cancel_stops_ngspice_child_and_does_not_publish_csv(self):
        with tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT) as temp:
            base = Path(temp); (base/'pdks/sky130A').mkdir(parents=True)
            binary = base/'ngspice'; pidfile = base/'child.pid'
            binary.write_text('#!'+sys.executable+'\nimport os,time\nfrom pathlib import Path\n'
                              f'Path({str(pidfile)!r}).write_text(str(os.getpid()))\ntime.sleep(30)\n')
            binary.chmod(0o755)
            output = base/'out.csv'
            env = dict(os.environ, PATH=str(base)+os.pathsep+os.environ['PATH'])
            process = subprocess.Popen([sys.executable, str(ROOT/'tools/characterize.py'), '--pdk', 'sky130A',
                                        '--model', 'nfet_01v8', '--pdk-root', str(base/'pdks'), '--lengths', '.5',
                                        '--output', str(output)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            try:
                until = time.monotonic()+5
                while not pidfile.exists() and time.monotonic() < until: time.sleep(.02)
                self.assertTrue(pidfile.exists())
                child = int(pidfile.read_text()); process.send_signal(signal.SIGTERM)
                log, _ = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 130, log)
                self.assertFalse(Path(f'/proc/{child}').exists(), 'ngspice child survived cancellation')
                self.assertFalse(output.exists())
            finally:
                if process.poll() is None: process.kill(); process.communicate()
