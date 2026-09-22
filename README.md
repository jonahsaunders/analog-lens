# Analog Lens for xschem

A native Tcl/Tk analysis extension. It adds an **Analog Lens** menu and a resizable analysis window inside xschem's process. No browser, server, account, or Python service is required.

Version 0.2.0 adds a GUI usability update informed by Apple's Human Interface Guidelines. The numerical engine, adapters, data parsing, xschem API contracts, and native GUI interactions have automated tests. The screenshots below show the real Tk interface with synthetic fixtures. Actual xschem/PDK simulations and GUI validation inside xschem require an IIC-OSIC-TOOLS installation; those were not available in the build environment. See `PDK_SUPPORT.md` for the exact support boundary and the [GUI audit](docs/GUI_AUDIT.md) for findings, changes, and platform validation limits.

## Interface preview

![Analog Lens operating-point inspector showing M1 and M2, their gm/Id and intrinsic gain, and the selected device's detailed metrics.](docs/images/operating-point.png)

**Operating-point inspector.** Browse device results, spot devices needing review, and inspect the selected transistor. This is a native Tk capture using the repository's synthetic test fixture, not measured PDK results. Missing parameters remain `—`.

See the [gm/Id explorer preview](#gmid-explorer) below. [Screenshot sources and regeneration instructions](docs/images/README.md) are included.

The inspector and help text scroll, numeric columns sort in both directions, and search filters have a clear empty state. **Run log** updates while ngspice runs. **View data** in the explorer opens a copyable table of lookup values. The extension keeps the host's ttk theme and uses its system fonts; it does not change xschem's global theme.

| Action | Linux / Windows | macOS binding |
|---|---|---|
| Find a device | Ctrl+F | Command+F |
| Load results | Ctrl+O | Command+O |
| Refresh | Ctrl+R | Command+R |
| Run operating point | Ctrl+Shift+R | Command+Shift+R |
| Export CSV | Ctrl+Shift+S | Command+Shift+S |
| Switch tabs | Ctrl+1–4 | Command+1–4 |
| Close Analog Lens | Ctrl+W | Command+W |

Shortcuts apply while the Analog Lens window has focus. The **Sort** menu offers keyboard access to table sorting. Use Tab / Shift+Tab between controls and Return in a numeric form to apply it. macOS bindings are implemented but have not been exercised on Aqua/VoiceOver.

## Install in IIC-OSIC-TOOLS

Extract this folder into your mounted designs directory. In the IIC terminal, run:

```sh
python3 /foss/designs/xschem-analog-lens/install.py --rc /foss/designs/YOUR_PROJECT/xschemrc
```

Replace `YOUR_PROJECT` with your existing project. The installer preserves the PDK setup, backs up `xschemrc`, and adds one source statement. Restart xschem and choose **Analog Lens → Open Analog Lens**.

For a persistent installation in a mounted directory, add:

```sh
--destination /foss/designs/plugins/analog-lens
```

The default destination is `~/.xschem/analog-lens`. This may be lost if your container home directory is not persisted. Projects with their own `xschemrc` must include the extension themselves; a user-level configuration is not always read when a project-level file exists.

To try it without editing any configuration, enter these lines in the xschem Tcl console:

```tcl
source /foss/designs/xschem-analog-lens/analog_lens.tcl
::analog_lens::show
```

Requirements: xschem with Tcl/Tk 8.6 or newer and the documented `xschem raw` API; ngspice on PATH; a working project PDK/model configuration. IHP requires the usual OSDI/PSP setup. The extension never edits installed PDK files. Load it **after** the PDK's xschemrc.

## Everyday workflow

1. Open your top-level simulation testbench in xschem.
2. Click **Operating point**. The extension traverses schematic hierarchy, generates parameter saves, netlists to a new file, and runs ngspice asynchronously. It preserves source schematics and existing simulation blocks.
3. Descend into the circuit. The table follows the current hierarchy. Select a transistor in xschem or the table to see its operating point and derived metrics.
4. Use **Locate in schematic** for cross-probing, or **Color by gm/Id** to highlight devices below, within, or above your targets using xschem palette layers 8, 4, and 6. This adds highlights; use xschem's Highlight menu to clear them. **Place annotation** places an optional annotation symbol; click in the schematic to position it. This is the only analysis action that intentionally adds a schematic object.
5. **Keep current results as baseline**, edit the circuit, rerun, and inspect **Compare runs**. Export CSV to retain a report.

The inspector displays Id/Ic, gm, gds/go, gm/Id, intrinsic gain, ro, Vgs, Vds, model Vth/Vdsat, model headroom, Cgg, and estimated fT when the required vectors exist. Missing results are `—`; they are never silently replaced with zero. Width, length, finger count, and multiplier are shown as entered, without guessing units or double-counting multiplicity.

The device list is scoped to the currently open hierarchy level. To see transistors in a subcircuit, descend into that subcircuit. The OP run itself gathers saves recursively from schematic-backed subcircuits. Arbitrary external SPICE subcircuits, encrypted models, unsupported primitive wrappers, and multi-device composite models may require an adapter or a separately generated raw file.

### Existing simulation flows

You can use **Load results…** with `op`, `dc`, or `tran`. Set **Sample** and **Dataset** to select a saved point (zero-based). The first version does not interpolate between samples or follow waveform cursor B. Load a top-level raw file at the top level, then descend, so xschem's raw hierarchy mapping is correct.

**Operating point** intentionally replaces top-level `.control` blocks and top-level analyses in its disposable netlist. It retains models, includes, sources, and `.param` statements. If your bias/model setup relies on `alter`, `alterparam`, `pre_osdi`, `set`, or other commands inside `.control`, use your own simulation and **Load results**, or move that required setup into the normal model/environment setup. Included files with their own control blocks are not rewritten. Run logs and generated decks stay in xschem's simulation directory.

Changing tabs or hierarchy while ngspice runs will not load results into the wrong schematic; the status bar tells you which raw file to load after returning to the testbench.

## gm/Id explorer

![Analog Lens gm/Id explorer showing illustrative intrinsic-gain curves for 0.3 and 0.6 micrometer channel lengths, plus a sizing estimate.](docs/images/gmid-explorer.png)

**gm/Id explorer.** Native Tk capture using `examples/lookup-template.csv`, labeled `DEMO_ONLY`. The curves and sizing estimate are illustrative synthetic data, not a characterized PDK.

Load measured CSV lookup data. It groups by PDK, model, corner, temperature, Vds, Vsb, and total reference width. Within that fixed slice, each channel length is a separate curve. You can plot intrinsic gain, estimated fT, or current density against gm/Id. When a matching model is selected in the inspector, its actual gain/fT operating point can appear as a dot; verify the circuit's corner, temperature and bias yourself.

Required columns:

| Column | Meaning |
|---|---|
| `pdk`, `model`, `corner` | Explicit process and device provenance |
| `temp_c` | Temperature in degrees Celsius |
| `vds_v`, `vsb_v` | Device bias in volts, using your table's declared sign convention |
| `length_um` | Channel length in micrometers |
| `total_width_um` | Total reference width, including parallel multiplicity |
| `id_a`, `gm_s`, `gds_s` | Saved current and small-signal parameters in SI units |
| `cgg_total_f` | Optional total gate capacitance in farads, including relevant overlaps |

The file in `examples/lookup-template.csv` is **illustrative synthetic data**, explicitly labeled `DEMO_ONLY`. It is a format example, not a characterized PDK or a valid sizing database. Replace it with your characterization data.

Enable **Sizing estimate** to reveal the sizing form. Sizing interpolates current density within a selected curve, computes `Id = gm / (gm/Id)`, then estimates total width from `Id / current_density`. Extrapolation, duplicate gm/Id samples, and unordered/multiple branches are rejected. Supply each curve in monotonic sweep order. Editing an input clears the previous estimate; invalid entries explain the problem next to the form. Linear width scaling is an estimate; map the result to the PDK's width/finger/multiplier convention and resimulate. Sizing does not automatically modify the schematic. There is no automatic PDK characterization in this version.

### Import existing MAT lookup data

An optional converter accepts flat or structured Murmann/pygmid-style `.mat` files with `L`, `VGS`, `VDS`, `VSB`, `ID`, `GM`, and `GDS` arrays in **L, VGS, VDS, VSB** order:

```sh
python3 tools/convert_mat.py nch.mat nch.csv \
  --variable nch --pdk sky130A --model nfet_01v8 \
  --corner tt --temp-c 27 --total-width-um 10 --length-unit um
```

Omit `--variable` for flat MAT fields. Add `--cgg-is-total` only if `CGG` already includes the relevant overlap capacitances. The converter requires NumPy/SciPy; the extension itself does not. MAT v7.3/HDF5 and pickle files are not supported.

## Interpretation

- gm/Id and intrinsic gain are positive magnitudes; current and terminal voltages retain simulator signs.
- Headroom is `abs(Vds) - abs(model Vdsat)` (PSP `vdss`). It is a model-based bias check, not a universal saturation test.
- IHP PSP effective Cgg is `cgg + cgsol + cgdol`. fT stays unavailable if either overlap value is missing. BSIM uses saved instance `cgg` directly.
- `gm/(2πCgg)` is an approximate device fT; it is not measured circuit bandwidth.
- gm/gds is intrinsic transistor gain; it is not loaded stage or loop gain.
- gm/Id target limits are editable design checks, not universal weak/moderate/strong inversion boundaries.
- AC gain, stability, noise, transient settling, Monte Carlo, automatic sizing optimization, and automated characterization are not implemented in this release.

## Tests

```sh
python3 -m unittest discover -s tests -v
```

These tests execute the real Tcl numerical/adapter logic through Python's Tcl interpreter, with fixture xschem commands for integration contracts. They do not substitute for PDK simulation validation.

The native GUI interaction tests skip without an X11 display. To run the complete suite, including keyboard input, sorting, validation, minimum-size layout, and dark-theme checks:

```sh
xvfb-run -a -s '-screen 0 1440x1000x24' python3 -m unittest discover -s tests -v
```

For the real native Tk widget/event smoke test in an IIC environment with `wish` and `xvfb-run`:

```sh
xvfb-run -a wish tests/gui_smoke.tcl
```

For installed-PDK ngspice checks, use `python3 tools/check_iic.py --output ./iic-checks`. This writes small test decks and a report and fails if an installed supported PDK fails. It also reports unavailable PDKs explicitly.

## Remove

Remove the `BEGIN ANALOG LENS` / `END ANALOG LENS` block from the same `xschemrc`, restart xschem, then delete the installed extension folder if desired. Keep source model configurations and schematics intact.

MIT license. This extension is independent of xschem, IIC-OSIC-TOOLS, and the PDK maintainers.
