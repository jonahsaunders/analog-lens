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

## Validated in IIC-OSIC-TOOLS 2026.08

The [passing integration run](https://github.com/jonahsaunders/analog-lens/actions/runs/35762801866) exercised installed vendor models and symbols:

| PDK | NMOS / PMOS model pair | Tested behavior |
|---|---|---|
| SKY130A | `nfet_01v8` / `pfet_01v8` | Real OP metrics and two-length characterization for both polarities; complete NMOS GUI workflow |
| GF180MCU-D | `nfet_03v3` / `pfet_03v3` | Same |
| IHP SG13G2 | `sg13_lv_nmos` / `sg13_lv_pmos` | Same, including PSP/OSDI and overlap capacitances |
| IHP SG13CMOS5L | `sg13_lv_nmos` / `sg13_lv_pmos` | Same, including PSP/OSDI and overlap capacitances |

All 24 direct simulations and four live xschem integrations passed. The direct checks cover NMOS/PMOS metrics and two-finger devices with one/two copies. GUI checks include hierarchy, cross-probing, highlighting, annotation placement, sidebar, native simulations, freshness, cursor tracking, sizing Apply/Undo and measured target verification, archived results, characterization, 27/85 °C batches with cache reuse, and project restoration. The v0.6 run also exercised the unified sizing workspace, condition reuse, installed corner choices, optional setup, unit inputs and visual target verification. Sixteen exported reports were compared with raw data, including post-sizing measurements. The container also passed all 118 automated tests without skips. See [VALIDATION.md](VALIDATION.md) for the image digest, numerical tolerances, source commit, and retained evidence.

Fixture and native tests additionally cover numerical guards, adapter naming, ambiguous wrappers, CSV/LUT validation, sizing math, hierarchy recovery, installer preservation, keyboard/layout behavior, comparisons, sessions, provenance, and Linux cancellation. These checks complement the real PDK simulations.

Geometry changes and characterization use the model pairs above. Sizing previews preserve literal finger/copy counts by default and accept explicit counts using each PDK's W/L and multiplicity conventions. Supported geometry guards and rounding are documented in the v0.5 guide. Parameterized dimensions, arrays and other models are refused. The [integrated workflow guide](docs/INTEGRATION_V05.md) describes voltage/corner limits and geometry handling.

## Coverage boundaries

The real tests use nominal MOS corners and the model pairs above. Batch checks additionally cover 27/85 °C at Vds 0.7 V and Vsb 0 V. Other voltage options, corners, temperatures, bias combinations, device geometries, BJT/RF/composite families, and other container/PDK revisions need validation before relying on them. Bipolar support currently has adapter/fixture coverage, not the real-device qualification above. PMOS metrics are tested in ngspice; the automated xschem placement/hierarchy testbench uses NMOS.

Check your own design in the IIC VNC/X11 desktop and compare its particular model variants against ngspice output and the PDK's annotations. Automated GUI checks cannot establish usability for every project, theme, or screen setup.

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

## Automated IIC validation (v0.6)

Run `xvfb-run -a python3 tools/validate_iic.py --require-all` inside IIC-OSIC-TOOLS, or `bash tools/run_iic_container.sh` from a Docker host. The harness uses installed vendor symbols/models, checks NMOS and PMOS metrics, and exercises actual xschem hierarchy, highlighting, cross-probing and annotation workflows. It saves logs and raw results and fails if any required PDK is absent or fails.

See the [validation record](VALIDATION.md) and [integration workflow](https://github.com/jonahsaunders/analog-lens/actions/workflows/iic.yml) for the tested environment and results. Results apply to the exact image and device coverage recorded there.
