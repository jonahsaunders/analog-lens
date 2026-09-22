# Integrated IIC workflow

Analog Lens 0.4 runs inside xschem's Tcl/Tk process in IIC-OSIC-TOOLS. Its sidebar, project memory, normal simulator integration, waveform cursor tracking, sizing changes, and PDK characterization share the current testbench context.

## Inspector sidebar

The sidebar opens beside the schematic when the extension loads. Select one scalar transistor to see current, gm/Id, gm, intrinsic gain, model headroom and estimated fT. It also works before simulation: geometry/model actions are available and missing measurements remain `—`.

**Hide** collapses the sidebar. **Analog Lens → Show inspector sidebar** opens it again. **Analysis…** opens the larger four-tab window for tables, plots and comparisons. Closing that window leaves the sidebar and ongoing simulations available. Host keyboard shortcuts and the host ttk theme are preserved.

The panel is attached to the drawing's existing Tk pack layout. This integration is validated against the IIC image listed in [VALIDATION.md](../VALIDATION.md); an unsupported host layout reports the problem and retains the analysis-window option.

## Normal xschem simulations

Use xschem's **Netlist** and **Simulate** controls normally, or choose **Run testbench** in the sidebar to netlist and simulate together. Analog Lens observes `simulate` and completion of the corresponding xschem process. It preserves the caller's callback and simulator configuration.

For a configured ngspice command, **Add device saves** inserts one marked block of `.save` directives into the generated SPICE deck. It does not change the source schematic, its `.control` block, models, sources or analysis commands. Repeated preparation replaces that block rather than duplicating it. A `.control` block that uses its own `save` commands may override saved vectors; missing vectors remain visible as missing. Disable automatic saves for custom netlisting flows.

The testbench must write a raw file, for example:

```spice
.control
set filetype=ascii
op
write my_testbench.raw
quit
.endc
```

After successful process completion, the extension looks for changed `.raw` files in the netlist directory. It prefers the testbench's standard raw filename, otherwise accepts one unique changed file. It will not silently choose among several files or reload an unchanged old file after a failed run.

**Project settings…** lets you specify an exact result path (relative to the netlist directory or absolute) and choose **auto**, **op**, **dc**, or **tran**. Auto recognizes the first plot header; choose a specific analysis for a raw file containing multiple plots. Unsupported AC/complex plots are not used for device operating-point metrics.

Results from a background run attach only at its original top-level testbench and xschem window. If you switch away, return to that testbench to attach them. xschem owns its normal simulation processes: use its **Simulate** control/process tools to stop them. Analog Lens's separate **Operating point** and **Cancel** buttons retain their isolated-run behavior.

## Project memory and freshness

Each saved top-level testbench has its own session under:

```text
<project>/.analog-lens/sessions/<testbench>-<path-id>.alsession
```

The project directory is the nearest parent containing `xschemrc`, or the testbench directory if none is found. Descending into a subcircuit keeps the top-level project identity. Switching testbenches restores their own targets, named baselines, lookup selection, sizing inputs, sorting, layout and integration preferences.

State is saved atomically after changes, approximately every two seconds, on project switches, and on normal shutdown. **Save session…** remains available for an explicit portable snapshot. A corrupt or mismatched automatic session is preserved; the sidebar reports that it needs attention. A read-only project keeps state in memory and reports the save problem. Unsaved testbenches do not create project files. Moving the project to another path requires opening its old session explicitly.

The source-state indicator distinguishes recorded current results, results made stale by schematic edits, and imports whose source state is unverified. xschem edit notifications cover changes within the current testbench hierarchy, including sizing and Undo. A run retains its starting state, so edits made while it runs do not make its results appear current. External changes to included model files are not comprehensively watched: rerun after changing external dependencies.

## Waveform cursor B

Enable **Follow waveform cursor B** in Project settings. For DC and transient results, moving cursor B updates Sample and the device metrics to the nearest saved point. The label shows the selected sample and sweep value; this is not interpolated data.

The last selected graph's local cursor and explicit dataset are used when available; otherwise the global cursor and current Dataset are used. A graph using another raw file or a custom sweep axis reports that it cannot be followed. The supported axes are the monotonic primary time/DC sweep. Use manual Sample/Dataset selection for other graph configurations.

