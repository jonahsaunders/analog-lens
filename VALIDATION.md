# Validation record

Version: 0.2.0
Date: 2026-09-22

51 automated tests pass using Python 3.12 and Tcl/Tk 8.6.14 on Linux with Xvfb. This includes 38 engine/installer/contract tests and 13 native GUI tests. The native Tk widget/event smoke test also passes. The 38 original headless tests also pass with Tcl 9.0.4.

Validated: numerical calculations, PMOS polarity, missing-data and low-current guards, PDK family/path fixtures for SKY130/GF180/IHP SG13G2/IHP SG13CMOS5L, unambiguous wrapper matching, CSV handling, LUT metadata/interpolation/sizing, hierarchy error recovery, installer idempotence, async subprocess/fileevents with a simulator fixture, and GUI Tcl command flow with mocked widgets.

Native GUI validation covers keyboard events, sorting, filter recovery, inline form validation, sizing invalidation, comparison states, lookup copying, busy controls, live logs, reopening, minimum-size layouts, larger fonts, and a representative dark host theme. Screenshots were visually reviewed for all four tabs and both custom dialogs. See [the GUI audit](docs/GUI_AUDIT.md) for the detailed record and remaining checks.

Not validated here: actual xschem runtime, actual ngspice model behavior, real PDK simulations, macOS Aqua/VoiceOver, Windows, or localization. The environment lacks xschem, ngspice and PDK installations. The package includes tests/gui_smoke.tcl and tools/check_iic.py for further checks in IIC-OSIC-TOOLS. Native tests skip when DISPLAY is absent; a headless-only test run is not equivalent to the full GUI suite.

No fabricated simulation results or PDK lookup tables are included. The lookup-template.csv values are synthetic format examples labeled DEMO_ONLY.
