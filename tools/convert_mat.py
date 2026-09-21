#!/usr/bin/env python3
"""Convert a Murmann/pygmid-style MOS lookup MAT file to Analog Lens CSV.

Requires scipy and numpy (available in typical IIC-OSIC-TOOLS environments).
The user supplies process metadata and explicitly declares coordinate units.
No pickle files are accepted. MAT v7.3/HDF5 files are not supported by loadmat.
"""
import argparse
import csv
from pathlib import Path
import sys

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('input', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--pdk', required=True)
    p.add_argument('--model', required=True)
    p.add_argument('--corner', required=True)
    p.add_argument('--temp-c', type=float, required=True)
    p.add_argument('--total-width-um', type=float, required=True, help='Total reference width including parallel multiplicity.')
    p.add_argument('--length-unit', choices=['um','m'], required=True)
    p.add_argument('--variable', help='MAT structure name, for example nch; omit for flat fields.')
    p.add_argument('--cgg-is-total', action='store_true', help='Declare CGG already includes the relevant overlap capacitances. Otherwise fT is omitted.')
    args = p.parse_args()
    try:
        import numpy as np
        from scipy.io import loadmat
    except ImportError:
        p.error('This optional converter needs scipy and numpy. The xschem extension itself has no Python dependencies.')
    if args.input.resolve() == args.output.resolve():
        p.error('Input and output must differ.')
    if not np.isfinite(args.total_width_um) or args.total_width_um <= 0 or not np.isfinite(args.temp_c):
        p.error('Width must be positive and temperature finite.')
    try:
        data = loadmat(args.input, struct_as_record=False, squeeze_me=False)
        if args.variable:
            obj = data[args.variable].item()
            data = {name: getattr(obj, name) for name in obj._fieldnames}
        data = {k.upper(): v for k,v in data.items()}
        axes = [np.asarray(data[k], dtype=float).ravel() for k in ('L','VGS','VDS','VSB')]
        shape = tuple(len(a) for a in axes)
        arrays = {}
        for field in ('ID','GM','GDS') + (('CGG',) if args.cgg_is_total else ()):
            a = np.asarray(data[field], dtype=float)
            if a.shape != shape:
                raise ValueError(f'{field} has shape {a.shape}; expected L,VGS,VDS,VSB = {shape}. No guessed reshaping is performed.')
            arrays[field] = a
        header = ['pdk','model','corner','temp_c','vds_v','vsb_v','length_um','total_width_um','id_a','gm_s','gds_s','cgg_total_f']
        with args.output.open('w', newline='', encoding='utf-8') as f:
            out = csv.writer(f); out.writerow(header)
            count = 0
            for index in np.ndindex(shape):
                l, vgs, vds, vsb = (axes[n][index[n]] for n in range(4))
                if not all(np.isfinite(x) for x in (l,vgs,vds,vsb)):
                    continue
                vals = [arrays[k][index] for k in ('ID','GM','GDS')]
                if not all(np.isfinite(x) for x in vals):
                    continue
                cgg = arrays['CGG'][index] if 'CGG' in arrays else ''
                out.writerow([args.pdk,args.model,args.corner,args.temp_c,vds,vsb,l*(1e6 if args.length_unit=='m' else 1),args.total_width_um,*vals,cgg])
                count += 1
        print(f'Wrote {count} samples to {args.output}')
    except (OSError, KeyError, ValueError, NotImplementedError, AttributeError) as exc:
        p.exit(1, f'Conversion failed: {exc}\n')

if __name__ == '__main__':
    main()
