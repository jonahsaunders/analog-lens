"""Bias guidance, lookup integrity, precision, and asynchronous provenance."""
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import tkinter
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from lookup_provenance import inspect_lookup
from project_data import read_graph


class LookupTrust(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('ANALOG_LENS_TEST_TMP', ROOT.parent))
        self.path = Path(self.temp.name)
        self.csv = self.path/'lookup.csv'; self.csv.write_text('fixture data\n')
        self.model = self.path/'model.lib'; self.model.write_text('.param fixture=1\n')
        self.deck = self.path/'deck.spice'; self.deck.write_text('fixture\n.include model.lib\n')
        deps, _ = read_graph(self.deck, False)
        self.manifest = dict(format='analog-lens-characterization', schema=1, status='completed',
                             csv_sha256=hashlib.sha256(self.csv.read_bytes()).hexdigest(),
                             ngspice_version='fixture simulator', dependencies=[deps])
        self.save()

    def tearDown(self):
        self.temp.cleanup()

    def save(self):
        self.csv.with_suffix('.json').write_text(json.dumps(self.manifest))

    def state(self):
        return inspect_lookup(self.csv, 'fixture simulator')['state']

    def test_model_edit_same_size_and_deleted_dependency_invalidate(self):
        self.assertEqual(self.state(), 'verified')
        self.model.write_text('.param fixture=2\n')
        self.assertEqual(self.state(), 'outdated')
        self.model.unlink(); self.assertEqual(self.state(), 'outdated')

    def test_imported_unknown_simulator_and_partial_are_never_verified(self):
        self.assertEqual(inspect_lookup(self.csv)['state'], 'unverified')
        self.manifest['dependencies'][0]['warnings'] = ['unresolved source']; self.save()
        self.assertEqual(self.state(), 'unverified')
        self.csv.with_suffix('.json').unlink()
        self.assertEqual(self.state(), 'imported')

    def test_modified_csv_version_and_malformed_manifest_rejected(self):
        self.assertEqual(inspect_lookup(self.csv, 'new simulator')['state'], 'outdated')
        self.csv.write_text('changed data\n'); self.assertEqual(self.state(), 'outdated')
        self.csv.with_suffix('.json').write_text('[]'); self.assertEqual(self.state(), 'outdated')

    def test_batch_validates_each_source_and_cycles(self):
        combined = self.path/'combined.csv'; combined.write_bytes(self.csv.read_bytes())
        data = dict(format='analog-lens-batch', schema=1, status='completed',
                    csv_sha256=hashlib.sha256(combined.read_bytes()).hexdigest(), jobs=[dict(csv=str(self.csv))])
        manifest = combined.with_suffix('.batch.json'); manifest.write_text(json.dumps(data))
        self.assertEqual(inspect_lookup(combined, 'fixture simulator')['state'], 'verified')
        self.model.write_text('.param fixture=3\n')
        self.assertEqual(inspect_lookup(combined, 'fixture simulator')['state'], 'outdated')
        data['jobs'] = [dict(csv=str(combined))]; manifest.write_text(json.dumps(data))
        self.assertIn('Cyclic', inspect_lookup(combined)['reason'])


class Guidance(unittest.TestCase):
    def setUp(self):
        self.t = tkinter.Tcl(); self.t.call('source', str(ROOT/'analog_lens.tcl'))

    def call(self, name, *args):
        return self.t.call('::analog_lens::'+name, *args)

    def d(self, **values):
        return self.t.call('dict', 'create', *[x for pair in values.items() for x in pair])

    def test_interpolates_signed_vgs_and_preserves_missing(self):
        text = (ROOT/'examples/lookup-template.csv').read_text()
        rows = list(csv.DictReader(io.StringIO(text)))
        for i, row in enumerate(rows): row['vgs_v'] = str(-.5-i*.1)
        output = io.StringIO(); writer = csv.DictWriter(output, fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
        parsed = self.call('parse_lut', output.getvalue())
        slice_ = self.t.call('dict', 'get', parsed[0], 'slice')
        result = self.call('sizing', parsed, slice_, .3, 16, 800)
        self.assertLess(float(self.t.call('dict', 'get', result, 'required_vgs')), 0)
        old = self.call('parse_lut', text)
        result = self.call('sizing', old, slice_, .3, 16, 800)
        self.assertEqual(str(self.t.call('dict', 'get', result, 'required_vgs')), '')

    def test_target_display_never_rounds_canonical_value(self):
        precise = 4.434420002066099
        self.t.setvar('::analog_lens::target_gmid', precise)
        self.assertEqual(float(self.t.getvar('::analog_lens::target_gmid')), precise)
        self.assertEqual(str(self.t.getvar('::analog_lens::target_display(target_gmid)')), '4.43442')
        self.t.setvar('::analog_lens::target_display(target_gmid)', '12.5')
        self.assertEqual(float(self.t.getvar('::analog_lens::target_gmid')), 12.5)

    def test_diagnosis_distinguishes_bias_shift_rounding_and_scaling(self):
        plan = self.d(result=self.d(required_vgs=-.7, width=20), geometry=self.d(total_width=20),
                      slice=('pdk','pfet','tt',27,-.9,0,10))
        bias = self.call('sizing_diagnosis', plan, self.d(terminal_vgs=-.9, terminal_vds=-.9), 'Miss')
        self.assertIn('Gate bias differs', bias)
        shifted = self.call('sizing_diagnosis', plan, self.d(terminal_vgs=-.7, terminal_vds=-.5), 'Miss')
        self.assertIn('Vds shifted', shifted)
        scaling = self.call('sizing_diagnosis', plan, self.d(terminal_vgs=-.7, terminal_vds=-.9), 'Miss')
        self.assertIn('Width scaling', scaling)
        rounded = self.t.call('dict', 'replace', plan, 'geometry', self.d(total_width=21))
        self.assertIn('rounding', self.call('sizing_diagnosis', rounded, self.d(terminal_vgs=-.7), 'Miss'))

    def test_old_async_results_cannot_overwrite_newer_check(self):
        self.t.setvar('::analog_lens::dependency_cache', self.d(path='new', token=2, result=self.d(state='current')))
        self.call('dependency_checked', 'old', 1, self.d(state='changed'))
        self.assertEqual(self.t.call('dict', 'get', self.t.getvar('::analog_lens::dependency_cache'), 'path'), 'new')

    def test_lookup_index_invalidates_on_replacement(self):
        rows = self.call('parse_lut', (ROOT/'examples/lookup-template.csv').read_text())
        self.t.setvar('::analog_lens::lut_rows', rows)
        first = self.call('lookup_index')
        self.assertGreater(int(self.t.call('dict', 'size', first)), 0)
        self.t.setvar('::analog_lens::lut_rows', '')
        self.assertEqual(int(self.t.call('dict', 'size', self.call('lookup_index'))), 0)
