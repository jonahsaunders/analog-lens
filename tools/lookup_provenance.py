#!/usr/bin/env python3
"""Validate lookup CSVs against their recorded simulator and model inputs.

Imported CSVs remain usable but never acquire verified status from their labels.
All manifests are parsed as data. No command stored in a manifest is executed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from project_data import check_manifest, tcl


def inspect_lookup(path, simulator=None, seen=None):
    path = Path(path).resolve()
    seen = set() if seen is None else set(seen)
    if path in seen or len(seen) > 8:
        return dict(state='outdated', reason='Cyclic or excessive batch provenance.')
    seen.add(path)
    single, batch = path.with_suffix('.json'), path.with_suffix('.batch.json')
    if not single.exists() and not batch.exists():
        return dict(state='imported', reason='Imported-unverified: no generated provenance manifest.')
    try:
        if single.exists() and batch.exists():
            raise ValueError('Ambiguous provenance: both single and batch manifests exist.')
        manifest = single if single.exists() else batch
        if manifest.stat().st_size > 20_000_000:
            raise ValueError('Provenance manifest exceeds 20 MB.')
        data = json.loads(manifest.read_text())
        if data['schema'] != 1 or data['status'] != 'completed':
            raise ValueError('Unsupported or incomplete provenance manifest.')
        if hashlib.sha256(path.read_bytes()).hexdigest() != data['csv_sha256']:
            raise ValueError('CSV content differs from its recorded hash.')
        if data['format'] == 'analog-lens-batch':
            jobs = data['jobs']
            if not isinstance(jobs, list) or not 1 <= len(jobs) <= 256:
                raise ValueError('Invalid batch jobs.')
            results = [inspect_lookup(Path(job['csv']) if Path(job['csv']).is_absolute()
                                      else manifest.parent/job['csv'], simulator, seen) for job in jobs]
            for result in results:
                if result['state'] == 'outdated':
                    return result
            if any(result['state'] != 'verified' for result in results):
                return dict(state='unverified', reason='Batch has unverified source lookups.')
        elif data['format'] == 'analog-lens-characterization':
            dependencies = data['dependencies']
            if not dependencies or not all(dep.get('files') for dep in dependencies):
                return dict(state='unverified', reason='Model dependency records are incomplete.')
            for dependency in dependencies:
                status = check_manifest(dependency, full=True)
                if status['state'] == 'changed':
                    return dict(state='outdated', reason='Model or characterization input changed or is missing.',
                                changed=status['changed'])
                if status['state'] != 'current':
                    return dict(state='unverified', reason='Some model dependencies were not resolved.')
            if simulator is None:
                return dict(state='unverified', reason='Current ngspice version could not be checked.')
            if simulator.strip() != data['ngspice_version'].strip():
                raise ValueError('ngspice version differs from the characterization run.')
        else:
            raise ValueError('Unsupported provenance format.')
        return dict(state='verified', reason='Verified: CSV, model inputs and ngspice version match.')
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
        return dict(state='outdated', reason=str(exc))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    args = parser.parse_args()
    try:
        simulator = subprocess.check_output(['ngspice', '--version'], text=True,
                                            stderr=subprocess.DEVNULL, timeout=10).strip()
    except (OSError, subprocess.SubprocessError):
        simulator = None
    print(tcl(inspect_lookup(args.path, simulator)))


if __name__ == '__main__':
    main()
