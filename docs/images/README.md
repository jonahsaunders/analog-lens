# README screenshots

These PNGs capture the actual Tcl/Tk widgets in `lib/gui.tcl`. They use
synthetic fixtures and do not show a live xschem session or PDK simulation.
The `DEMO ONLY` label is set in the capture session's header; it is not a
change to the extension's normal interface.

| Image | Data source | View |
|---|---|---|
| `operating-point.png` | `tests/mock_xschem.tcl` | M1 selected, with M2 marked for review and missing parameters shown as `—` |
| `gmid-explorer.png` | `examples/lookup-template.csv` | Intrinsic gain for two channel lengths, with the synthetic 0.3 µm / 16 V⁻¹ / 800 µS sizing example |

## Regenerate

On Linux, install Python with tkinter, Pillow with XCB support, Xvfb, xauth,
and standard TrueType fonts. From the repository root, run:

```sh
xvfb-run -a -s '-screen 0 1440x1000x24' python3 tools/capture_screenshots.py
```

On an existing X11 display of at least 1440×1000, you can also run:

```sh
python3 tools/capture_screenshots.py
```

The script captures the 1380×940 application content area using the `clam`
theme and a fixed Tk scale. Keep the application unobscured when using a
normal desktop. Font rendering may vary between Linux distributions.
It writes both PNGs to this directory. No xschem, ngspice, or PDK is required.
The Python image dependency is only needed for this documentation utility.

After regenerating, check both images for clipped labels and curves before
committing them. These captures demonstrate widget rendering; they do not
replace the validation described in `PDK_SUPPORT.md` and `VALIDATION.md`.
