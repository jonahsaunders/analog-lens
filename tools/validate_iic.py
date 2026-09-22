#!/usr/bin/env python3
"""Validate installed PDKs and the actual xschem GUI inside IIC-OSIC-TOOLS.

Run with an X11 display: xvfb-run -a python3 tools/validate_iic.py --require-all
All generated schematics, simulations, logs and reports stay under --output.
"""
import argparse
import csv
import datetime
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys

from check_iic import PDKS, configuration, parse_ascii_op

ROOT = Path(__file__).resolve().parents[1]
HEADER = 'v {xschem version=3.4.7 file_version=1.2}\nG {}\nK {}\nV {}\nS {}\nE {}\n'
# xschem's ASCII raw reader uses float my_atof(), then raw value uses
# dtoa() (%.8g). Ratios compound that conversion error. Allow one ppm for
# this transport path only; check_iic.py still checks direct metrics at 1e-9.
# Upstream: src/save.c read_raw_ascii_point(), src/editprop.c my_atof()/dtoa().
XSCHEM_REL_TOL = 1e-6


def tcl_literal(text):
    return '"' + str(text).replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('[', '\\[').replace(']', '\\]') + '"'


def symbol_pins(path):
    pins = []
    for match in re.finditer(r'^B\s+5\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+\{([^}]*)\}', path.read_text(), re.M):
        name = re.search(r'\bname\s*=\s*"?([\w]+)', match[5])
        if name and name[1].lower() in ('d', 'g', 's', 'b'):
            pins.append((name[1].lower(), (float(match[1])+float(match[3]))/2, (float(match[2])+float(match[4]))/2))
    if {pin[0] for pin in pins} != {'d', 'g', 's', 'b'}:
        raise ValueError(f'Expected four D/G/S/B pins in {path}')
    return pins


def labels(pins, dx=0, dy=0, ground=False):
    return ''.join(f'C {{devices/lab_pin.sym}} {x+dx:g} {y+dy:g} 0 0 {{name=lab_{dx}_{name} lab={"0" if ground and name in ("s", "b") else name}}}\n'
                   for name, x, y in pins)


def make_testbench(pdk, base, out):
    includes, instance, _, _, vg, vd, _ = configuration(pdk, base, 'n')
    model = instance.split()[5]
    candidates = sorted((base / 'libs.tech/xschem').rglob(model + '.sym'))
    if not candidates and model.startswith('sky130_fd_pr__'):
        candidates = sorted((base / 'libs.tech/xschem').rglob(model.split('__', 1)[1] + '.sym'))
    if not candidates:
        raise ValueError(f'Cannot find the installed xschem symbol for {model}')
    symbol = candidates[0]
    pins = symbol_pins(symbol)
    width, length = ('10', '0.5') if pdk.startswith('sky') else ('10u', '0.6u' if pdk.startswith('gf') else '0.5u')
    # SKY130 vendor symbols supply the sky130_fd_pr__ prefix in their format.
    symbol_model = model.split('__', 1)[1] if pdk.startswith('sky') else model
    mos = f'C {{{symbol}}} 0 0 0 0 {{name=M1 model={symbol_model} W={width} L={length} w={width} l={length} nf=1 ng=1 mult=1 m=1 spiceprefix=X}}\n'
    child = HEADER + mos + labels(pins)
    for index, pin in enumerate(('d', 'g', 's', 'b')):
        child += f'C {{devices/iopin.sym}} -200 {index*40} 0 0 {{name=p{index} lab={pin}}}\n'
    (out / 'al_child.sch').write_text(child)
    child_symbol = 'v {xschem version=3.4.7 file_version=1.2}\nG {}\nK {type=subcircuit\nformat="@name @pinlist @symname"\ntemplate="name=x1"}\nV {}\nS {}\nE {}\nL 4 -40 -20 40 -20 {}\n'
    child_pins = []
    for index, pin in enumerate(('d', 'g', 's', 'b')):
        x = index*20
        child_symbol += f'B 5 {x-2} -2 {x+2} 2 {{name={pin} dir=inout}}\n'
        child_pins.append((pin, x, 0))
    (out / 'al_child.sym').write_text(child_symbol)
    bias = (includes + f'\nvg g 0 {vg}\nvd d 0 {vd}').replace('"', '\\"')
    top = HEADER + mos + labels(pins, ground=True)
    top += f'C {{{out / "al_child.sym"}}} 300 0 0 0 {{name=x1}}\n' + labels(child_pins, 300, ground=True)
    top += f'C {{devices/code_shown.sym}} -300 -250 0 0 {{name=BIAS only_toplevel=false value="{bias}"}}\n'
    flow = '.control\nset filetype=ascii\nalter vd 0.7\nop\nwrite top.raw\nquit\n.endc'
    top += f'C {{devices/code_shown.sym}} -300 200 0 0 {{name=FLOW only_toplevel=true value="{flow}"}}\n'
    schematic = out / 'top.sch'; schematic.write_text(top)
    rc = out / 'xschemrc'
    pdk_rc = base / 'libs.tech/xschem/xschemrc'
    if not pdk_rc.is_file():
        raise ValueError(f'Missing PDK xschemrc: {pdk_rc}')
    rc.write_text(f'source {tcl_literal(pdk_rc)}\nappend XSCHEM_LIBRARY_PATH : {tcl_literal(out)}\nset netlist_dir {tcl_literal(out)}\nset no_ask_quit 1\n')
    return schematic, rc


