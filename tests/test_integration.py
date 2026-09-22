"""Native panel/project/simulation contracts and reversible schematic editing."""
import os
from pathlib import Path
import tempfile
import tkinter as tk
import unittest

ROOT = Path(__file__).resolve().parents[1]
TEST_TMP_ROOT = Path(os.environ.get('ANALOG_LENS_TEST_TMP', str(ROOT.parent)))


@unittest.skipUnless(os.environ.get('DISPLAY'), 'Native integration UI needs X11')
class Integration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT)
        self.directory = Path(self.temp.name)
        for name in ('a.sch', 'b.sch'):
            (self.directory/name).write_text('Fixture schematic '+name)
        (self.directory/'xschemrc').write_text('# fixture')
        self.app = tk.Tk(); self.app.geometry('1000x700')
        self.c = self.app.tk.call
        self.c('source', str(ROOT/'tests/mock_xschem.tcl'))
        self.c('source', str(ROOT/'tests/integration_fixture.tcl'))
        self.c('set', '::hostfixture::top', str(self.directory/'a.sch'))
        self.c('set', '::netlist_dir', str(self.directory))
        self.c('set', '::env(PDK)', 'gf180mcuD')
        self.c('set', '::mock::selection', 'M1')
        self.c('frame', '.drw', '-width', 600, '-height', 600)
        self.c('pack', '.drw', '-side', 'right', '-fill', 'both', '-expand', 1)
        self.c('source', str(ROOT/'analog_lens.tcl'))
        self.call('project_sync')
        self.call('show'); self.c('after', 'cancel', self.get('timer')); self.set('timer', '')
        self.call('refresh'); self.app.update()

    def tearDown(self):
        if self.get('integration_timer'):
            self.c('after', 'cancel', self.get('integration_timer'))
        if self.c('winfo', 'exists', '.analog_lens'):
            self.call('close_window')
        self.app.destroy(); self.temp.cleanup()

    def call(self, name, *args):
        return self.c('::analog_lens::'+name, *args)

    def get(self, name):
        return self.c('set', '::analog_lens::'+name)

    def set(self, name, value):
        return self.c('set', '::analog_lens::'+name, value)

    def load_compatible(self):
        text = (ROOT/'examples/lookup-template.csv').read_text().replace('DEMO_ONLY', 'gf180mcuD').replace('nfet_demo', 'nfet_03v3')
        # Use a controlled fixture, never publish these as characterized PDK data.
        lines = text.splitlines(); header = lines[0].split(',')
        import csv, io
        rows = list(csv.DictReader(io.StringIO(text)))
        for r in rows:
            r['pdk'] = 'gf180mcuD'; r['model'] = 'nfet_03v3'
        out = io.StringIO(); writer = csv.DictWriter(out, fieldnames=header); writer.writeheader(); writer.writerows(rows)
        path = self.directory/'fixture.csv'; path.write_text(out.getvalue())
        self.set('lut_file', str(path)); self.set('lut_rows', self.call('parse_lut', out.getvalue()))
        self.call('rebuild_lookup_filters')
        self.set('target_length', '0.3'); self.set('target_gmid', '16'); self.set('target_gm_u', '800')
        return path

    def test_sidebar_embeds_collapses_and_reopens_without_losing_metrics(self):
        self.call('show_sidebar'); self.app.update()
        panel = str(self.get('sidebar'))
        self.assertEqual(self.c('winfo', 'toplevel', panel), '.')
        self.assertLess(int(self.c('winfo', 'width', panel)), int(self.c('winfo', 'width', '.drw')))
        self.assertIn('800', self.c(panel+'.metrics', 'get', '1.0', 'end'))
        self.call('hide_sidebar'); self.call('show_sidebar'); self.app.update()
        self.assertIn('800', self.c(panel+'.metrics', 'get', '1.0', 'end'))
        self.call('close_window'); self.assertTrue(self.c('winfo', 'exists', panel))

    def test_unmapped_window_does_not_save_invalid_one_pixel_geometry(self):
        self.call('close_window')
        self.set('session_geometry', '')
        self.call('show')
        data = self.call('session_data')
        self.call('validate_session', data)
        self.assertNotEqual(str(self.c('dict', 'get', data, 'geometry')), '1x1')

    def test_large_text_lookup_actions_wrap_without_clipping(self):
        self.call('close_window')
        for font in ('TkDefaultFont', 'TkTextFont', 'TkFixedFont'):
            self.c('font', 'configure', font, '-size', 14)
        self.call('show'); self.c('wm', 'geometry', '.analog_lens', '900x640')
        self.c('.analog_lens.tabs', 'select', '.analog_lens.tabs.lut'); self.app.update()
        self.call('fit_lookup_layout'); self.app.update()
        for name in ('load', 'characterize', 'metric', 'sizing', 'data'):
            w = '.analog_lens.tabs.lut.tools.'+name
            self.assertGreaterEqual(int(self.c('winfo', 'width', w)), int(self.c('winfo', 'reqwidth', w))-2)
            self.assertLessEqual(int(self.c('winfo', 'rootx', w))+int(self.c('winfo', 'width', w)), int(self.c('winfo', 'rootx', '.analog_lens'))+900)

    def test_project_switch_restores_targets_and_baselines_and_restart(self):
        self.c('dict', 'set', '::analog_lens::limits', 'gmid_min', 7)
        self.set('baseline_name', 'Project A'); self.call('keep_baseline'); self.call('project_flush')
        saved = self.call('project_session_path', self.get('project_key'), str(self.directory))
        self.assertTrue(Path(saved).is_file())
        self.c('set', '::hostfixture::top', str(self.directory/'b.sch')); self.call('project_sync')
        self.assertEqual(str(self.get('baselines')), '')
        self.c('dict', 'set', '::analog_lens::limits', 'gmid_min', 8)
        self.c('set', '::hostfixture::top', str(self.directory/'a.sch')); self.call('project_sync')
        self.assertEqual(float(self.c('dict', 'get', self.get('limits'), 'gmid_min')), 7)
        self.assertEqual(self.get('baseline_choice'), 'Project A')
        self.call('project_flush'); self.set('project_key', ''); self.set('project_memory', '')
        self.call('project_sync')
        self.assertEqual(self.get('baseline_choice'), 'Project A')

    def test_corrupt_autosession_is_preserved(self):
        key = str(self.directory/'b.sch')
        path = Path(self.call('project_session_path', key, str(self.directory)))
        path.parent.mkdir(parents=True, exist_ok=True); path.write_text('not a session')
        self.c('set', '::hostfixture::top', key); self.call('project_sync'); self.call('project_flush')
        self.assertEqual(path.read_text(), 'not a session')
        self.assertIn('attention', self.get('project_message'))

    def test_native_saves_preserve_controls_and_are_idempotent(self):
        deck = 'title\n.param bias=1\n.control\nalterparam bias=2\nop\nwrite a.raw\n.endc\n.end\n'
        once = self.call('native_deck', deck, '.save @m.xm1.m0[gm]')
        self.assertIn('.control\nalterparam bias=2\nop\nwrite a.raw\n.endc', once)
        self.assertEqual(once, self.call('native_deck', once, '.save @m.xm1.m0[gm]'))

    def test_native_completion_retains_callback_and_loads_only_changed_raw(self):
        self.app.tk.eval('proc simulate {{callback {}}} {set ::callback_kept $callback; set ::execute(pipe,42) fixture; return 42}')
        self.c('trace', 'add', 'execution', 'simulate', 'enter', '::analog_lens::native_enter')
        self.c('trace', 'add', 'execution', 'simulate', 'leave', '::analog_lens::native_leave')
        self.c('simulate', 'set ::my_callback 1')
        raw = self.directory/'a.raw'; raw.write_text('Title: fixture\nPlotname: Operating Point\nnew raw fixture')
        self.c('set', '::execute(exitcode,42)', 0); self.c('unset', '::execute(pipe,42)'); self.app.update()
        self.assertEqual(self.c('set', '::callback_kept'), 'set ::my_callback 1')
        self.assertEqual(str(self.c('set', '::mock::raw_file')), str(raw))
        self.assertIn('Loaded', self.get('native_message'))
        self.c('simulate'); self.c('set', '::execute(exitcode,42)', 0); self.c('unset', '::execute(pipe,42)'); self.app.update()
        self.assertIn('No unique new raw', self.get('native_message'))

    def test_failed_native_run_keeps_previous_results(self):
        self.call('native_enter', 'simulate', 'enter'); self.call('native_leave', 'simulate', 0, 42, 'leave')
        before = self.c('set', '::mock::raw_file')
        self.c('set', '::execute(exitcode,42)', 1); self.app.update()
        self.assertEqual(before, self.c('set', '::mock::raw_file'))
        self.assertIn('not complete successfully', self.get('native_message'))

    def test_native_freshness_uses_netlist_state_not_later_schematic_edits(self):
        self.call('start_integration')
        self.c('xschem', 'netlist')
        original = self.call('design_stamp')
        key = self.get('project_key')
        self.c('dict', 'incr', '::analog_lens::edit_revisions', key)
        self.call('native_enter', 'simulate', 'enter')
        job = self.c('lindex', self.get('native_stack'), 'end')
        self.assertEqual(self.c('dict', 'get', job, 'metadata', 'design_stamp'), original)
        self.assertNotEqual(original, self.call('design_stamp'))
        # Externally changed decks have no verifiable schematic stamp.
        deck = self.directory/'a.spice'
        deck.write_text(deck.read_text()+'\n* changed outside xschem\n')
        self.call('native_enter', 'simulate', 'enter')
        job = self.c('lindex', self.get('native_stack'), 'end')
        self.assertEqual(str(self.c('dict', 'get', job, 'metadata', 'design_stamp')), '')

    def test_cursor_follows_nonuniform_samples_and_retains_provenance(self):
        self.c('set', '::hostfixture::rawtype', 'tran'); self.set('result_metadata', '')
        self.call('refresh')
        self.c('dict', 'set', '::analog_lens::result_metadata', 'design_stamp', self.call('design_stamp'))
        self.c('dict', 'set', '::analog_lens::integration_options', 'follow_cursor', 1)
        self.c('set', '::hostfixture::cursor', .8); self.call('follow_cursor')
        self.assertEqual(int(self.get('sample')), 2)
        self.assertEqual(self.c('dict', 'get', self.get('result_metadata'), 'design_stamp'), self.call('design_stamp'))
        self.c('set', '::hostfixture::cursor', .1); self.call('follow_cursor')
        self.assertEqual(int(self.get('sample')), 0)
        self.c('set', '::hostfixture::axis', (1, .25, 0)); self.set('cursor_key', '')
        self.call('follow_cursor'); self.assertEqual(int(self.get('sample')), 2)

    def test_sizing_is_one_undo_and_rejects_changed_preview(self):
        self.load_compatible(); self.call('refresh')
        before = self.c('set', '::hostfixture::props')
        self.set('size_plan', self.call('make_size_plan'))
        self.c('set', '::mock::selection', 'M2')
        with self.assertRaises(tk.TclError): self.call('apply_size_plan')
        self.c('set', '::mock::selection', 'M1')
        self.set('target_gm_u', 900)
        with self.assertRaises(tk.TclError): self.call('apply_size_plan')
        self.assertEqual(before, self.c('set', '::hostfixture::props'))
        self.set('target_gm_u', 800); self.set('size_plan', self.call('make_size_plan'))
        self.call('apply_size_plan')
        self.assertEqual(int(self.c('set', '::hostfixture::pushes')), 1)
        self.assertEqual(self.c('dict', 'get', self.c('set', '::hostfixture::props'), 'nf'), 1)
        self.c('xschem', 'undo'); self.assertEqual(before, self.c('set', '::hostfixture::props'))

    def test_unknown_model_and_wrong_pdk_cannot_be_applied(self):
        self.load_compatible()
        self.c('set', '::env(PDK)', 'sky130A')
        with self.assertRaises(tk.TclError): self.call('make_size_plan')
        self.c('set', '::env(PDK)', 'gf180mcuD')
        self.c('dict', 'set', '::hostfixture::props', 'model', 'custom_model')
        with self.assertRaises(tk.TclError): self.call('make_size_plan')

    def test_known_measured_bias_mismatch_cannot_be_applied(self):
        self.load_compatible()
        self.c('dict', 'set', '::mock::vectors', 'v(vd)', .8)
        self.call('refresh')
        with self.assertRaises(tk.TclError): self.call('make_size_plan')

    def test_lookup_bias_uses_external_terminals_not_intrinsic_model_voltage(self):
        self.load_compatible()
        self.c('dict', 'set', '::mock::vectors', 'v(@m.xm1.m0[vds])', .8999)
        self.call('refresh')
        self.call('make_size_plan')

    def test_matching_lookup_selection_does_not_guess_between_biases(self):
        self.load_compatible(); self.call('auto_select_lookup')
        self.assertIn('Compatible', self.get('lookup_match_message'))
        self.c('dict', 'set', '::analog_lens::declared', 'corner', 'ss')
        self.set('result_metadata', ''); self.set('lookup_match_key', '')
        self.call('auto_select_lookup')
        self.assertIn('No compatible', self.get('lookup_match_message'))

    def test_characterization_completion_loads_csv_and_autosaves_project(self):
        path = self.load_compatible()
        self.call('characterize_dialog')
        self.set('lut_rows', ''); self.set('lut_file', '')
        self.set('char_output', str(path)); self.set('char_project', self.get('project_key'))
        self.set('char_state', 'running')
        # Exercise the actual EOF/completion handler with a real pipe and
        # fixture CSV. These values remain explicitly test data.
        channel = self.c('open', ('|', 'cat', str(path), '2>@1'), 'r')
        self.set('char_channel', channel)
        self.call('characterization_readable')
        self.assertEqual(self.get('char_state'), 'completed', self.get('char_log'))
        self.assertEqual(self.get('lut_file'), str(path))
        self.assertGreater(int(self.c('llength', self.get('lut_rows'))), 0)
        self.assertIn('Loaded', self.get('char_status'))
        session = self.call('project_session_path', self.get('project_key'), str(self.directory))
        self.assertTrue(Path(session).is_file())
