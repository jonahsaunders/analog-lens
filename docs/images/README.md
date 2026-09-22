# Interface screenshots

The `iic-*.png` files capture the real IIC-OSIC-TOOLS workflow below. The other PNGs capture the actual Tcl/Tk analysis widgets using synthetic fixtures; those do not show a live xschem session or PDK simulation.
The `DEMO ONLY` label is set in the capture session's header; it is not a
change to the extension's normal interface.

| Image | Data source | View |
|---|---|---|
| `iic-inspector.png` | Passing IIC 2026.08 run, IHP SG13G2 NMOS | Embedded sidebar with real simulator measurements and source-state indicator |
| `iic-sizing-preview.png` | Same run, SKY130 NMOS measured lookup | Width 10 → 20 µm preview; one finger/copy, Apply and Undo workflow |
| `iic-characterization.png` | Same run, SKY130 NMOS | Completed seven-sample real ngspice sweep, automatically loaded into the explorer |
| `iic-sizing-verification.png` | v0.5 passing IIC 2026.08 run, SKY130 NMOS | Actual rerun measurements, before/after changes and signed target errors; a reported Miss is an honest target verdict |
| `iic-project-results.png` | Same v0.5 run, SKY130 NMOS | Archived native/OP runs and named sizing baselines |
| `iic-characterization-batch.png` | Same v0.5 run, SKY130 NMOS | Completed 27/85 °C batch, with both conditions reused from verified cache |
| `operating-point.png` | `tests/mock_xschem.tcl` | M1 selected, with M2 marked for review and missing parameters shown as `—` |
| `gmid-explorer.png` | `examples/lookup-template.csv` | Intrinsic gain for two channel lengths, with the synthetic 0.3 µm / 16 V⁻¹ / 800 µS sizing example |
| `compare-runs.png` | `tests/mock_xschem.tcl`, then a synthetic change to M1 gm | Baseline and current metrics, including a +25% gm/Id change |
| `setup-help.png` | Default bias targets | Editable design checks and scrollable workflow/keyboard help |
| `lookup-data.png` | `examples/lookup-template.csv` | Numeric snapshot of the plotted synthetic lookup values |
| `run-log.png` | Explicitly labeled synthetic explanatory text | Log reading, tail following, copying, and closing |

The original inspector, sizing-preview and single-characterization captures come from [passing run 35738760853](https://github.com/jonahsaunders/analog-lens/actions/runs/35738760853), code `e01f9d7f18acf3fdf7f6948c65f066066d0009b0`, artifact `10698881729`. `tests/iic_live.tcl` and `tools/capture_live.py` create them while testing actual xschem. Run `bash tools/run_iic_container.sh` to reproduce the real workflow. The validation artifact contains source decks, simulator raw data and characterization provenance.

The three new v0.5 captures come from [passing run 35756609167](https://github.com/jonahsaunders/analog-lens/actions/runs/35756609167), code `09c9cec27dd97a263b7e0ae2ede7118de88bad61`, artifact `10707733195`. The artifact identifier and measured verification values are retained in the [v0.5 validation summary](../validation/iic-2026.08-v0.5.json). These are direct window captures without altered measurements.

The v0.6 captures below come from [passing run 35762801866](https://github.com/jonahsaunders/analog-lens/actions/runs/35762801866), code `bc6a00bdbe36e5ea8f85e5a2229fb08c0ec35cf7`, artifact `10710882913`. They show setup, sizing, verification and characterization in the actual SKY130 NMOS workflow; none use synthetic data.

| Image | View |
|---|---|
| `iic-sizing-workspace.png` | Unified targets, conditions, inline preview area and measured tolerance bands |
| `iic-project-setup.png` | Optional setup checks; opening the wizard starts no simulation |
| `iic-verification-chart.png` | Target/before/after table and two measured tolerance bands |
| `iic-characterization-v06.png` | Installed corner choices and device-condition reuse controls |

## v0.6.1 real IIC captures

`iic-hig-workspace.png` and `iic-hig-characterization.png` show the real SKY130
NMOS workflow from [passing run 35767855614](https://github.com/jonahsaunders/analog-lens/actions/runs/35767855614),
code `7be289359dfd51ab7c8a2aa5735bce77d98d4ac9`, artifact `10713620068`.
The first shows measured target errors and the second shows seven generated
lookup samples. These are direct captures; a reported target Miss is preserved.
See the [v0.6.1 validation summary](../validation/iic-2026.08-v0.6.1.json).

## v0.6.1 GUI audit captures

The three `hig-*.png` images below come from `tools/capture_gui_audit.py` at
code `7be289359dfd51ab7c8a2aa5735bce77d98d4ac9`. They show actual Tcl/Tk
rendering with synthetic fixtures, not measured PDK results. No pixels or
measurements were edited after capture.

| Image | Capture mode and view |
|---|---|
| `hig-large-characterization.png` | 14-point system text, 640×520; scrolling form and wrapping persistent actions |
| `hig-large-setup.png` | 14-point system text, 640×520; optional setup with scrolling content and visible actions |
| `hig-dark-workspace.png` | Representative dark host theme, 1380×940; synthetic sizing and numeric verification |

The [v0.6.1 audit](../GUI_AUDIT_061.md) contains reproduction commands,
review scope and accessibility limits. Earlier screenshots above retain
their original version and workflow provenance.

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
