#!/usr/bin/env python3
"""Create runnable SKY130 sizing and current-mirror lessons in an IIC project.

Run inside IIC-OSIC-TOOLS. Existing output directories are never overwritten.
Measured targets and before/miss/adjusted results are generated from your models.
"""
import argparse
import csv
import json
import os
from pathlib import Path
import subprocess
import sys

import characterize
from check_iic import configuration, parse_ascii_op
from validate_iic import HEADER, symbol_pins, tcl_literal

ROOT = Path(__file__).resolve().parents[1]


def schematic(symbol, pins, instances, code, raw_name):
    text = HEADER
    for name, x, nets, width in instances:
        text += (f'C {{{symbol}}} {x} 0 0 0 {{name={name} model=nfet_01v8 '
                 f'W={width:g} L=0.5 nf=1 mult=1 spiceprefix=X}}\n')
        for pin, px, py in pins:
            text += f'C {{devices/lab_pin.sym}} {x+px:g} {py:g} 0 0 {{name=lab_{name}_{pin} lab={nets[pin]}}}\n'
    flow = f'.control\nset filetype=ascii\nop\nwrite {raw_name}\nquit\n.endc'
    for name, value, y in [('BIAS', code, -260), ('FLOW', flow, 200)]:
        value = value.replace('"', '\\"')
        text += f'C {{devices/code_shown.sym}} -260 {y} 0 0 {{name={name} only_toplevel=true value="{value}"}}\n'
    return text


def create(output, pdk_root):
    if output.exists():
        raise ValueError('Choose a new output directory; existing lessons are preserved.')
    base = (pdk_root/'sky130A').resolve()
    choices = sorted((base/'libs.tech/xschem').rglob('nfet_01v8.sym'))
    if not choices:
        raise ValueError('Installed SKY130 xschem symbols are missing.')
    symbol = choices[0]; pins = symbol_pins(symbol)
    output.mkdir(parents=True)
    lookup = output/'lookup.csv'
    result = characterize.main(['--pdk','sky130A','--model','nfet_01v8','--pdk-root',str(pdk_root),
                                '--lengths','.5','--width','20','--vds','.9','--vsb','0',
                                '--vgs-start','.4','--vgs-stop','1.2','--vgs-step','.01','--output',str(lookup)])
    if result:
        raise ValueError('Characterization failed. Inspect the preserved logs and use a new output directory to retry.')
    with lookup.open() as stream:
        rows = list(csv.DictReader(stream))
    point = min(rows, key=lambda row: abs(float(row['vgs_v'])-.7))
    # Characterize the final geometry directly: doubling width is only an
    # estimate and SKY130's width-dependent effects can exceed the tolerance.
    target_gm = float(point['gm_s']); target_gmid = abs(float(point['gm_s'])/float(point['id_a']))
    required_vgs = float(point['vgs_v']); target_id = abs(float(point['id_a']))
    includes, instance, prefix, current, _, _, _ = configuration('sky130A', base, 'n')
    nets = dict(d='d',g='g',s='0',b='0')
    common = includes+'\n.temp 27\nvd d 0 .9\n'
    (output/'sizing.sch').write_text(schematic(symbol,pins,[('M1',0,nets,10)],common+'vg g 0 .9','sizing.raw'))
    (output/'adjusted.sch').write_text(schematic(symbol,pins,[('M1',0,nets,20)],common+f'vg g 0 {required_vgs:.12g}','adjusted.raw'))
    mirror = [('M1',0,dict(d='gate',g='gate',s='0',b='0'),10),
              ('M2',300,dict(d='out',g='gate',s='0',b='0'),20)]
    mirror_code = includes+f'\n.temp 27\niref 0 gate {target_id/2:.12g}\nvout out 0 .9'
    (output/'mirror.sch').write_text(schematic(symbol,pins,mirror,mirror_code,'mirror.raw'))
    rc = (f'source {tcl_literal(base/"libs.tech/xschem/xschemrc")}\n'
          f'source {tcl_literal(ROOT/"analog_lens.tcl")}\nset netlist_dir {tcl_literal(output)}\n')
    (output/'xschemrc').write_text(rc)
    env = dict(os.environ, PDK='sky130A', PDKPATH=str(base), SPICE_USERINIT_DIR=str(base/'libs.tech/ngspice'))
    measurements = {}
    for label, width, vgs in [('before',10,.9),('width_only',20,.9),('bias_adjusted',20,required_vgs)]:
        raw = output/(label+'.raw'); deck = output/(label+'.spice'); log = output/(label+'.log')
        device = instance.replace('w=10 ',f'w={width} ')
        deck.write_text('Analog Lens measured sizing lesson\n'+common+f'vg g 0 {vgs:.12g}\n'+device+
                        f'\n.save all\n.save {prefix}[gm] {prefix}[{current}]\n.control\nset filetype=ascii\nop\nwrite {raw.name}\nquit\n.endc\n.end\n')
        code = characterize.simulate(['ngspice','-b',str(deck)],deck,log,env)
        if code or not raw.is_file():
            raise ValueError('Tutorial simulation failed; inspect '+str(log))
        values = parse_ascii_op(raw.read_text()); gm = values[prefix+'[gm]']; ids = abs(values[prefix+'['+current+']'])
        gmid = gm/ids
        measurements[label] = dict(gm_s=gm,gmid=gmid,id_a=ids,vgs_v=vgs,
                                   gm_error_percent=100*(gm/target_gm-1),gmid_error_percent=100*(gmid/target_gmid-1))
    targets = dict(length_um=.5, gm_uS=target_gm*1e6, gmid=target_gmid, estimated_vgs_v=required_vgs,
                   estimated_id_a=target_id, total_width_um=20,tolerance_percent=10,measurements=measurements)
    (output/'targets.json').write_text(json.dumps(targets,indent=2)+'\n')
    print(json.dumps(targets,indent=2))
    final = measurements['bias_adjusted']
    if max(abs(final[k]) for k in ('gm_error_percent','gmid_error_percent')) > 10:
        raise ValueError('Adjusted lesson did not meet the 10% device targets; inspect targets.json and the retained simulations.')
    print(f'Open: cd {output}\nxschem sizing.sch\nFollow {ROOT / "examples/README.md"}')
    return targets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--pdk-root',type=Path,default=Path(os.environ.get('PDK_ROOT','/foss/pdks')))
    args=parser.parse_args()
    try:
        create(args.output.resolve(),args.pdk_root.resolve())
    except (OSError,ValueError,KeyError,subprocess.SubprocessError) as exc:
        parser.exit(1,f'Tutorial setup failed: {exc}\n')


if __name__ == '__main__':
    main()
