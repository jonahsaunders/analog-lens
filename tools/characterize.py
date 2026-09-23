#!/usr/bin/env python3
"""Characterize installed IIC MOS models with real ngspice DC sweeps.

No model files are copied or modified. CSV publication is atomic and occurs
only after every requested length succeeds. A JSON manifest retains provenance.
"""
import argparse
import csv
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

from check_iic import PDKS, configuration

PROFILES = {
    'sky130A': ('nfet_01v8', 'pfet_01v8', 'tt', 1.8, .15),
    'gf180mcuD': ('nfet_03v3', 'pfet_03v3', 'typical', 3.3, .28),
    'ihp-sg13g2': ('sg13_lv_nmos', 'sg13_lv_pmos', 'mos_tt', 1.2, .13),
    'ihp-sg13cmos5l': ('sg13_lv_nmos', 'sg13_lv_pmos', 'mos_tt', 1.2, .13),
}
FIELDS = ['pdk', 'model', 'corner', 'temp_c', 'vds_v', 'vsb_v', 'length_um',
          'total_width_um', 'id_a', 'gm_s', 'gds_s', 'cgg_total_f', 'vgs_v']


def parse_ascii_sweep(text):
    """Return all real points, preserving simulator sweep order."""
    if 'Flags: real' not in text or 'Values:' not in text:
        raise ValueError('Expected a real ASCII raw file.')
    header, payload = text.split('Values:', 1)
    names = re.findall(r'^\s*\d+\s+(\S+)\s+\S+\s*$', header.split('Variables:', 1)[1], re.M)
    count = int(re.search(r'No\. Points:\s*(\d+)', header)[1])
    if not names or not 2 <= count <= 10001:
        raise ValueError('Sweep must contain 2–10001 points.')
    lines = [line.strip() for line in payload.splitlines() if line.strip()]
    if len(lines) != count * len(names):
        raise ValueError('Raw data point count is inconsistent.')
    names = [re.sub(r'^[vi]\((@.*)\)$', r'\1', n.lower()) for n in names]
    points = []
    for i in range(count):
        block = lines[i*len(names):(i+1)*len(names)]
        first = block[0].split()
        if len(first) != 2 or int(first[0]) != i:
            raise ValueError('Unexpected raw sample index.')
        values = [float(first[1])] + [float(v) for v in block[1:]]
        if not all(math.isfinite(v) for v in values):
            raise ValueError('Nonfinite simulator result.')
        points.append(dict(zip(names, values)))
    return points


def validate_request(args):
    profile = PROFILES[args.pdk]
    args.model = re.sub(r'^(sky130_fd_pr__|gf180mcu_fd_pr__)', '', args.model)
    if args.model not in profile[:2]:
        raise ValueError(f'Model must be {profile[0]} or {profile[1]} for {args.pdk}.')
    args.polarity = 'n' if args.model == profile[0] else 'p'
    args.sign = 1 if args.polarity == 'n' else -1
    if args.corner is None:
        args.corner = profile[2]
    if not re.fullmatch(r'[A-Za-z0-9_]+', args.corner):
        raise ValueError('Corner must be an installed library section name.')
    for name in ('width', 'temp', 'vds', 'vsb', 'vgs_start', 'vgs_stop', 'vgs_step'):
        value = getattr(args, name)
        if value is not None and not math.isfinite(value):
            raise ValueError(f'{name} must be finite.')
    if args.vgs_stop is None:
        args.vgs_stop = profile[3]
    if args.vds is None:
        args.vds = args.sign * profile[3] / 2
    if not 0 < args.width <= 10000 or not -100 <= args.temp <= 250:
        raise ValueError('Use width 0–10000 µm and temperature −100–250 °C.')
    if not 0 < args.sign*args.vds <= profile[3] or abs(args.vsb) > profile[3]:
        raise ValueError('Vds must have the device polarity and be within its nominal voltage; check Vsb.')
    if not 0 <= args.vgs_start < args.vgs_stop <= profile[3] or args.vgs_step <= 0:
        raise ValueError('Use an increasing Vgs magnitude sweep within the nominal voltage.')
    count = (args.vgs_stop-args.vgs_start)/args.vgs_step
    if not 1 <= count <= 10000:
        raise ValueError('Request 2–10001 sweep samples.')
    if not 1 <= len(args.lengths) <= 32 or len(set(args.lengths)) != len(args.lengths):
        raise ValueError('Choose 1–32 unique lengths.')
    if any(not math.isfinite(v) or not profile[4] <= v <= 1000 for v in args.lengths):
        raise ValueError(f'Lengths must be between {profile[4]} and 1000 µm for this profile.')


