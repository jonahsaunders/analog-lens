#!/usr/bin/env python3
"""Measure large-table indexing without xschem or an X11 display."""
import argparse
import json
from pathlib import Path
import tkinter

ROOT = Path(__file__).resolve().parents[1]


def profile(count):
    t = tkinter.Tcl(); t.call('source', str(ROOT/'analog_lens.tcl'))
    t.call('set', 'sample_count', count)
    t.eval('''
        set rows {}
        for {set i 0} {$i < $sample_count} {incr i} {
            lappend rows [dict create slice {fixture nmos tt 27 0.9 0 10} length_um [expr {0.5+($i%8)*0.1}]]
        }
        set ::analog_lens::lut_rows $rows
        proc scan_lengths {} {
            set lengths {}
            foreach row $::analog_lens::lut_rows {lappend lengths [dict get $row length_um]}
            return [lsort -real -unique $lengths]
        }
    ''')
    scan = float(t.call('lindex', t.call('time', 'scan_lengths', 10), 0))/1000
    build = float(t.call('lindex', t.call('time', '::analog_lens::lookup_index', 1), 0))/1000
    cached = float(t.call('lindex', t.call('time', '::analog_lens::lookup_index', 1000), 0))/1000
    return dict(samples=count, scan_ms=scan, index_build_ms=build, cached_read_ms=cached)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--samples',type=int,default=100000)
    args=parser.parse_args()
    if not 1 <= args.samples <= 1000000: parser.error('Choose 1–1000000 samples.')
    print(json.dumps(profile(args.samples),indent=2))
