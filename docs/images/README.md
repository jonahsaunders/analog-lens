# Interface screenshots

These PNGs capture the actual Tcl/Tk widgets in `lib/gui.tcl`. They use
synthetic fixtures and do not show a live xschem session or PDK simulation.
The `DEMO ONLY` label is set in the capture session's header; it is not a
change to the extension's normal interface.

| Image | Data source | View |
|---|---|---|
| `operating-point.png` | `tests/mock_xschem.tcl` | M1 selected, with M2 marked for review and missing parameters shown as `—` |
| `gmid-explorer.png` | `examples/lookup-template.csv` | Intrinsic gain for two channel lengths, with the synthetic 0.3 µm / 16 V⁻¹ / 800 µS sizing example |
| `compare-runs.png` | `tests/mock_xschem.tcl`, then a synthetic change to M1 gm | Baseline and current metrics, including a +25% gm/Id change |
| `setup-help.png` | Default bias targets | Editable design checks and scrollable workflow/keyboard help |
| `lookup-data.png` | `examples/lookup-template.csv` | Numeric snapshot of the plotted synthetic lookup values |
| `run-log.png` | Explicitly labeled synthetic explanatory text | Log reading, tail following, copying, and closing |

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

The script captures the four tabs at 1380×940, the lookup-data dialog at
760×440, and the log at 840×460, using the `clam` theme and a fixed Tk scale.
Keep the application unobscured when using a
normal desktop. Font rendering may vary between Linux distributions.
It writes seven PNGs to this directory, including the environment-check dialog. No xschem, ngspice, or PDK is required.
The Python image dependency is only needed for this documentation utility.

For additional minimum-size, larger-text, empty-search, and dark-theme
captures, choose a separate output directory:

```sh
xvfb-run -a -s '-screen 0 1440x1000x24' python3 tools/capture_screenshots.py \
  --audit --output-dir /tmp/analog-lens-gui-audit
```

After regenerating, check all images for clipped labels and curves before
committing them. These captures demonstrate widget rendering; they do not
replace the validation described in `PDK_SUPPORT.md` and `VALIDATION.md`.

The v0.4 captures include separate lookup filters, saved-baseline selection, and `environment-check.png`. The environment-check image demonstrates diagnostics in the capture environment; it is not a successful IIC validation report.
