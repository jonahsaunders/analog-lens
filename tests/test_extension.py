"""Headless Tcl engine and xschem contract tests; these are not PDK simulations."""
from pathlib import Path
import importlib.util
import math
import os
import sys
import tempfile
import time
import tkinter
import unittest

ROOT = Path(__file__).resolve().parents[1]

class Engine(unittest.TestCase):
    def setUp(self):
        self.t = tkinter.Tcl()
        self.t.call('source', str(ROOT/'analog_lens.tcl'))
    def call(self, command, *args):
        return self.t.call('::analog_lens::'+command, *args)
    def d(self, **kw):
        return self.t.call('dict','create',*[x for item in kw.items() for x in item])
    def g(self, d, key):
        return self.t.call('dict','get',d,key)
    def device(self, family='sky130', name='M1', hierarchy='', model='nfet_01v8', **kw):
        return self.d(family=family, name=name, hierarchy=hierarchy, model=model, prefix='X', type='nmos', **kw)
    def test_numeric_missing_not_zero(self):
        for x in ('','NaN','Inf','-Inf','1; exit','[exit]'):
            self.assertEqual(self.call('number',x),'')
        self.assertEqual(float(self.call('number','0')),0.0)
    def test_spice_suffix(self):
        self.assertAlmostEqual(float(self.call('spice_number','2.2u')),2.2e-6)
        self.assertEqual(float(self.call('spice_number','2M')),.002)
        self.assertEqual(float(self.call('spice_number','2meg')),2e6)
        self.assertEqual(self.call('spice_number','{w*2}'),'')
    def test_metrics(self):
        r=self.call('metrics',self.d(id=5e-5,gm=.0008,gds=2.5e-5,vds=.9,vdsat=.2,cgg=1e-13),'sky130')
        self.assertAlmostEqual(float(self.g(r,'gmid')),16)
        self.assertAlmostEqual(float(self.g(r,'gain')),32)
        self.assertAlmostEqual(float(self.g(r,'ro')),40000)
        self.assertAlmostEqual(float(self.g(r,'headroom')),.7)
        self.assertEqual(self.g(r,'status'),'In range')
    def test_pmos_signs(self):
        r=self.call('metrics',self.d(id=-5e-5,gm=.0008,gds=2.5e-5,vds=-.9,vdsat=-.2),'gf180','pmos')
        self.assertEqual(float(self.g(r,'gmid')),16)
        self.assertAlmostEqual(float(self.g(r,'headroom')),.7)
    def test_near_zero_current(self):
        r=self.call('metrics',self.d(id=1e-15,gm=1e-10,gds=0),'sky130')
        self.assertEqual(self.g(r,'gmid'),'');self.assertEqual(self.g(r,'gain'),'');self.assertEqual(self.g(r,'ro'),'')
    def test_psp_overlap(self):
        r=self.call('metrics',self.d(id=.001,gm=.01,gds=.0001,cgg=1e-12,cgsol=2e-13,cgdol=3e-13),'ihp')
        self.assertAlmostEqual(float(self.g(r,'cgg_total')),1.5e-12)
        self.assertTrue(math.isclose(float(self.g(r,'ft')),.01/(2*math.pi*1.5e-12),rel_tol=1e-12))
    def test_psp_missing_overlap(self):
        r=self.call('metrics',self.d(id=.001,gm=.01,gds=.0001,cgg=1e-12),'ihp')
        self.assertEqual(self.g(r,'ft'),'')
    def test_all_iic_families(self):
        for pdk,expected in [('sky130A','sky130'),('sky130B','sky130'),('gf180mcuD','gf180'),('gf180mcuA','gf180'),('ihp-sg13g2','ihp'),('ihp-sg13cmos5l','ihp')]:
            self.assertEqual(self.call('family','','',pdk),expected)
        self.assertEqual(self.call('family','sg13g2_pr/sg13_lv_nmos.sym','','sky130A'),'ihp')
    def test_paths_sky130(self):
        p=self.call('device_paths',self.device(hierarchy='.xamp.',model='sky130_fd_pr__nfet_01v8'))
        self.assertEqual(self.t.splitlist(p)[0],'@m.xamp.xm1.msky130_fd_pr__nfet_01v8')
    def test_paths_gf180(self):
        p=self.call('device_paths',self.device(family='gf180',model='nfet_03v3',hierarchy='xamp.'))
        self.assertEqual(self.t.splitlist(p)[0],'@m.xamp.xm1.m0')
    def test_paths_both_ihp(self):
        for sym in ('sg13g2_pr/sg13_lv_nmos.sym','sg13cmos5l_pr/sg13_lv_nmos.sym'):
            fam=self.call('family',sym,'sg13_lv_nmos')
            p=self.call('device_paths',self.device(family=fam,model='sg13_lv_nmos',hierarchy='xamp.'))
            self.assertEqual(self.t.splitlist(p)[0],'@n.xamp.xm1.nsg13_lv_nmos')
    def test_bipolar_path(self):
        d=self.d(family='ihp',name='Q1',prefix='X',model='npn13G2_5t',hierarchy='',type='vertical_npn')
        self.assertEqual(self.t.splitlist(self.call('device_paths',d))[0],'@q.xq1.qnpn13g2')
    def test_sky_gf_bipolar_paths(self):
        for family,model,expected in [('sky130','npn_05v5_w1p00l2p00','@q.xq1.qsky130_fd_pr__npn_05v5_w1p00l2p00'),('gf180','npn_10p00x10p00','@q.xq1.q0')]:
            d=self.d(family=family,name='Q1',prefix='X',model=model,hierarchy='',type='npn')
            self.assertEqual(self.t.splitlist(self.call('device_paths',d))[0],expected)
    def test_bipolar_metrics(self):
        r=self.call('metrics',self.d(id=.001,ib=1e-5,gm=.038,gds=1e-5,vbe=.7,vbc=-.3),'ihp','vertical_npn')
        self.assertAlmostEqual(float(self.g(r,'beta')),100)
        self.assertAlmostEqual(float(self.g(r,'vce')),1)
        self.assertEqual(self.g(r,'status'),'In range')
    def test_wrapped_vector_names(self):
        d=self.device(family='gf180',model='nfet_03v3')
        names=('i(@m.xm1.m0[id])','@m.xm1.m0[gm]','v(@m.xm1.m0[vds])')
        r=self.call('resolve_vectors',d,self.call('vector_index',names))
        self.assertEqual(self.g(self.g(r,'vectors'),'id'),names[0])
        self.assertEqual(self.g(self.g(r,'vectors'),'vds'),names[2])
    def test_no_m1_m10_collision(self):
        r=self.call('resolve_vectors',self.device(family='gf180'),self.call('vector_index',('@m.xm10.m0[gm]',)))
        self.assertEqual(int(self.t.call('dict','size',self.g(r,'vectors'))),0)
    def test_ambiguous_deeper_primitive(self):
        r=self.call('resolve_vectors',self.device(family='gf180'),self.call('vector_index',('@m.xm1.extra.a[gm]','@m.xm1.extra.b[gm]')))
        self.assertEqual(self.g(r,'vectors'),'')
    def test_save_lines_all_families(self):
        for family,model,param in [('sky130','nfet_01v8','id'),('gf180','nfet_03v3','id'),('ihp','sg13_lv_nmos','ids')]:
            s=self.call('save_lines',(self.device(family=family,model=model),))
            self.assertIn('.save all',s);self.assertIn('['+param+']',s);self.assertIn('[gm]',s)
    def test_csv_roundtrip(self):
        row=('text,with,commas','quote"and\nnewline','a','')
        encoded=self.call('csv_row',row)
        parsed=self.t.splitlist(self.call('csv_parse',encoded))
        self.assertEqual(self.t.splitlist(parsed[0]),row)
    def test_csv_unclosed(self):
        with self.assertRaises(tkinter.TclError):self.call('csv_parse','a,b\n"x,y')
    def test_lut_metadata_isolated(self):
        rows=self.call('parse_lut',(ROOT/'examples/lookup-template.csv').read_text())
        rows=self.t.splitlist(rows)
        self.assertEqual(len(rows),6)
        curves=self.call('lut_curves',rows,self.g(rows[0],'slice'),'gain')
        self.assertEqual(int(self.t.call('dict','size',curves)),2)
    def test_lut_sizing(self):
        rows=self.t.splitlist(self.call('parse_lut',(ROOT/'examples/lookup-template.csv').read_text()))
        r=self.call('sizing',rows,self.g(rows[0],'slice'),.3,16,800)
        self.assertAlmostEqual(float(self.g(r,'id')),5e-5)
        self.assertAlmostEqual(float(self.g(r,'width')),10)
    def test_lut_no_extrapolation(self):
        rows=self.t.splitlist(self.call('parse_lut',(ROOT/'examples/lookup-template.csv').read_text()))
        with self.assertRaises(tkinter.TclError):self.call('sizing',rows,self.g(rows[0],'slice'),.3,100,800)
    def test_lut_duplicate_x_rejected(self):
        rows=self.t.splitlist(self.call('parse_lut',(ROOT/'examples/lookup-template.csv').read_text()))
        rows=(*rows,rows[0])
        with self.assertRaises(tkinter.TclError):self.call('sizing',rows,self.g(rows[0],'slice'),.3,16,800)
    def test_lut_branch_rejected(self):
        rows=self.t.splitlist(self.call('parse_lut',(ROOT/'examples/lookup-template.csv').read_text()))
        unordered=(rows[0],rows[2],rows[1],*rows[3:])
        with self.assertRaises(tkinter.TclError):self.call('sizing',unordered,self.g(rows[0],'slice'),.3,16,800)
    def test_lut_injection_is_data(self):
        s=(ROOT/'examples/lookup-template.csv').read_text().replace('illustrative_nmos','[set ::injected 1]')
        self.call('parse_lut',s)
        self.assertEqual(self.t.eval('info exists ::injected'),'0')
    def test_op_deck_preserves_circuit(self):
        src='test\n.lib "model file.lib" tt\n.param vb=0.7\nv1 d 0 1.8\n.control\nalter v1 2\ntran 1n 1u\n.endc\n.tran 1n 1u\n+ extra\n.save v(d)\n.end\n'
        deck=self.call('op_deck',src,'.save @m1[gm]\n','/tmp/example.raw')
        self.assertIn('.param vb=0.7',deck);self.assertIn('.lib "model file.lib" tt',deck)
        self.assertNotIn('alter ',deck);self.assertNotIn('.tran ',deck);self.assertNotIn('+ extra',deck)
        self.assertIn('write "/tmp/example.raw"',deck);self.assertEqual(deck.count('.control'),1)
    def test_op_deck_rejects_bad_blocks(self):
        with self.assertRaises(tkinter.TclError):self.call('op_deck','test\n.control\nop\n','','a.raw')
    def test_io(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as d:
            path=Path(d)/'unicode.txt';self.call('write_text',str(path),'µΩ\n');self.assertEqual(self.call('read_text',str(path)),'µΩ\n')
    def test_loader_idempotent(self):
        self.t.eval('set ::analog_lens::sample 17')
        self.t.call('source',str(ROOT/'analog_lens.tcl'))
        self.assertEqual(self.t.eval('set ::analog_lens::sample'),'17')
    def test_mock_refresh(self):
        self.t.call('source',str(ROOT/'tests/mock_xschem.tcl'))
        self.t.eval('rename ::analog_lens::render {}; proc ::analog_lens::render {} {}')
        self.call('refresh')
        self.assertEqual(self.t.eval('llength $::analog_lens::records'),'2')
        self.assertEqual(float(self.t.eval('dict get [lindex $::analog_lens::records 0] values gmid')),16)
    def test_out_of_range_sample(self):
        self.t.call('source',str(ROOT/'tests/mock_xschem.tcl'))
        self.t.eval('set ::analog_lens::sample 2')
        with self.assertRaises(tkinter.TclError):self.call('refresh')
    def test_collect_preserves_selection(self):
        self.t.call('source',str(ROOT/'tests/mock_xschem.tcl'))
        self.call('collect_devices')
        self.assertEqual(self.t.eval('set ::mock::selection'),'M2')
    def test_hierarchy_restored_on_error(self):
        self.t.call('source',str(ROOT/'tests/mock_xschem.tcl'))
        self.t.eval('set ::mock::hierarchy_test 1')
        with self.assertRaises(tkinter.TclError):self.call('collect_devices')
        self.assertEqual(self.t.eval('set ::mock::level'),'0')
        self.assertEqual(self.t.eval('set ::mock::selection'),'M2')
    def test_widget_command_contract(self):
        self.t.call('source',str(ROOT/'tests/mock_tk.tcl'))
        try:
            self.t.call('source',str(ROOT/'tests/gui_smoke.tcl'))
        except tkinter.TclError:
            self.fail(self.t.eval('set errorInfo'))
        self.assertEqual(self.t.eval('winfo exists .analog_lens'),'0')
    def test_async_process_contract(self):
        # Real subprocess/fileevents; fake executable and xschem API, not ngspice.
        self.t.call('source',str(ROOT/'tests/mock_xschem.tcl'))
        self.t.eval('rename ::analog_lens::render {}; proc ::analog_lens::render {} {}; rename ::analog_lens::update_run_controls {}; proc ::analog_lens::update_run_controls {} {}')
        with tempfile.TemporaryDirectory(dir=ROOT) as d:
            d=Path(d); exe=d/'ngspice'
            exe.write_text('#!'+sys.executable+'\nimport sys,re,pathlib\ns=pathlib.Path(sys.argv[-1]).read_text()\np=re.search(r\'write "([^"]+)"\',s).group(1)\npathlib.Path(p).write_text("fixture raw")\nprint("fixture complete")\n')
            exe.chmod(0o755)
            old=self.t.eval('set ::env(PATH)')
            self.t.setvar('env(PATH)',str(d)+os.pathsep+old)
            self.t.setvar('netlist_dir',str(d))
            try:
                self.call('run_op')
                deadline=time.monotonic()+5
                while self.t.eval('set ::analog_lens::run_channel') and time.monotonic()<deadline:
                    self.t.eval('update');time.sleep(.005)
                self.assertEqual(self.t.eval('set ::analog_lens::run_channel'),'')
                self.assertIn('2 devices',self.t.eval('set ::analog_lens::status'))
                deck=next(x for x in d.glob('*.spice') if not x.name.endswith('-source.spice'))
                self.assertIn('.save @m.xm1.m0[gm]',deck.read_text())
                self.assertNotIn('tran 1n',deck.read_text())
            finally:
                self.t.setvar('env(PATH)',old)

class Installer(unittest.TestCase):
    def setUp(self):
        spec=importlib.util.spec_from_file_location('al_install',ROOT/'install.py');self.mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.mod)
    def test_preserve_pdk_and_idempotence(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as d:
            d=Path(d);rc=d/'xschemrc';rc.write_text('source /pdk/xschemrc\nset my_custom_var 7\n')
            dest=d/'plugin';_,backup=self.mod.install(ROOT,dest,rc)
            self.assertTrue(backup.exists());self.assertIn('source /pdk/xschemrc',rc.read_text())
            before=rc.read_text();_,backup2=self.mod.install(ROOT,dest,rc)
            self.assertIsNone(backup2);self.assertEqual(rc.read_text(),before)
    def test_missing_rc_refused(self):
        with tempfile.TemporaryDirectory(dir=ROOT) as d:
            with self.assertRaises(ValueError):self.mod.install(ROOT,Path(d)/'plugin',Path(d)/'missing')

if __name__=='__main__':unittest.main()
