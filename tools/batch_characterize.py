#!/usr/bin/env python3
"""Reusable, resumable PVT/bias grids. Completed jobs survive cancellation.

Cache identity includes exact request, model/source contents, simulator version
and generator code. Combined CSV is published only when every job succeeds.
"""
import argparse
import csv
import hashlib
import io
import itertools
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

import characterize
from project_data import read_graph, check_manifest


def cache_key(request, dependencies, simulator):
    content = dict(request=request, files={p: s['sha256'] for p, s in dependencies['files'].items()},
                   simulator=simulator, generator=hashlib.sha256(Path(characterize.__file__).read_bytes()).hexdigest())
    return hashlib.sha256(json.dumps(content, sort_keys=True).encode()).hexdigest()


def valid_cache(csv_path, key):
    try:
        data = json.loads(csv_path.with_suffix('.json').read_text())
        meta = json.loads(csv_path.with_suffix('.cache.json').read_text())
        return (meta['key'] == key and data['status'] == 'completed' and
                data['csv_sha256'] == hashlib.sha256(csv_path.read_bytes()).hexdigest())
    except (OSError, ValueError, KeyError):
        return False


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pdk', choices=characterize.PDKS, required=True)
    p.add_argument('--model', required=True)
    p.add_argument('--pdk-root', type=Path, default=Path(os.environ.get('PDK_ROOT', '/foss/pdks')))
    p.add_argument('--lengths', type=float, nargs='+', required=True)
    p.add_argument('--width', type=float, default=10)
    p.add_argument('--corners', nargs='+', required=True)
    p.add_argument('--temps', type=float, nargs='+', required=True)
    p.add_argument('--vds-values', type=float, nargs='+', required=True)
    p.add_argument('--vsb-values', type=float, nargs='+', default=[0.])
    p.add_argument('--vgs-start', type=float, default=.1)
    p.add_argument('--vgs-stop', type=float)
    p.add_argument('--vgs-step', type=float, default=.025)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--cache', type=Path, required=True)
    args = p.parse_args(argv)
    try:
        grids = (args.corners, args.temps, args.vds_values, args.vsb_values)
        if any(len(set(values)) != len(values) for values in grids):
            raise ValueError('Batch grids must not contain duplicate conditions.')
        count = 1
        for values in grids:
            count *= len(values)
        if not 1 <= count <= 256:
            raise ValueError('Choose at most 256 condition combinations per batch.')
        requests = []
        for corner, temp, vds, vsb in itertools.product(*grids):
            job = argparse.Namespace(pdk=args.pdk, model=args.model, lengths=args.lengths,
                                     width=args.width, corner=corner, temp=temp, vds=vds, vsb=vsb,
                                     vgs_start=args.vgs_start, vgs_stop=args.vgs_stop, vgs_step=args.vgs_step)
            characterize.validate_request(job)
            requests.append(job)
        output = args.output.resolve()
        if output.exists():
            raise ValueError('Combined CSV already exists; choose a new output. Cached jobs are reusable.')
        output.parent.mkdir(parents=True, exist_ok=True); args.cache.mkdir(parents=True, exist_ok=True)
        simulator = subprocess.check_output(['ngspice', '--version'], text=True).strip()
        base = (args.pdk_root/args.pdk).resolve()
        state = dict(format='analog-lens-batch', schema=1, status='running', request={
            k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()}, jobs=[])
        manifest = output.with_suffix('.batch.json')
        rows = []
        for index, job in enumerate(requests):
            print(f'Condition {index+1}/{count}: {job.corner}, {job.temp:g} °C, Vds={job.vds:g}, Vsb={job.vsb:g}', flush=True)
            probe = output.parent/'dependency-probe.spice'
            probe.write_text(characterize.make_deck(job, base, job.lengths[0], 'probe.raw')[0])
            dependencies, _ = read_graph(probe)
            # The disposable probe's path is not part of model/cache identity.
            dependencies['files'].pop(str(probe), None)
            request = vars(job)
            key = cache_key(request, dependencies, simulator)
            directory = args.cache/key; directory.mkdir(exist_ok=True)
            csv_path = directory/'lookup.csv'
            cached = not dependencies['warnings'] and valid_cache(csv_path, key)
            if not cached:
                # Preserve interrupted/invalid outputs for inspection; write a new attempt.
                import tempfile
                attempt = Path(tempfile.mkdtemp(prefix='attempt-', dir=directory))
                generated = attempt/'lookup.csv'
                command = ['--pdk', job.pdk, '--model', job.model, '--pdk-root', str(args.pdk_root),
                           '--lengths', *map(str, job.lengths), '--output', str(generated)]
                for name in ('width', 'corner', 'temp', 'vds', 'vsb', 'vgs_start', 'vgs_stop', 'vgs_step'):
                    command.extend(['--'+name.replace('_', '-'), str(getattr(job, name))])
                code = characterize.main(command)
                if code == 130:
                    raise KeyboardInterrupt
                if code:
                    raise ValueError('A condition failed; completed jobs are retained for retry.')
                if check_manifest(dependencies, full=True)['state'] == 'changed':
                    raise ValueError('Model dependencies changed during characterization; retry with stable models.')
                shutil.copyfile(generated, csv_path)
                shutil.copyfile(generated.with_suffix('.json'), csv_path.with_suffix('.json'))
                characterize.atomic_text(csv_path.with_suffix('.cache.json'), json.dumps(dict(key=key)))
            else:
                print('Reusing verified cached samples.', flush=True)
            with csv_path.open() as stream:
                rows.extend(csv.DictReader(stream))
            state['jobs'].append(dict(request=request, csv=str(csv_path), cache_key=key, reused=cached))
            characterize.atomic_text(manifest, json.dumps(state, indent=2)+'\n')
        text = io.StringIO(); writer = csv.DictWriter(text, fieldnames=characterize.FIELDS)
        writer.writeheader(); writer.writerows(rows)
        state.update(status='completed', samples=len(rows), csv_sha256=hashlib.sha256(text.getvalue().encode()).hexdigest())
        characterize.atomic_text(manifest, json.dumps(state, indent=2)+'\n')
        characterize.atomic_text(output, text.getvalue())
        print(f'Completed batch: {count} conditions, {len(rows)} measured samples → {output}', flush=True)
        return 0
    except KeyboardInterrupt:
        if 'state' in locals():
            state['status'] = 'cancelled'; characterize.atomic_text(manifest, json.dumps(state, indent=2)+'\n')
        print('Batch cancelled. Completed conditions are cached; repeat the same request to resume.', flush=True)
        return 130
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        if 'state' in locals():
            state.update(status='failed', error=str(exc)); characterize.atomic_text(manifest, json.dumps(state, indent=2)+'\n')
        print('Batch failed: '+str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    raise SystemExit(main())
