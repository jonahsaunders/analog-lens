"""Native Tk interaction tests. Run under Xvfb; no xschem/PDK is required."""
from pathlib import Path
import os
import tkinter as tk
import unittest
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TEST_TMP_ROOT = Path(os.environ.get("ANALOG_LENS_TEST_TMP", str(ROOT.parent)))
W = '.analog_lens'


@unittest.skipUnless(os.environ.get('DISPLAY'), 'Native Tk tests require an X11 display')
class NativeGUI(unittest.TestCase):
    def setUp(self):
        self.app = tk.Tk()
        self.app.withdraw()
        self.c = self.app.tk.call
        self.c('source', str(ROOT / 'tests/mock_xschem.tcl'))
        self.c('source', str(ROOT / 'analog_lens.tcl'))
        self.c('tk', 'scaling', 1.3333333333)
        self.c('ttk::style', 'theme', 'use', 'clam')
        self.original_theme = self.c('ttk::style', 'theme', 'use')
        self.c('::analog_lens::show')
        self.c('after', 'cancel', self.get('timer'))
        self.set('timer', '')
        self.set('live', 0)
        self.app.update()

    def tearDown(self):
        self.set('run_channel', '')
        if self.c('winfo', 'exists', W):
            self.call('close_window')
        self.app.destroy()

    def call(self, name, *args):
        return self.c('::analog_lens::' + name, *args)

    def get(self, name):
        return self.c('set', '::analog_lens::' + name)

    def set(self, name, value):
        self.c('set', '::analog_lens::' + name, value)

    def settle(self):
        done = tk.BooleanVar(self.app, False)
        self.app.after(150, done.set, True)
        self.app.wait_variable(done)
        self.app.update()

    def load_lut(self):
        self.c('rename', 'tk_getOpenFile', 'native_file_dialog')
        self.app.createcommand('tk_getOpenFile', lambda *args: str(ROOT / 'examples/lookup-template.csv'))
        try:
            self.call('load_lut')
        finally:
            self.app.deletecommand('tk_getOpenFile')
            self.c('rename', 'native_file_dialog', 'tk_getOpenFile')

    def test_sort_toggle_refresh_selection_and_missing_last(self):
        tree = W + '.tabs.op.panes.list.tree'
        self.c(tree, 'selection', 'set', 'd1')
        self.call('inspect_selection')
        self.call('sort_table', 'gmid')
        self.assertEqual(self.c(tree, 'children', ''), ('d1', 'd0'))
        self.call('sort_table', 'gmid')
        self.assertEqual(self.c(tree, 'children', ''), ('d0', 'd1'))
        self.call('refresh')
        self.assertEqual(self.c(tree, 'children', ''), ('d0', 'd1'))
        self.assertEqual(self.c(tree, 'selection'), ('d1',))
        for _ in range(2):
            self.call('sort_table', 'margin')
            self.assertEqual(self.c(tree, 'children', '')[-1], 'd1')

    def test_filtered_empty_state_clears_stale_details(self):
        self.set('search', 'no-such-device')
        self.call('render')
        self.assertIn('No matching', self.get('empty_text'))
        self.assertEqual(self.c(W + '.tabs.op.panes.detail.text', 'get', '1.0', 'end-1c'), '')
        self.assertTrue(self.c(W + '.tabs.op.panes.detail.locate', 'instate', 'disabled'))
        self.call('clear_search')
        self.assertEqual(len(self.c(W + '.tabs.op.panes.list.tree', 'children', '')), 2)
        self.assertFalse(self.c(W + '.tabs.op.panes.detail.locate', 'instate', 'disabled'))

    def test_invalid_targets_are_atomic_and_recover(self):
        before = self.get('limits')
        self.set('edit_limits(gmid_min)', '30')
        self.call('apply_targets')
        self.assertEqual(self.get('limits'), before)
        self.assertIn('less than', self.get('targets_message'))
        self.set('edit_limits(gmid_min)', '6')
        self.call('apply_targets')
        self.assertEqual(float(self.c('dict', 'get', self.get('limits'), 'gmid_min')), 6)
        self.assertIn('applied', self.get('targets_message'))

    def test_sizing_validation_invalidation_and_data_table(self):
        self.load_lut()
        self.set('target_gmid', '16')
        self.set('target_gm_u', '800')
        self.call('calculate_size')
        self.assertIn('50 µA', self.get('sizing_text'))
        self.set('target_gm_u', '900')
        self.assertEqual(str(self.get('sizing_text')), '')
        self.set('target_gmid', 'abc')
        self.call('calculate_size')
        self.assertIn('greater than zero', self.get('sizing_error'))
        self.assertEqual(str(self.get('sizing_text')), '')
        self.call('data_dialog')
        tree = W + '.data.root.table.tree'
        self.assertEqual(len(self.c(tree, 'children', '')), 6)
        self.call('copy_table', tree)
        copied = self.c('clipboard', 'get')
        self.assertIn('Intrinsic gain (V/V)', copied)
        self.assertEqual(len(copied.splitlines()), 7)

    def test_busy_state_and_live_log(self):
        self.set('run_channel', 'fixture-busy')
        self.call('update_run_controls')
        self.app.update()
        for name in ['run', 'load', 'refresh', 'export']:
            self.assertTrue(self.c(W + '.root.tools.' + name, 'instate', 'disabled'))
        self.assertTrue(self.c('winfo', 'ismapped', W + '.root.progress'))
        self.call('log_dialog')
        self.set('run_log', 'first line\n')
        self.c('append', '::analog_lens::run_log', 'second line\n')
        self.assertEqual(self.c(W + '.log.text', 'get', '1.0', 'end-1c'), 'first line\nsecond line\n')
        self.set('run_channel', '')
        self.call('update_run_controls')
        self.assertFalse(self.c(W + '.root.tools.run', 'instate', 'disabled'))
        self.assertEqual(self.c('winfo', 'manager', W + '.root.progress'), '')

    def test_baseline_mismatch_and_signed_percent(self):
        self.assertIn('No baseline', self.get('compare_summary'))
        self.call('keep_baseline')
        self.app.tk.eval('dict set ::mock::vectors {@m.xm1.m0[gm]} 0.001')
        self.call('refresh')
        tree = W + '.tabs.compare.tree'
        row = self.c(tree, 'children', '')[0]
        self.assertEqual(self.c(tree, 'set', row, 'delta'), '+25.00')
        self.set('active_context', 'another hierarchy')
        self.call('render_compare')
        self.assertIn('Return to that hierarchy', self.get('compare_summary'))
        self.assertEqual(self.c(tree, 'children', ''), '')

    def test_keyboard_find_locate_and_host_theme_unchanged(self):
        self.assertEqual(self.c('ttk::style', 'theme', 'use'), self.original_theme)
        self.c('focus', '-force', W + '.root.tools.run')
        self.c('event', 'generate', W + '.root.tools.run', '<Control-f>')
        self.app.update()
        self.assertEqual(str(self.c('focus')), W + '.tabs.op.filters.search')
        tree = W + '.tabs.op.panes.list.tree'
        self.c(tree, 'selection', 'set', 'd0')
        self.c('focus', '-force', tree)
        self.c('event', 'generate', tree, '<Return>')
        self.app.update()
        self.assertEqual(self.c('set', '::mock::selection'), 'M1')

    def test_minimum_window_keeps_actions_visible(self):
        self.check_actions_visible()

    def test_larger_system_text_keeps_actions_visible(self):
        self.call('close_window')
        self.c('font', 'configure', 'TkDefaultFont', '-size', 14)
        self.c('font', 'configure', 'TkTextFont', '-size', 14)
        self.c('font', 'configure', 'TkFixedFont', '-size', 14)
        self.call('show')
        self.c('after', 'cancel', self.get('timer'))
        self.set('timer', '')
        self.check_actions_visible()

    def test_reopen_retains_lookup_options_and_single_traces(self):
        self.load_lut()
        self.set('target_gmid', '16')
        self.call('close_window')
        self.call('show')
        self.assertTrue(self.c(W + '.tabs.lut.filters.model.value', 'cget', '-values'))
        self.assertEqual(len(self.c(W + '.tabs.lut.size.length', 'cget', '-values')), 2)
        self.assertEqual(str(self.get('target_gmid')), '16')
        traces = self.c('trace', 'info', 'variable', '::analog_lens::target_gmid')
        self.assertEqual(len(traces), 1)

    def test_lookup_dialog_actions_survive_minimum_size(self):
        self.load_lut()
        self.call('data_dialog')
        dialog = W + '.data'
        self.c('wm', 'geometry', dialog, '500x300+0+0')
        self.settle()
        for name in ['copy', 'close']:
            widget = dialog + '.root.actions.' + name
            self.assertTrue(self.c('winfo', 'ismapped', widget))
            y = int(self.c('winfo', 'rooty', widget)) - int(self.c('winfo', 'rooty', dialog))
            self.assertLessEqual(y + int(self.c('winfo', 'height', widget)), 300)
            self.assertGreaterEqual(int(self.c('winfo', 'height', widget)), 20)

    def test_plot_ticks_remain_aligned_after_resize(self):
        self.load_lut()
        self.c(W + '.tabs', 'select', W + '.tabs.lut')
        self.c('wm', 'geometry', W, '900x640')
        self.settle()
        plot = W + '.tabs.lut.plot'
        ticks = {}
        for item in self.c(plot, 'find', 'all'):
            if str(self.c(plot, 'type', item)) == 'text':
                text = str(self.c(plot, 'itemcget', item, '-text'))
                if text in ['10', '13', '16', '19', '22']:
                    ticks[text] = tuple(map(float, self.app.tk.splitlist(self.c(plot, 'coords', item))))
        self.assertEqual(len(ticks), 5)
        x0, y0 = ticks['10']
        x1, y1 = ticks['22']
        for index, label in enumerate(['10', '13', '16', '19', '22']):
            self.assertAlmostEqual(ticks[label][0], x0 + (x1 - x0) * index / 4)
            self.assertAlmostEqual(ticks[label][1], y0)

    def test_dark_host_palette_retains_readable_text(self):
        self.call('close_window')
        self.app.tk.eval('''
            ttk::style theme create AuditDark -parent clam -settings {
                ttk::style configure . -background #202024 -foreground #f4f4f5
                ttk::style configure TFrame -background #202024
                ttk::style configure TLabel -foreground #f4f4f5
                ttk::style configure Treeview -background #29292f -fieldbackground #29292f -foreground #f4f4f5
            }
            ttk::style theme use AuditDark
        ''')
        self.call('show')
        self.assertEqual(self.c('ttk::style', 'theme', 'use'), 'AuditDark')

        def luminance(color):
            rgb = map(int, self.app.tk.splitlist(self.c('winfo', 'rgb', '.', color)))
            linear = [v / 65535 / 12.92 if v / 65535 <= 0.04045
                      else ((v / 65535 + 0.055) / 1.055) ** 2.4 for v in rgb]
            return sum(v * w for v, w in zip(linear, [.2126, .7152, .0722]))

        colors = self.get('colors')
        for fg, bg in [('fg', 'field'), ('muted', 'bg'), ('warning', 'field'), ('error', 'bg')]:
            a, b = sorted([luminance(self.c('dict', 'get', colors, fg)),
                           luminance(self.c('dict', 'get', colors, bg))])
            self.assertGreaterEqual((b + .05) / (a + .05), 4.5, (fg, bg))

    def test_session_restores_baselines_lookup_targets_and_layout(self):
        self.load_lut()
        self.set('baseline_name', 'Nominal')
        self.call('keep_baseline')
        self.c('wm', 'geometry', W, '1100x780')
        self.settle()
        with tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT) as temp:
            path = str(Path(temp) / 'run.alsession')
            self.call('save_session', path)
            self.set('baselines', '')
            self.set('baseline_choice', '')
            self.set('lut_rows', '')
            self.set('target_gmid', 8)
            self.call('open_session', path)
            self.settle()
            self.assertEqual(self.get('baseline_choice'), 'Nominal')
            self.assertEqual(float(self.get('target_gmid')), 15)
            self.assertEqual(len(self.get('lut_rows')), 6)
            self.assertEqual(int(self.c('winfo', 'width', W)), 1100)
            self.assertIn('matched', self.get('compare_summary'))

    def test_lookup_filter_curve_inspection_zoom_and_svg(self):
        self.load_lut()
        self.c(W + '.tabs', 'select', W + '.tabs.lut')
        self.set('lut_length', '0.3')
        self.call('reset_plot')
        self.settle()
        self.assertEqual(len(self.get('plot_points')), 3)
        self.call('step_plot_point', 1)
        self.assertIn('L = 0.3', self.get('plot_point_text'))
        before = tuple(map(float, self.get('plot_bounds')))
        self.call('zoom_plot', .7)
        self.settle()
        after = tuple(map(float, self.get('plot_bounds')))
        self.assertLess(after[1] - after[0], before[1] - before[0])
        self.call('reset_plot')
        with tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT) as temp:
            path = Path(temp) / 'chart.svg'
            self.call('export_plot_svg', str(path))
            root = ET.parse(path).getroot()
            self.assertEqual(root.tag, '{http://www.w3.org/2000/svg}svg')
            self.assertIn('DEMO', path.read_text())
            self.assertTrue(root.findall('{http://www.w3.org/2000/svg}polyline'))
        self.call('data_dialog')
        tree = W + '.data.root.table.tree'
        rows = self.c(tree, 'children', '')
        self.assertEqual(len(rows), 3)
        self.assertTrue(all(len(self.c(tree, 'item', row, '-values')) == 3 for row in rows))

    def test_lookup_known_mismatch_hides_overlay(self):
        self.load_lut()
        self.app.tk.eval('dict set ::analog_lens::result_metadata corner ss')
        self.assertIn('Overlay hidden', self.call('lookup_provenance_warning'))

    def test_environment_report_is_copyable(self):
        self.call('check_environment')
        self.c(W + '.environment.actions.copy', 'invoke')
        self.assertIn('IIC-OSIC-TOOLS readiness', self.c('clipboard', 'get'))
        self.assertIn('Result API — Ready', self.get('environment_report'))

    def test_comparison_export_contains_conditions_and_added_devices(self):
        self.call('keep_baseline')
        self.app.tk.eval('set r [lindex $::analog_lens::records 0]; dict set r name M3; lappend ::analog_lens::records $r')
        self.call('render_compare')
        self.assertIn('1 added', self.get('compare_summary'))
        with tempfile.TemporaryDirectory(dir=TEST_TMP_ROOT) as temp:
            path = Path(temp) / 'comparison.csv'
            self.call('export_comparison', str(path))
            import csv
            with path.open() as file:
                rows = list(csv.DictReader(file))
            self.assertEqual(rows[-1]['state'], 'Added')
            self.assertEqual(rows[-1]['baseline_id'], '')
            self.assertIn('captured_at', rows[0]['baseline_metadata'])

    def check_actions_visible(self):
        self.c('wm', 'geometry', W, '900x640+0+0')
        self.set('sizing_visible', 1)
        self.call('toggle_sizing')
        actions = {
            'op': ['.filters.follow', '.point.color', '.panes.detail.locate', '.panes.detail.annotate', '.panes.detail.copy'],
            'lut': ['.tools.load', '.tools.data', '.size.calc', '.size.gm', '.filters.model.value'],
            'compare': ['.keep', '.copy', '.saved.export'],
            'setup': ['.apply', '.targets.current_floor', '.environment', '.conditions.apply'],
        }
        for tab, paths in actions.items():
            self.c(W + '.tabs', 'select', W + '.tabs.' + tab)
            self.settle()
            left = int(self.c('winfo', 'rootx', W))
            top = int(self.c('winfo', 'rooty', W))
            for path in paths:
                w = W + '.tabs.' + tab + path
                with self.subTest(widget=w):
                    self.assertTrue(self.c('winfo', 'ismapped', w))
                    x = int(self.c('winfo', 'rootx', w)) - left
                    y = int(self.c('winfo', 'rooty', w)) - top
                    width = int(self.c('winfo', 'width', w))
                    height = int(self.c('winfo', 'height', w))
                    self.assertGreaterEqual(x, 0)
                    self.assertGreaterEqual(y, 0)
                    self.assertLessEqual(x + width, 900)
                    self.assertLessEqual(y + height, 640)
                    self.assertGreaterEqual(height, 20)
                    self.assertGreaterEqual(width, int(self.c('winfo', 'reqwidth', w)))
        self.c(W + '.tabs', 'select', W + '.tabs.lut')
        self.set('sizing_visible', 0)
        self.call('toggle_sizing')
        self.settle()
        self.assertTrue(self.c('winfo', 'ismapped', W + '.tabs.lut.charttools.export'))


if __name__ == '__main__':
    unittest.main()
