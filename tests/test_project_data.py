"""Hierarchy, dependency invalidation and cache integrity with file fixtures."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import tkinter
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from project_data import read_graph, devices_from_lines, check_manifest, deck_conditions, tcl, installed_corners
from batch_characterize import cache_key, valid_cache


class ProjectData(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=os.environ.get('ANALOG_LENS_TEST_TMP', ROOT.parent))
        self.path = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_installed_corner_choices_read_profile_library_not_guesses(self):
        base=self.path/'pdk';lib=base/'libs.tech/ngspice';lib.mkdir(parents=True)
        (lib/'sky130.lib.spice').write_text('.lib tt\n.endl\n.lib ss\n.endl\n.lib "external.lib" ff\n* .lib ignored\n')
        self.assertEqual(installed_corners(base,'sky130A'),['ss','tt'])
        with self.assertRaises(OSError):installed_corners(base,'gf180mcuD')

    def test_nested_repeated_hierarchy_and_multiline_parameters(self):
        lines = ['title', 'x1 d g 0 0 child', 'x10 d g 0 0 child', '.subckt child d g s b',
                 'XM1 d g s b nfet_03v3 w=10u l=.5u', '.ends']
        devices = devices_from_lines(lines, 'gf180mcuD')
        self.assertEqual([d['hierarchy'] for d in devices], ['x1.', 'x10.'])
        interp = tkinter.Tcl(); interp.call('source', str(ROOT/'analog_lens.tcl'))
        saves = interp.call('::analog_lens::save_lines', tcl(devices))
        self.assertIn('@m.x1.xm1.m0[gm]', saves)
        self.assertIn('@m.x10.xm1.m0[gm]', saves)

    def test_recursive_or_unresolved_subcircuits_fail_explicitly(self):
        for lines in (['x1 a b c missing'], ['x1 a b c loop', '.subckt loop a b c', 'x1 a b c loop', '.ends']):
            with self.assertRaises(ValueError):
                devices_from_lines(lines, 'sky130A')

    def test_selected_library_section_and_include_are_fingerprinted(self):
        model = self.path/'model file.lib'; model.write_text('.param fixture=1\n')
        lib = self.path/'corners.lib'
        lib.write_text('.lib tt\n.include "model file.lib"\n.endl\n.lib ss\n.include missing.lib\n.endl\n')
        child = self.path/'child.sch'; child.write_text('schematic fixture')
        deck = self.path/'top.spice'; deck.write_text('title\n.lib "corners.lib" tt\n** sch_path: '+str(child)+'\n')
        manifest, _ = read_graph(deck, False)
        self.assertFalse(manifest['warnings'])
        self.assertIn(str(child), manifest['files'])
        self.assertEqual(check_manifest(manifest)['state'], 'current')
        # Same-size edit with restored mtime still changes ctime/content.
        stat = model.stat(); model.write_text('.param fixture=2\n')
        os.utime(model, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        self.assertEqual(check_manifest(manifest)['changed'], [str(model)])

    def test_missing_dependency_is_partial_and_deleted_file_is_changed(self):
        deck = self.path/'top.spice'; deck.write_text('title\n.include absent.lib\n')
        manifest, _ = read_graph(deck, False)
        self.assertEqual(check_manifest(manifest)['state'], 'partial')
        deck.unlink(); self.assertEqual(check_manifest(manifest)['state'], 'changed')

    def test_tcl_serialization_does_not_evaluate_names(self):
        value = {'name': 'a{b}\\c\n[set ::injected 1]; $x', 'rows': [{'data': 'µ m'}]}
        interp = tkinter.Tcl(); encoded = tcl(value)
        self.assertEqual(interp.call('dict', 'get', encoded, 'name'), value['name'])
        self.assertEqual(interp.eval('info exists ::injected'), '0')

    def test_observed_conditions_exclude_ambiguous_control_overrides(self):
        deck = self.path/'top.spice'; deck.write_text('title\n.lib "models.lib" tt\n.temp 85\n')
        self.assertEqual(deck_conditions(deck), {'corner': 'tt', 'temp_c': '85'})
        deck.write_text(deck.read_text()+'.control\nset temp=27\naltermod foo vto=.4\n.endc\n')
        self.assertEqual(deck_conditions(deck), {})

    def test_cache_key_changes_with_model_simulator_or_conditions(self):
        request = {'temp': 27}; deps = {'files': {'model': {'sha256': 'abc'}}}
        original = cache_key(request, deps, 'ngspice fixture 1')
        self.assertNotEqual(original, cache_key({'temp': 85}, deps, 'ngspice fixture 1'))
        self.assertNotEqual(original, cache_key(request, deps, 'ngspice fixture 2'))
        self.assertNotEqual(original, cache_key(request, {'files': {'model': {'sha256': 'def'}}}, 'ngspice fixture 1'))

    def test_cache_rejects_incomplete_or_modified_csv(self):
        path = self.path/'lookup.csv'; path.write_text('fixture samples')
        path.with_suffix('.json').write_text(json.dumps({'status':'completed', 'csv_sha256':hashlib.sha256(path.read_bytes()).hexdigest()}))
        path.with_suffix('.cache.json').write_text(json.dumps({'key':'fixture'}))
        self.assertTrue(valid_cache(path, 'fixture'))
        path.write_text('changed samples'); self.assertFalse(valid_cache(path, 'fixture'))

    def test_large_hierarchy_expands_each_instance_without_host_calls(self):
        lines = [f'x{i} a b c child' for i in range(5000)] + ['.subckt child a b c', 'xm1 a b c c nfet_03v3 w=10u l=.5u', '.ends']
        self.assertEqual(len(devices_from_lines(lines, 'gf180mcuD')), 5000)

    def test_parameter_conditionals_are_allowed_but_conditional_devices_are_not_guessed(self):
        lines = ['.if flag', '.param foo=1', '.endif', 'xm1 d g 0 0 nfet_03v3 w=1u']
        self.assertEqual(len(devices_from_lines(lines, 'gf180mcuD')), 1)
        with self.assertRaises(ValueError):
            devices_from_lines(['.if flag', 'xm1 d g 0 0 nfet_03v3 w=1u', '.endif'], 'gf180mcuD')
