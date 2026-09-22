#!/usr/bin/env python3
"""Capture one real xschem/Tk window during the IIC integration run."""
import argparse
import os
from pathlib import Path
from PIL import ImageGrab

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('bounds', type=int, nargs=4, help='x y width height')
args = parser.parse_args()
x, y, width, height = args.bounds
ImageGrab.grab(bbox=(x, y, x+width, y+height), xdisplay=os.environ['DISPLAY']).save(args.output)
