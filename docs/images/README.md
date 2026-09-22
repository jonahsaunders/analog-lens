# Interface screenshots

The `iic-*.png` files capture the real IIC-OSIC-TOOLS workflow below. The other PNGs capture the actual Tcl/Tk analysis widgets using synthetic fixtures; those do not show a live xschem session or PDK simulation.
The `DEMO ONLY` label is set in the capture session's header; it is not a
change to the extension's normal interface.

| Image | Data source | View |
|---|---|---|
| `iic-inspector.png` | Passing IIC 2026.08 run, IHP SG13G2 NMOS | Embedded sidebar with real simulator measurements and source-state indicator |
| `iic-sizing-preview.png` | Same run, SKY130 NMOS measured lookup | Width 10 → 20 µm preview; one finger/copy, Apply and Undo workflow |
| `iic-characterization.png` | Same run, SKY130 NMOS | Completed seven-sample real ngspice sweep, automatically loaded into the explorer |
| `operating-point.png` | `tests/mock_xschem.tcl` | M1 selected, with M2 marked for review and missing parameters shown as `—` |
| `gmid-explorer.png` | `examples/lookup-template.csv` | Intrinsic gain for two channel lengths, with the synthetic 0.3 µm / 16 V⁻¹ / 800 µS sizing example |
| `compare-runs.png` | `tests/mock_xschem.tcl`, then a synthetic change to M1 gm | Baseline and current metrics, including a +25% gm/Id change |
| `setup-help.png` | Default bias targets | Editable design checks and scrollable workflow/keyboard help |
| `lookup-data.png` | `examples/lookup-template.csv` | Numeric snapshot of the plotted synthetic lookup values |
| `run-log.png` | Explicitly labeled synthetic explanatory text | Log reading, tail following, copying, and closing |

The real captures come from [passing run 35738760853](https://github.com/jonahsaunders/analog-lens/actions/runs/35738760853), code `e01f9d7f18acf3fdf7f6948c65f066066d0009b0`, artifact `10698881729`. `tests/iic_live.tcl` and `tools/capture_live.py` create them while testing actual xschem. Run `bash tools/run_iic_container.sh` to reproduce the real workflow. The validation artifact contains source decks, simulator raw data and characterization provenance.

## Regenerate synthetic previews

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
