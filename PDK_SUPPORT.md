# PDK support and verification

Target inventory checked against the IIC-OSIC-TOOLS README and installation scripts on 2026-09-21. The documented installed PDKs are `sky130A`, `gf180mcuD`, `ihp-sg13g2`, and `ihp-sg13cmos5l`. Current installation scripts remove SKY130B and GF180 A/B/C to reduce image size; the extension recognizes their family naming if separately installed.

| PDK | MOS primitive convention | Current / saturation | Capacitance handling |
|---|---|---|---|
| SKY130A | `@m.<hierarchy>x<instance>.msky130_fd_pr__<model>`; `__base` fallback for already-saved data | `id`, `vdsat` | instance `cgg` |
| GF180MCU-D | `@m.<hierarchy>x<instance>.m0` | `id`, `vdsat` | instance `cgg` |
| IHP SG13G2 | `@n.<hierarchy>x<instance>.n<model>` | `ids`, `vdss` | `cgg + cgsol + cgdol` |
| IHP SG13CMOS5L | same PSP/OSDI convention as SG13G2 | `ids`, `vdss` | `cgg + cgsol + cgdol` |

The extension detects a PDK family from the symbol/model first, then falls back to `$PDK`. It uses native ngspice variable names and handles `i(...)` and `v(...)` wrappers. It discovers a deeper internal primitive only when exactly one gm-bearing primitive belongs to the exact wrapper; it does not match `M1` to `M10` or combine values from unrelated devices.

Bipolar adapters additionally recognize SKY130 `qsky130_fd_pr__<model>`, GF180 `q0`, and IHP vertical NPN `q<model>` wrappers. They report Ic, Ib, gm, go, DC beta and terminal voltages when saved. IHP CMOS5L PNP/other composite bipolar models are not covered by this initial adapter. Passive devices, RF composite models, and device-specific extra parameters are outside the first version's inspector.

Support means the MOS adapter and GUI workflow are implemented. **It does not mean every voltage option, device family, container tag, or installed PDK revision has been validated.** Model names and nested wrappers can change. Missing vectors remain visible as missing, with diagnostics, instead of fabricated results.

## Validation performed during development

- Tcl source loading and numerical calculations.
- Fixture-based path resolution for all four PDK targets and compatibility aliases.
- PMOS polarity, low-current guards, zero/nonpositive conductance, missing values, and IHP overlap handling.
- CSV import/export, unit/metadata checks, interpolation boundaries, and sizing math.
- xschem API contract fixtures, selection restoration, and hierarchy restoration after failure.
- Installer preservation and idempotence checks.
- A real asynchronous subprocess/fileevent check using a fake simulator executable and xschem API fixture (not a real ngspice run).
- Native GUI Tcl procedures exercised against mock widget commands; this verifies command flow, not rendering or actual Tk option behavior.

## Validation still required in IIC-OSIC-TOOLS

- Run `tools/check_iic.py` against the actual installed model versions.
- Run `tests/gui_smoke.tcl` with real Tk/X11, then inspect the window in xschem.
- Exercise the extension on a real top-level testbench for each PDK, including hierarchy and saved parameter names.
- Verify the particular device variants used in your design, and compare against ngspice output and existing PDK annotations.

The build environment did not contain xschem, ngspice, an X server, or the installed PDKs. Integration and visual validation are therefore explicitly unverified.

## Primary references

- IIC-OSIC-TOOLS inventory: https://github.com/iic-jku/IIC-OSIC-TOOLS#2-installed-pdks
- SKY130/GF180 installation and patch conventions: https://github.com/iic-jku/IIC-OSIC-TOOLS/blob/main/_build/images/open_pdks/scripts/install_ciel.sh
- IHP CMOS5L installation: https://github.com/iic-jku/IIC-OSIC-TOOLS/blob/main/_build/images/open_pdks/scripts/install_ihp_cmos5l.sh
- xschem Tcl API: https://xschem.sourceforge.io/stefan/xschem_man/developer_info.html
- IHP parameter save/display conventions: https://github.com/IHP-GmbH/IHP-Open-PDK/blob/main/ihp-sg13g2/libs.tech/xschem/xschem-menu
- IHP CMOS5L parameter conventions: https://github.com/iic-jku/ihp-sg13cmos5l/blob/main/libs.tech/xschem/xschem-menu
- GF180 parameter conventions: https://github.com/fossi-foundation/globalfoundries-pdk-libs-gf180mcu_fd_pr/blob/main/cells/xschem/xschem-menu
- SKY130 symbol conventions: https://github.com/StefanSchippers/xschem_sky130/blob/main/sky130_fd_pr/nfet_01v8.sym

No foundry models, PDK files, proprietary data, or third-party lookup tables are distributed with this extension.
