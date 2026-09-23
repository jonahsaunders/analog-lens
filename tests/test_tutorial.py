"""Generated schematics retain signed bias, connectivity and source safety."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from create_tutorial import create, schematic
from validate_iic import make_testbench


class Tutorial(unittest.TestCase):
    def test_mirror_connections_share_gate_and_keep_distinct_drains(self):
        pins = [('d',0,-20),('g',-20,0),('s',0,20),('b',20,0)]
        devices = [('M1',0,dict(d='gate',g='gate',s='0',b='0'),10),
                   ('M2',300,dict(d='out',g='gate',s='0',b='0'),20)]
        text = schematic(Path('/installed/nfet_01v8.sym'), pins, devices, 'iref 0 gate 1u', 'mirror.raw')
        for name, net in [('M1_d','gate'),('M1_g','gate'),('M2_g','gate'),('M2_d','out')]:
            self.assertIn(f'name=lab_{name} lab={net}', text)
        self.assertIn('name=M2 model=nfet_01v8 W=20', text)
        self.assertIn('write mirror.raw', text)

    def test_pmos_gui_bench_emits_corner_temperature_and_body_bias(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('ANALOG_LENS_TEST_TMP', ROOT.parent)) as temp:
            root=Path(temp); base=root/'sky130A'; symbols=base/'libs.tech/xschem'; symbols.mkdir(parents=True)
            (symbols/'xschemrc').write_text('# fixture')
            (symbols/'pfet_01v8.sym').write_text('\n'.join(f'B 5 {x-2} {y-2} {x+2} {y+2} {{name={name}}}'
                for name,x,y in [('d',0,-20),('g',-20,0),('s',0,20),('b',20,0)]))
            out=root/'out';out.mkdir()
            sch,_=make_testbench('sky130A',base,out,'p','ss',85,-.1)
            text=sch.read_text()
            for part in ('ss', '.temp 85', 'vg g 0 -0.9', 'vd d 0 -0.9', 'vb b 0 0.1', 'alter vd -0.7', 'model=pfet_01v8'):
                self.assertIn(part,text)
            self.assertIn('name=lab_0_b lab=b',text)
            self.assertIn('name=lab_0_s lab=0',text)

    def test_existing_tutorial_directory_is_never_modified(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('ANALOG_LENS_TEST_TMP', ROOT.parent)) as temp:
            path=Path(temp); marker=path/'keep';marker.write_text('original')
            with self.assertRaisesRegex(ValueError,'new output'):
                create(path,path/'no-pdk')
            self.assertEqual(marker.read_text(),'original')
