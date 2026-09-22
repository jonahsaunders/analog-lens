#!/usr/bin/env python3
"""Run real ngspice MOS parameter checks for installed IIC-OSIC-TOOLS PDKs.

Writes unique test decks, raw results, logs and JSON report. Does not modify PDKs.
This is an integration diagnostic, not foundry model qualification.
"""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tkinter
import hashlib

ROOT = Path(__file__).resolve().parents[1]

PDKS = ('sky130A', 'gf180mcuD', 'ihp-sg13g2', 'ihp-sg13cmos5l')

def parse_ascii_op(text):
    """Read the first point in an ngspice real ASCII raw file."""
    if 'Flags: real' not in text or 'Values:' not in text:
        raise ValueError('Expected real ASCII operating-point raw data.')
    header, payload = text.split('Values:', 1)
    variables = re.findall(r'^\s*\d+\s+(\S+)\s+\S+\s*$', header.split('Variables:', 1)[1], re.M)
    lines = [line.strip() for line in payload.splitlines() if line.strip()]
    if len(lines) < len(variables):
        raise ValueError('Incomplete operating-point data.')
    vals = [float(lines[0].split()[-1])] + [float(x) for x in lines[1:len(variables)]]
    return {re.sub(r'^[vi]\((@.*)\)$', r'\1', key.lower()): val for key,val in zip(variables,vals)}