def make_deck(args, base, length, raw_name):
    includes, instance, prefix, current, _, _, psp = configuration(args.pdk, base, args.polarity)
    includes = re.sub(r'(?m)^(\.lib\s+"[^"]+")\s+\S+', lambda m: m[1]+' '+args.corner, includes)
    suffix = '' if args.pdk.startswith('sky') else 'u'
    instance = re.sub(r'\bw=\S+', f'w={args.width:.12g}{suffix}', instance)
    instance = re.sub(r'\bl=\S+', f'l={length:.12g}{suffix}', instance)
    instance = instance.replace('d g 0 0', 'd g 0 b')
    params = [current, 'gm', 'gds', 'cgg', 'vgs']
    if psp:
        params += ['cgsol', 'cgdol']
    saves = '\n'.join('.save '+prefix+'['+p+']' for p in params)
    deck = (f'Analog Lens real characterization: {args.pdk} {args.model}\n{includes}\n'
            f'.temp {args.temp:.12g}\nvg g 0 0\nvd d 0 {args.vds:.12g}\nvb b 0 {-args.vsb:.12g}\n'
            f'{instance}\n.save all\n{saves}\n.control\nset filetype=ascii\n'
            f'dc vg {args.sign*args.vgs_start:.12g} {args.sign*args.vgs_stop:.12g} {args.sign*args.vgs_step:.12g}\n'
            f'write {raw_name}\nquit\n.endc\n.end\n')
    return deck, prefix, current, psp


def rows_from_points(points, args, length, prefix, current, psp):
    rows = []
    for point in points:
        def value(name):
            return point[prefix+'['+name+']']
        ids, gm, gds = value(current), value('gm'), value('gds')
        if abs(ids) <= 1e-12 or gm <= 0 or gds <= 0:
            continue
        cgg = value('cgg') + (value('cgsol')+value('cgdol') if psp else 0)
        rows.append(dict(zip(FIELDS, [args.pdk, args.model, args.corner, args.temp, args.vds, args.vsb,
                                     length, args.width, ids, gm, gds, cgg, point['v(g)']])))
    if len(rows) < 2:
        raise ValueError('Fewer than two usable samples; adjust the gate sweep or bias.')
    # Do not sort away a folded/nonmonotonic curve: sizing must not choose a branch silently.
    ratios = [abs(r['gm_s']/r['id_a']) for r in rows]
    deltas = [b-a for a,b in zip(ratios, ratios[1:])]
    monotonic = all(d > 1e-9 for d in deltas) or all(d < -1e-9 for d in deltas)
    return rows, monotonic


