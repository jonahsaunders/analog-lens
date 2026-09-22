# Validation record

Version: 0.4.0 · Target: IIC-OSIC-TOOLS, Linux/X11 · Date: 2026-09-22

## Local verification

**85 tests pass** with Python 3.12 and Tcl/Tk 8.6.14 on Linux under Xvfb, with no skips. The native Tk widget/event smoke test also passes.

Coverage includes numerical calculations, PMOS polarity, missing-data/current guards, SKY130/GF180/IHP adapter fixtures, unambiguous wrapper matching, CSV handling, LUT interpolation/sizing, hierarchy error recovery, installer idempotence, and asynchronous process handling.

Native GUI checks cover keyboard navigation, sorting, filters, validation, comparison, clipboard output, lookup filters, sample inspection, zoom, SVG export, session restoration, diagnostics, small windows, larger fonts, and a dark host theme. Session tests check malformed-file rejection, literal imported text, duplicate baseline names, provenance, and added/removed devices.

New integration checks cover project switching and corrupt-session preservation, host callback retention, generated-deck provenance, terminal-bias matching, cursor sample selection, guarded sizing and Undo, braced host selection lists, and characterization completion with project autosave.

The cancellation test starts a real Linux subprocess that ignores SIGTERM. It verifies escalation, unchanged loaded results, and survival of an unrelated subprocess. This validates the Linux process lifecycle; it is separate from PDK simulation testing.

```sh
xvfb-run -a -s '-screen 0 1440x1000x24' python3 tools/run_tests.py --require-gui
xvfb-run -a wish tests/gui_smoke.tcl
```

The required runner rejects missing displays and skipped tests. An ordinary headless unittest run remains available for numerical/contract work and is not equivalent to full GUI validation.

## Real IIC integration

Validated with **IIC-OSIC-TOOLS 2026.08** in the [passing integration run](https://github.com/jonahsaunders/analog-lens/actions/runs/35738760853), using code commit [`e01f9d7`](https://github.com/jonahsaunders/analog-lens/commit/e01f9d7f18acf3fdf7f6948c65f066066d0009b0).

- Container: `hpretl/iic-osic-tools:2026.08`, Linux/amd64.
- Tools: xschem 3.4.8RC, ngspice 47, Tcl/Tk 8.6.14.
- Resolved digest: `sha256:3c371645b19c6f6564dc8c7b21e39ad1c1833d274fe5b85639afe1ba9d7987e7`.
- 85 native/contract tests passed in the container, without skips.
- Eight real NMOS/PMOS simulations passed; extension calculations agree with independently derived raw-data metrics.
- Eight NMOS/PMOS characterization jobs passed at two lengths each; measured currents and small-signal parameters come from ngspice.
- Four real xschem GUI integrations passed: hierarchy, cross-probing, highlighting, annotation placement, embedded sidebar, native simulation/callback, cursor tracking, sizing/Undo, characterization, and project-session restoration.
- Each GUI run also generated and automatically loaded a real seven-sample NMOS lookup.
- All twelve top-level/child/native exports passed comparison with their own raw simulator files.

| Installed PDK | Tested NMOS / PMOS | Real simulation | xschem workflow |
|---|---|---|---|
| `sky130A` | `nfet_01v8` / `pfet_01v8` | Passed | Passed |
| `gf180mcuD` | `nfet_03v3` / `pfet_03v3` | Passed | Passed |
| `ihp-sg13g2` | `sg13_lv_nmos` / `sg13_lv_pmos` | Passed | Passed |
| `ihp-sg13cmos5l` | `sg13_lv_nmos` / `sg13_lv_pmos` | Passed | Passed |

The persistent [machine-readable validation summary](docs/validation/iic-2026.08-v0.4.json) records versions, measured errors, deck hashes, and results. The workflow artifact retains generated schematics/decks, raw files, exports, and full logs. PDK files are not redistributed.

The direct calculation check uses a relative tolerance of `1e-9`. The xschem export check uses `1e-6` (one part per million), with no absolute tolerance: its ASCII reader uses floating-point `my_atof()`, and its `raw value` API returns eight significant digits through `dtoa()`. Ratios accumulate those conversion errors. The largest measured relative error was `1.84e-7` (0.184 ppm). See upstream [ASCII reader](https://github.com/StefanSchippers/xschem/blob/ddc734480d5326fb787993dad24f4062e5d28434/src/save.c) and [number conversion](https://github.com/StefanSchippers/xschem/blob/ddc734480d5326fb787993dad24f4062e5d28434/src/editprop.c). A v0.3 archived-run regression check accepted all eight actual exports and rejected all eight after a deliberately introduced 10 ppm gm error.

The earlier v0.3 integration run exposed and fixed an ngspice 47 filename issue: `write` treats double quotes as part of its output filename. Generated analysis files now use a safe unquoted basename in the simulation directory; paths containing spaces are covered by the asynchronous-run regression test.

The v0.4 live run additionally caught startup geometry, host selection-list serialization, and characterization-completion issues. Regression checks cover each fix. Lookup bias matching uses measured schematic terminals; model-internal Vds can differ because of series resistance. Native freshness records deck-generation state, so Simulate alone cannot validate a stale deck.

### Reproduce

Run `bash tools/run_iic_container.sh` on a Docker host, or run this inside the IIC environment:

```sh
xvfb-run -a -s '-screen 0 1440x1000x24' python3 tools/validate_iic.py --require-all
```

`--require-all` treats missing PDKs as failure. `tools/check_iic.py` provides the standalone NMOS/PMOS checks, and `tests/iic_live.tcl` drives the actual xschem workflows. Reports are generated for each run. The native [GUI workflow](https://github.com/jonahsaunders/analog-lens/actions/workflows/tests.yml) also checks the Tk smoke test and captures the interface.

## Scope and limitations

Native macOS/Aqua/VoiceOver and native Windows support are outside the target scope. IIC runs Linux/X11 even when its container is hosted on another operating system.

The three `iic-*.png` screenshots show the real passing container workflow; the remaining captures use explicitly labeled synthetic fixtures. [Screenshot provenance](docs/images/README.md) identifies each source. No synthetic values are presented as PDK measurements. Automated xschem interaction tests do not replace a manual VNC/X11 usability check in the user's own project. PDK device-family/model coverage remains bounded by [PDK_SUPPORT.md](PDK_SUPPORT.md).
