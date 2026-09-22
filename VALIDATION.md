# Validation record

Version: 0.6.1 · Target: IIC-OSIC-TOOLS, Linux/X11 · Date: 2026-09-22

## Native verification

**125 tests pass** with Python 3.12 and Tcl/Tk 8.6.14 on Linux under Xvfb, without skips. The native Tk widget/event smoke test also passes. [Native CI run 35767855567](https://github.com/jonahsaunders/analog-lens/actions/runs/35767855567) verifies the same source commit as the container run below.

Coverage includes numerical calculations, PMOS polarity, missing-data/current guards, SKY130/GF180/IHP adapters, CSV/LUT validation, interpolation, installer preservation, keyboard navigation, sorting, filters, chart inspection, sessions, project switching and Linux subprocess cancellation.

The v0.5 checks add netlist hierarchy discovery with 5,000 instances, repeated hierarchy and recursion handling, literal imported data, selected library sections, same-size model changes, dependency deletion, observed versus declared conditions, finger/copy geometry limits, sizing-preview invalidation, target Pass/Miss/Incomplete states, revision guards, archived raw-file copies, result filters, batch requests and cache invalidation. Regression cases cover host redraw notifications and same-size raw-file overwrites within one timestamp interval.

```sh
xvfb-run -a -s '-screen 0 1440x1000x24' python3 tools/run_tests.py --require-gui
xvfb-run -a wish tests/gui_smoke.tcl
```

The required runner rejects missing displays and skipped tests. A headless unittest run remains useful for numerical/contract work but does not provide full GUI validation.

The v0.6 checks additionally cover dimension-aware units, canonical session storage, body-bias sign conversion, unknown/stale conditions, unique versus ambiguous saved lookup matches, measured bias precedence, optional setup without simulation, inline recovery, unified preview/Undo, numeric verification charts and small-window keyboard scrolling.

The v0.6.1 [GUI audit](docs/GUI_AUDIT_061.md) adds seven regression tests for compact dialogs and tabs, keyboard focus/scrolling, field errors, batch progress and input locks, log reading position, result selection, verification disclosure and host-surface contrast. The original layout checks also exercise keyboard access through scrolling tabs at 14-point system text.

## Real IIC integration

Validated with **IIC-OSIC-TOOLS 2026.08** in [integration run 35767855614](https://github.com/jonahsaunders/analog-lens/actions/runs/35767855614), using code commit [`7be2893`](https://github.com/jonahsaunders/analog-lens/commit/7be289359dfd51ab7c8a2aa5735bce77d98d4ac9).

- Container: `hpretl/iic-osic-tools:2026.08`, Linux/amd64.
- Tools: xschem 3.4.8RC, ngspice 47, Tcl/Tk 8.6.14.
- Resolved digest: `sha256:3c371645b19c6f6564dc8c7b21e39ad1c1833d274fe5b85639afe1ba9d7987e7`.
- 125 native/contract tests passed in the container, without skips.
- 24 direct model simulations passed: eight NMOS/PMOS metric checks plus sixteen two-finger simulations with one or two parallel copies. Doubling copies doubled measured current and gm within the checked tolerance.
- Eight NMOS/PMOS characterization jobs passed at two lengths each.
- Four real xschem GUI workflows passed, including hierarchy, cross-probing, highlighting, annotation placement, sidebar, native simulation/callback, cursor tracking, sizing/Undo and project restoration.
- Each GUI workflow applied two fingers and two copies, checked the installed symbol's emitted netlist, reran the native testbench and produced measured sizing target errors.
- Sixteen exported reports—top-level, child, native and post-sizing results for each PDK—were compared with their own raw simulator files.
- Each GUI workflow generated a seven-sample lookup, then ran a 27/85 °C batch and repeated it with both conditions reused from verified cache. Combined batches contain fourteen measured samples each.
- The project results browser retained independent raw archives and named baselines.
- Every PDK also exercised the new Size & verify tab, a target entered in mS, device-condition reuse, a unique matching lookup, actual installed corner sections, optional setup without an accidental run, and two visual tolerance bands.

| Installed PDK | Tested NMOS / PMOS | Direct simulations | xschem, sizing and batches |
|---|---|---|---|
| `sky130A` | `nfet_01v8` / `pfet_01v8` | Passed | Passed |
| `gf180mcuD` | `nfet_03v3` / `pfet_03v3` | Passed | Passed |
| `ihp-sg13g2` | `sg13_lv_nmos` / `sg13_lv_pmos` | Passed | Passed |
| `ihp-sg13cmos5l` | `sg13_lv_nmos` / `sg13_lv_pmos` | Passed | Passed |

The [machine-readable v0.6.1 summary](docs/validation/iic-2026.08-v0.6.1.json) records versions, measured errors, deck hashes, geometry checks, verification verdicts and batch reuse. The workflow artifact retains generated schematics/decks, raw files, exports, dependency manifests, screenshots and logs. PDK model files are not redistributed. The [v0.6 summary](docs/validation/iic-2026.08-v0.6.json), [v0.5 summary](docs/validation/iic-2026.08-v0.5.json) and [v0.4 summary](docs/validation/iic-2026.08-v0.4.json) remain available as historical evidence.

A passing integration test means the workflow measured and reported the target error correctly. It does **not** mean a width-only sizing estimate met gm and gm/Id targets in the circuit: the live testbench keeps its fixed gate bias, and a legitimate **Miss** is expected for some requests. The verification capture shows that distinction.

The direct metric tolerance is `1e-9` relative. Multiplier and xschem export checks use `1e-6` relative, without an absolute tolerance. xschem's ASCII reader and eight-significant-digit numeric API introduce small conversion errors. The largest measured relative export error was `1.8342e-7` (0.184 ppm); the JSON summary records every comparison. See upstream [ASCII reader](https://github.com/StefanSchippers/xschem/blob/ddc734480d5326fb787993dad24f4062e5d28434/src/save.c) and [number conversion](https://github.com/StefanSchippers/xschem/blob/ddc734480d5326fb787993dad24f4062e5d28434/src/editprop.c).

Live validation caught three relevant host behaviors: redraw notifications can advance the source revision, fast raw overwrites can share size/timestamp, and xschem caches plots by filename/type. Verification now snapshots the completed edit, includes a raw-content fingerprint and explicitly reloads overwritten plots. Post-sizing exports are checked against raw data to detect stale in-memory measurements. The v0.6 regression checks also preserve valid previews across selection polling, retain full target precision before geometry rounding, and detect identical rapid reruns using nanosecond file timestamps.

### Reproduce

Run `bash tools/run_iic_container.sh` on a Docker host, or run inside IIC:

```sh
xvfb-run -a -s '-screen 0 1440x1000x24' python3 tools/validate_iic.py --require-all
```

`--require-all` treats missing PDKs as failure. `tools/check_iic.py` provides standalone NMOS/PMOS and multiplier checks; `tests/iic_live.tcl` drives actual xschem. The native [GUI workflow](https://github.com/jonahsaunders/analog-lens/actions/workflows/tests.yml) also checks the Tk smoke test and captures the interface.

## Scope and limitations

The full GUI testbench uses NMOS; PMOS has real metric, multiplier and characterization coverage. The batch GUI checks nominal corners, temperatures 27/85 °C, Vds 0.7 V and Vsb 0 V. General corner/bias grids are implemented, but every possible combination and device family has not been validated. [PDK_SUPPORT.md](PDK_SUPPORT.md) defines model coverage.

Automatic sizing reruns start at the top-level testbench. Nested edits use the normal save/return workflow. Target verification covers gm and gm/Id, not circuit-level gain, stability, noise, settling or layout qualification. Dynamic simulator scripts outside the discovered dependency graph remain unverified. Run archives have no automatic deletion policy.

Native macOS/Aqua/VoiceOver and native Windows support are outside the target scope. IIC runs Linux/X11 even when its container is hosted on another operating system. Automated interaction checks do not replace a manual VNC/X11 usability check in the user's project.

The `iic-*.png` images show actual container workflows; other captures use explicitly labeled synthetic fixtures. [Screenshot provenance](docs/images/README.md) identifies each source.