def atomic_text(path, text):
    fd, name = tempfile.mkstemp(prefix='.'+path.name, dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            stream.write(text)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def simulate(command, deck, log, env, timeout=120):
    with log.open('w') as output:
        child = subprocess.Popen(command, cwd=deck.parent, env=env, stdout=output, stderr=subprocess.STDOUT)
        try:
            return child.wait(timeout=timeout)
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=.5)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pdk', choices=PDKS, required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--pdk-root', type=Path, default=Path(os.environ.get('PDK_ROOT', '/foss/pdks')))
    parser.add_argument('--lengths', type=float, nargs='+', required=True)
    parser.add_argument('--width', type=float, default=10.)
    parser.add_argument('--corner')
    parser.add_argument('--temp', type=float, default=27.)
    parser.add_argument('--vds', type=float)
    parser.add_argument('--vsb', type=float, default=0.)
    parser.add_argument('--vgs-start', type=float, default=.1, help='Magnitude; polarity is applied automatically.')
    parser.add_argument('--vgs-stop', type=float)
    parser.add_argument('--vgs-step', type=float, default=.025)
    parser.add_argument('--output', type=Path, required=True, help='New CSV path; existing output is never overwritten.')
    args = parser.parse_args(argv)
    try:
        validate_request(args)
        binary = shutil.which('ngspice')
        if not binary:
            raise ValueError('ngspice is missing. Run inside IIC-OSIC-TOOLS.')
        base = (args.pdk_root/args.pdk).resolve()
        if not base.is_dir():
            raise ValueError(f'Installed PDK not found: {base}')
        output = args.output.resolve()
        manifest = output.with_suffix('.json')
        if output.exists() or manifest.exists():
            raise ValueError('Choose a new output path; existing characterization is preserved.')
        output.parent.mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix=output.stem+'-decks-', dir=output.parent))
        env = dict(os.environ, PDK=args.pdk, PDKPATH=str(base), SPICE_USERINIT_DIR=str(base/'libs.tech/ngspice'))
        rows = []; sweeps = []; dependencies = []
        for i, length in enumerate(args.lengths):
            print(f'Length {i+1}/{len(args.lengths)}: {length:g} µm', flush=True)
            deck = work/f'length-{i}.spice'; raw = work/f'length-{i}.raw'; log = work/f'length-{i}.log'
            text, prefix, current, psp = make_deck(args, base, length, raw.name)
            deck.write_text(text)
            from project_data import read_graph, check_manifest
            dependency, _ = read_graph(deck, init_dir=base/'libs.tech/ngspice')
            code = simulate([binary, '-b', str(deck)], deck, log, env)
            if code or not raw.is_file() or re.search(r'(?im)^(fatal error|error:|doanalyses:)', log.read_text()):
                raise ValueError(f'ngspice failed; inspect {log}')
            if check_manifest(dependency, full=True)['state'] == 'changed':
                raise ValueError('Model inputs changed during the sweep; repeat with stable model files.')
            dependencies.append(dependency)
            points = parse_ascii_sweep(raw.read_text())
            curve, monotonic = rows_from_points(points, args, length, prefix, current, psp)
            rows.extend(curve)
            sweeps.append(dict(length_um=length, samples=len(curve), monotonic_gmid=monotonic,
                               raw=str(raw), deck=str(deck), deck_sha256=hashlib.sha256(deck.read_bytes()).hexdigest()))
            if not monotonic:
                print('Curve has multiple gm/Id branches. Plotting is available; narrow the sweep before sizing.', flush=True)
        csv_text = io.StringIO(); writer = csv.DictWriter(csv_text, fieldnames=FIELDS)
        writer.writeheader(); writer.writerows(rows)
        result = dict(format='analog-lens-characterization', schema=1, status='completed',
                      pdk=args.pdk, model=args.model, corner=args.corner, temp_c=args.temp, vds_v=args.vds, vsb_v=args.vsb,
                      total_width_um=args.width, fingers=1, multiplier=1, pdk_path=str(base),
                      iic_version=os.environ.get('IIC_OSIC_TOOLS_VERSION', 'unknown'),
                      ngspice_version=subprocess.check_output([binary, '--version'], text=True).strip(),
                      csv_sha256=hashlib.sha256(csv_text.getvalue().encode()).hexdigest(), sweeps=sweeps, dependencies=dependencies)
        atomic_text(manifest, json.dumps(result, indent=2)+'\n')
        atomic_text(output, csv_text.getvalue())
        print(f'Completed: {len(rows)} measured samples → {output}', flush=True)
        return 0
    except KeyboardInterrupt:
        print('Characterization cancelled. No partial lookup CSV was published.', file=sys.stderr)
        return 130
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print(f'Characterization failed: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    raise SystemExit(main())