## Sizing preview, Apply and Undo

1. Select a supported MOS in the schematic.
2. Choose **Size selected…**, load or generate compatible measured lookup data, and choose a characterized length, gm/Id and target gm.
3. Click **Preview schematic changes…**. The preview lists each old/new property and the lookup conditions.
4. Choose **Apply**, or **Apply & run OP** at the top level.

Geometry changes use the verified symbol conventions: micron-valued `W/L` for SKY130, meter-suffixed `W/L` for GF180, and `w/l` for IHP. This implementation normalizes the proposed geometry to **one finger and one parallel copy**, setting the corresponding `nf/ng/mult/m` properties to 1. It does not infer a multifinger layout strategy. The preview makes that normalization explicit.

Device discovery uses xschem's hierarchy navigation. If a hierarchical testbench has unsaved edits, xschem may ask you to save before descending, including when preparing device saves or choosing **Apply & run OP**. **Apply** alone does not traverse or save. Save the parent when prompted to retain its edits during hierarchy navigation.

All property edits form **one xschem Undo** operation. The extension does not save the schematic automatically. At a subcircuit level, apply and save your edits, then return to the top-level testbench to rerun. A named pre-edit baseline is kept when device results are available.

Application is refused if the selected instance, its properties, target inputs or lookup file changed since preview. Unsupported models, array elements, parameterized dimensions, different PDK/model conditions, known measured bias mismatches and the `DEMO_ONLY` lookup are not applied. Measured voltage matching allows 10 ppm or 1 µV for xschem's transport precision. Unknown corner/temperature/body-bias conditions still need verification.

Width scaling remains an estimate. Existing parasitic formulas are retained, and fixed parasitic values require review after changing geometry. Resimulate and inspect the baseline comparison before accepting the result.

## Generate measured lookup curves

Select a transistor and choose **Characterize…**. The form specifies lengths, total reference width, installed library corner section, temperature, signed Vds, Vsb (`Vs − Vb`), and a gate-voltage magnitude sweep. PMOS gate polarity is applied automatically; its Vds must be negative.

The generator runs real ngspice sweeps using the installed PDK's model includes and initialization/OSDI setup. Current, gm, gds and gate capacitance are read from the simulator; IHP overlap capacitances are included. One finger and one parallel copy establish the CSV's reference-width convention.

Supported profiles:

| PDK | Models | Default corner | Maximum sweep magnitude |
|---|---|---|---|
| `sky130A` | `nfet_01v8`, `pfet_01v8` | `tt` | 1.8 V |
| `gf180mcuD` | `nfet_03v3`, `pfet_03v3` | `typical` | 3.3 V |
| `ihp-sg13g2` | `sg13_lv_nmos`, `sg13_lv_pmos` | `mos_tt` | 1.2 V |
| `ihp-sg13cmos5l` | `sg13_lv_nmos`, `sg13_lv_pmos` | `mos_tt` | 1.2 V |

The nominal profiles are validated; other installed corner sections require checking against the actual PDK revision. The generator bounds sweep sizes and dimensions, rejects nonfinite parameters, and never modifies installed PDK files.

Completed CSVs, JSON provenance, generated decks, simulator raw data and logs stay under `.analog-lens/lookups/`. Publication occurs only after every requested length succeeds. **Cancel run** stops the generator and its ngspice child while keeping the previously loaded lookup data. If you switch projects during a run, the completed file is reported without replacing the other project's lookup.

The explorer automatically selects a unique compatible model/condition slice. Multiple compatible slices require an explicit choice. A nonmonotonic gm/Id curve is retained for plotting with a warning; sizing requires a narrower monotonic sweep. Small or nonpositive conductances and currents at/below 1 pA are excluded.

The same generator can run from the IIC terminal:

```sh
python3 tools/characterize.py --pdk sky130A --model nfet_01v8 \
  --lengths 0.5 1.0 --width 10 --corner tt --temp 27 \
  --vds 0.9 --vsb 0 --vgs-start 0.2 --vgs-stop 1.8 --vgs-step 0.025 \
  --output /foss/designs/my_project/lookups/nfet.csv
```

Existing output paths are never overwritten. No third-party model files are distributed with the lookup output.
