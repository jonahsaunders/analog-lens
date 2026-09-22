#!/usr/bin/env python3
"""Run the complete suite; --require-gui makes missing/skipped GUI tests fail CI."""
import argparse
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--require-gui', action='store_true')
    args = parser.parse_args()
    if args.require_gui:
        if not os.environ.get('DISPLAY'):
            parser.exit(2, 'DISPLAY is required. Run with xvfb-run or inside the IIC desktop.\n')
        import tkinter
        window = tkinter.Tk()
        window.withdraw()
        print('Native GUI runtime: Tk', window.tk.call('package', 'require', 'Tk'), flush=True)
        window.destroy()
    suite = unittest.defaultTestLoader.discover(str(ROOT / 'tests'))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if args.require_gui and result.skipped:
        print('Required full suite skipped tests:', result.skipped, file=sys.stderr)
        return 1
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
