# Validation record

Version: 0.3.0 · Target: IIC-OSIC-TOOLS, Linux/X11 · Date: 2026-09-22

## Local verification

**65 tests pass** with Python 3.12 and Tcl/Tk 8.6.14 on Linux under Xvfb, with no skips. The native Tk widget/event smoke test also passes.

Coverage includes numerical calculations, PMOS polarity, missing-data/current guards, SKY130/GF180/IHP adapter fixtures, unambiguous wrapper matching, CSV handling, LUT interpolation/sizing, hierarchy error recovery, installer idempotence, and asynchronous process handling.

Native GUI checks cover keyboard navigation, sorting, filters, validation, comparison, clipboard output, lookup filters, sample inspection, zoom, SVG export, session restoration, diagnostics, small windows, larger fonts, and a dark host theme. Session tests check malformed-file rejection, literal imported text, duplicate baseline names, provenance, and added/removed devices.

The cancellation test starts a real Linux subprocess that ignores SIGTERM. It verifies escalation, unchanged loaded results, and survival of an unrelated subprocess. This validates the Linux process lifecycle; it is separate from PDK simulation testing.

```sh
xvfb-run -a -s '-screen 0 1440x1000x24' python3 tools/run_tests.py --require-gui
xvfb-run -a wish tests/gui_smoke.tcl
```

The required runner rejects missing displays and skipped tests. An ordinary headless unittest run remains available for numerical/contract work and is not equivalent to full GUI validation.

## Real IIC integration

The development workspace has no Docker/Podman, xschem, ngspice, or installed PDKs. Its attempted integration run correctly reports missing prerequisites; no local PDK success is claimed.

The repository now provides an executable integration harness and a GitHub Actions job:

- [IIC integration runs](https://github.com/jonahsaunders/analog-lens/actions/workflows/iic.yml)
- `tools/validate_iic.py`: native tests, real PDK simulations, and real xschem GUI workflows.
- `tools/check_iic.py`: NMOS/PMOS checks for SKY130A, GF180MCU-D, SG13G2, and SG13CMOS5L; extension metrics are compared with independently computed simulator values.
- `tests/iic_live.tcl`: top-level/hierarchical runs, raw-result loading, cross-probing, highlighting, annotation placement, and saving a session inside xschem.
- `tools/run_iic_container.sh`: runs the harness in a tagged IIC image and records its resolved image information.

Each run saves generated schematics/decks, raw files, exports, logs, and JSON results. `--require-all` treats missing PDKs as failure. **A workflow definition is not evidence of a passing integration run; use its artifact report for the actual outcome and tested image.**

## Scope and limitations

Native macOS/Aqua/VoiceOver and native Windows support are outside the target scope. IIC runs Linux/X11 even when its container is hosted on another operating system.

Screenshots use synthetic fixtures and the clearly marked DEMO_ONLY lookup file. No fabricated PDK measurements are included. Automated xschem interaction tests do not replace a manual VNC/X11 usability check in the user's own project. PDK device-family/model coverage remains bounded by [PDK_SUPPORT.md](PDK_SUPPORT.md).