def compare_export_to_raw(path):
    with path.open() as file:
        rows = list(csv.DictReader(file))
    if len(rows) != 1:
        raise ValueError(f'Expected exactly one MOS in {path}')
    row = rows[0]
    raw = parse_ascii_op(Path(row['raw_file']).read_text())
    # Both top and child have the same bias; use the hierarchy exported by xschem.
    hierarchy = row['hierarchy'].strip('.')
    prefix = '@' + ('n.' if row['family'] == 'ihp' else 'm.') + (hierarchy + '.' if hierarchy else '') + 'xm1.'
    gm_keys = [key for key in raw if key.startswith(prefix) and key.endswith('[gm]')]
    if len(gm_keys) != 1:
        raise ValueError(f'Ambiguous/missing gm for {prefix}: {gm_keys}')
    device = gm_keys[0][:-4]
    gm = raw[device+'[gm]']; gds = raw[device+'[gds]']
    current = raw[device+('[ids]' if row['family'] == 'ihp' else '[id]')]
    errors = {}
    for column, expected in {'gm_S': gm, 'gds_S': gds, 'id_A': current,
                             'gmid_1_V': abs(gm/current), 'intrinsic_gain': gm/gds}.items():
        actual = float(row[column])
        if not math.isfinite(actual) or not math.isfinite(expected) or not math.isclose(
                actual, expected, rel_tol=XSCHEM_REL_TOL, abs_tol=0):
            raise ValueError(f'{path.name} {column}: export={actual:.16g}, raw={expected:.16g}; '
                             f'exceeds xschem relative tolerance {XSCHEM_REL_TOL:g}')
        errors[column] = abs(actual/expected-1) if expected else 0
    return {'file': path.name, 'relative_tolerance': XSCHEM_REL_TOL,
            'max_relative_error': max(errors.values()), 'relative_errors': errors}


