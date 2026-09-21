# Validation record

Version: 0.1.0
Date: 2026-09-21

38 automated tests pass using Python 3.12 and Tcl 9.0.4. The extension uses Tcl 8.6-compatible syntax; a Tcl 8.6 runtime was not available for execution here.

Validated: numerical calculations, PMOS polarity, missing-data and low-current guards, PDK family/path fixtures for SKY130/GF180/IHP SG13G2/IHP SG13CMOS5L, unambiguous wrapper matching, CSV handling, LUT metadata/interpolation/sizing, hierarchy error recovery, installer idempotence, async subprocess/fileevents with a simulator fixture, and GUI Tcl command flow with mocked widgets.

Not validated here: actual xschem runtime, actual ngspice model behavior, real PDK simulations, rendered native Tk layout. The environment lacked xschem, ngspice, PDK installations and an X server. The package includes tests/gui_smoke.tcl and tools/check_iic.py for these checks in IIC-OSIC-TOOLS.

No fabricated simulation results or PDK lookup tables are included. The lookup-template.csv values are synthetic format examples labeled DEMO_ONLY.