def configuration(pdk, base, polarity):
    is_p = polarity == 'p'
    if pdk.startswith('sky130'):
        lib=base/'libs.tech/ngspice/sky130.lib.spice'
        model='pfet_01v8' if is_p else 'nfet_01v8'
        # Open_pdks SKY130 model wrappers expect micron-valued W/L and scale=1u.
        includes=f'.lib "{lib}" tt\n.option scale=1u'
        instance=f'xm1 d g 0 0 sky130_fd_pr__{model} w=10 l=0.5 nf=1 mult=1 m=1'
        return includes,instance,f'@m.xm1.msky130_fd_pr__{model}','id',-.9 if is_p else .9, .9, False
    if pdk.startswith('gf180'):
        model='pfet_03v3' if is_p else 'nfet_03v3'
        root=base/'libs.tech/ngspice'
        includes=f'.include "{root / "design.ngspice"}"\n.lib "{root / "sm141064.ngspice"}" typical'
        instance=f'xm1 d g 0 0 {model} w=10u l=0.6u nf=1 m=1'
        return includes,instance,'@m.xm1.m0','id',-1.8 if is_p else 1.8,1.8,False
    model='sg13_lv_pmos' if is_p else 'sg13_lv_nmos'
    lib=base/'libs.tech/ngspice/models/cornerMOSlv.lib'
    includes=f'.lib "{lib}" mos_tt'
    instance=f'xm1 d g 0 0 {model} w=10u l=0.5u ng=1 m=1'
    return includes,instance,f'@n.xm1.n{model}','ids',-.9 if is_p else .9,.9,True

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pdk-root',type=Path,default=Path(os.environ.get('PDK_ROOT','/foss/pdks')))
    p.add_argument('--output',type=Path,default=Path('iic-checks'))
    p.add_argument('--timeout',type=int,default=90)
    p.add_argument('--require-all', action='store_true', help='Fail if any supported PDK is missing.')
    args=p.parse_args()
    binary=shutil.which('ngspice')
    if not binary:
        p.exit(2,'ngspice was not found. Run this diagnostic inside IIC-OSIC-TOOLS.\n')
    out=(args.output/datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')).resolve();out.mkdir(parents=True)
    results=[]
    tcl = tkinter.Tcl()
    tcl.call('source', str(ROOT / 'analog_lens.tcl'))
    for pdk in PDKS:
        base=(args.pdk_root/pdk).resolve()
        if not base.is_dir():
            results.append(dict(pdk=pdk,status='not-installed'));continue
        for polarity in ('n','p'):
            tag=f'{pdk}-{polarity}mos'; raw=out/(tag+'.raw'); deck=out/(tag+'.spice')
            includes,instance,path,current,vg,vd,psp=configuration(pdk,base,polarity)
            params=[current,'gm','gds','vgs','vds','vdss' if psp else 'vdsat','cgg']
            if psp:params+=['cgsol','cgdol']
            saves='\n'.join('.save '+path+'['+param+']' for param in params)
            vds=-vd if polarity=='p' else vd
            deck.write_text(f'Analog Lens {tag} parameter check\n{includes}\nvg g 0 {vg}\nvd d 0 {vds}\n{instance}\n.save all\n{saves}\n.control\nset filetype=ascii\nop\nwrite {raw.name}\nquit\n.endc\n.end\n')
            env=dict(os.environ,PDK=pdk,PDKPATH=str(base),SPICE_USERINIT_DIR=str(base/'libs.tech/ngspice'))
            # Preserve the installation's own init files and OSDI paths.
            try:
                proc=subprocess.run([binary,'-b',str(deck)],cwd=out,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=args.timeout)
                (out/(tag+'.log')).write_text(proc.stdout)
                if proc.returncode or not raw.is_file():raise ValueError('Simulation failed; inspect the log.')
                values=parse_ascii_op(raw.read_text())
                expected=[path+'['+param+']' for param in params]
                missing=[key for key in expected if key not in values or not math.isfinite(values[key])]
                if missing:raise ValueError('Missing or nonfinite parameters: '+', '.join(missing))
                ids,gm,gds=(values[path+'['+param+']'] for param in (current,'gm','gds'))
                if abs(ids)<1e-12 or gm<=0 or gds<=0:raise ValueError('Invalid bias or nonpositive small-signal parameters.')
                fields = dict(id=ids, gm=gm, gds=gds, vds=values[path+'[vds]'],
                              vdsat=values[path+('[vdss]' if psp else '[vdsat]')], cgg=values[path+'[cgg]'])
                if psp:
                    fields.update(cgsol=values[path+'[cgsol]'], cgdol=values[path+'[cgdol]'])
                family = 'ihp' if psp else 'sky130' if pdk.startswith('sky') else 'gf180'
                computed = tcl.call('::analog_lens::metrics', tcl.call('dict', 'create', *[v for pair in fields.items() for v in pair]), family, polarity+'mos')
                capacitance = fields['cgg'] + (fields['cgsol']+fields['cgdol'] if psp else 0)
                expected_metrics = dict(gmid=abs(gm/ids), gain=gm/gds, ro=1/gds,
                                        headroom=abs(fields['vds'])-abs(fields['vdsat']))
                if capacitance > 0: expected_metrics['ft'] = gm/(2*math.pi*capacitance)
                for key, expected_value in expected_metrics.items():
                    actual = float(tcl.call('dict', 'get', computed, key))
                    if not math.isclose(actual, expected_value, rel_tol=1e-9, abs_tol=1e-15):
                        raise ValueError(f'Extension disagrees with ngspice-derived {key}: {actual} vs {expected_value}')
                results.append(dict(pdk=pdk,device=polarity+'mos',status='passed',metrics=expected_metrics,
                                    raw=str(raw),deck_sha256=hashlib.sha256(deck.read_bytes()).hexdigest()))
            except (OSError,ValueError,subprocess.TimeoutExpired,tkinter.TclError) as exc:
                results.append(dict(pdk=pdk,device=polarity+'mos',status='failed',error=str(exc)))
    report=out/'report.json';report.write_text(json.dumps(results,indent=2)+'\n')
    for r in results:print(r['pdk'],r.get('device',''),r['status'],r.get('error',''))
    print('Report:',report)
    return 1 if any(r['status']=='failed' or (args.require_all and r['status']=='not-installed') for r in results) else 0 if any(r['status']=='passed' for r in results) else 2

if __name__=='__main__':raise SystemExit(main())