def run_logged(command, log, *, env=None, cwd=ROOT, timeout=240):
    with log.open('w') as output:
        process = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, env=env, cwd=cwd, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('iic-validation'))
    parser.add_argument('--pdk-root', type=Path, default=Path(os.environ.get('PDK_ROOT', '/foss/pdks')))
    parser.add_argument('--require-all', action='store_true')
    args = parser.parse_args()
    out = (args.output / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')).resolve()
    out.mkdir(parents=True)
    report = {'iic_version': os.environ.get('IIC_OSIC_TOOLS_VERSION', 'unknown'), 'checks': []}
    report_path = out / 'report.json'
    def record(name, status, **extra):
        report['checks'].append(dict(name=name, status=status, **extra))
        report_path.write_text(json.dumps(report, indent=2)+'\n')
        print(name, status, extra.get('error', ''), flush=True)
    missing = [name for name in ('xschem', 'ngspice') if not shutil.which(name)]
    if missing or not os.environ.get('DISPLAY'):
        record('environment', 'failed', error='Need an X11 display and IIC tools; missing: '+', '.join(missing))
        print('Report:', report_path)
        return 2
    report['tool_versions'] = {}
    for tool in ('xschem', 'ngspice'):
        version = subprocess.run([tool, '--version'], stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True, timeout=15)
        report['tool_versions'][tool] = version.stdout.strip()
    try:
        code = run_logged([sys.executable, str(ROOT/'tools/run_tests.py'), '--require-gui'], out/'tests.log')
        record('native-suite', 'passed' if code == 0 else 'failed')
        if code: print((out/'tests.log').read_text()[-10000:], flush=True)
        command = [sys.executable, str(ROOT/'tools/check_iic.py'), '--pdk-root', str(args.pdk_root), '--output', str(out/'pdk')]
        if args.require_all: command.append('--require-all')
        code = run_logged(command, out/'pdk.log', timeout=900)
        record('ngspice-pdk-metrics', 'passed' if code == 0 else 'failed')
        if code:
            print((out/'pdk.log').read_text()[-10000:], flush=True)
            for log in (out/'pdk').rglob('*.log'):
                print(log.name, log.read_text()[-3000:], flush=True)
    except (OSError, subprocess.TimeoutExpired) as exc:
        record('test-runner', 'failed', error=str(exc))
    for pdk in PDKS:
        base = (args.pdk_root/pdk).resolve()
        if not base.is_dir():
            record(pdk+'-xschem', 'failed' if args.require_all else 'not-installed', error='PDK directory is missing')
            continue
        directory = out/pdk; directory.mkdir()
        try:
            lookup = None; sweep = None
            for polarity in ('n', 'p'):
                _, instance, _, _, _, vd, _ = configuration(pdk, base, polarity)
                model = instance.split()[5]
                csv_path = directory/(polarity+'mos-lookup.csv')
                command = [sys.executable, str(ROOT/'tools/characterize.py'), '--pdk', pdk, '--model', model,
                           '--pdk-root', str(args.pdk_root), '--lengths', '0.5', '1.0', '--vds', str(.7 if polarity=='n' else -.7),
                           '--vgs-start', '0.2', '--vgs-step', '0.05', '--output', str(csv_path)]
                code = run_logged(command, directory/(polarity+'mos-characterize.log'), timeout=300)
                if code or not csv_path.is_file():
                    raise ValueError(f'{polarity}MOS characterization failed: '+(directory/(polarity+'mos-characterize.log')).read_text()[-2500:])
                manifest = json.loads(csv_path.with_suffix('.json').read_text())
                record(pdk+'-'+polarity+'mos-characterization', 'passed', samples=sum(s['samples'] for s in manifest['sweeps']))
                if polarity == 'n': lookup = csv_path; sweep = manifest['sweeps'][0]['raw']
            schematic, rc = make_testbench(pdk, base, directory)
            env = dict(os.environ, PDK=pdk, PDKPATH=str(base), SPICE_USERINIT_DIR=str(base/'libs.tech/ngspice'),
                       ANALOG_LENS_ROOT=str(ROOT), ANALOG_LENS_OUTPUT=str(directory),
                       ANALOG_LENS_LOOKUP=str(lookup), ANALOG_LENS_SWEEP=str(sweep))
            code = run_logged(['xschem', '-r', '-s', '--rcfile', str(rc), '--script', str(ROOT/'tests/iic_live.tcl'), str(schematic)],
                              directory/'xschem.log', env=env, cwd=directory, timeout=240)
            if code or not (directory/'passed.txt').is_file():
                raise ValueError('Live xschem checks failed; inspect xschem.log')
            comparisons = [compare_export_to_raw(directory/name) for name in ('top.csv', 'child.csv', 'native.csv')]
            record(pdk+'-xschem', 'passed', comparisons=comparisons)
        except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as exc:
            record(pdk+'-xschem', 'failed', error=str(exc))
            log = directory/'xschem.log'
            if log.is_file(): print(log.read_text()[-10000:], flush=True)
            # A failing GUI prerequisite can block every following PDK behind
            # the same dialog. Retain this report and fail promptly for diagnosis.
            print('Report:', report_path, flush=True)
            return 1
    print('Report:', report_path)
    return 1 if any(check['status']=='failed' for check in report['checks']) else 0


if __name__ == '__main__':
    raise SystemExit(main())
