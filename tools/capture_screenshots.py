#!/usr/bin/env python3
"""Capture real Tk widgets with the repository's synthetic demo fixtures.

Run on Linux with Python tkinter, Pillow (XCB support), and an X11 display:
    xvfb-run -a -s '-screen 0 1440x1000x24' python3 tools/capture_screenshots.py
No xschem, ngspice, or installed PDK is needed. No simulation is performed.
"""

from pathlib import Path
import argparse
import os
import tkinter as tk

from PIL import ImageGrab


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs" / "images"
WINDOW = ".analog_lens"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, default=OUTPUT)
    parser.add_argument('--audit', action='store_true', help='Also capture minimum-size, large-text, and dark-theme states.')
    args = parser.parse_args()
    if not os.environ.get("DISPLAY"):
        raise SystemExit("An X11 display is required; see the xvfb-run command above.")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    app = tk.Tk()
    app.withdraw()
    try:
        call = app.tk.call
        # Fix capture scale/theme, without changing the extension's widget code.
        call("tk", "scaling", 1.3333333333)
        call("ttk::style", "theme", "use", "clam")
        call("source", str(ROOT / "tests" / "mock_xschem.tcl"))
        call("source", str(ROOT / "analog_lens.tcl"))
        call("::analog_lens::show")
        call("after", "cancel", call("set", "::analog_lens::timer"))
        call("set", "::analog_lens::timer", "")
        call("set", "::analog_lens::live", 0)
        call("set", "::analog_lens::summary", "DEMO ONLY  ·  Synthetic fixture data")
        call("set", "::analog_lens::status",
             "Native Tk interface preview · No PDK simulation was run. Missing parameters appear as —.")
        call("wm", "geometry", WINDOW, "1380x940+20+20")
        app.update()

        def capture(filename, target=WINDOW):
            # Let the debounced canvas redraw finish after geometry changes.
            settled = tk.BooleanVar(app, False)
            app.after(250, settled.set, True)
            app.wait_variable(settled)
            app.update_idletasks()
            app.update()
            x = int(call("winfo", "rootx", target))
            y = int(call("winfo", "rooty", target))
            w = int(call("winfo", "width", target))
            h = int(call("winfo", "height", target))
            screen_w = int(call("winfo", "screenwidth", WINDOW))
            screen_h = int(call("winfo", "screenheight", WINDOW))
            if x < 0 or y < 0 or x + w > screen_w or y + h > screen_h:
                raise RuntimeError("Display is too small; use at least 1440x1000.")
            image = ImageGrab.grab(bbox=(x, y, x + w, y + h),
                                   xdisplay=os.environ["DISPLAY"])
            image.save(args.output_dir / filename, optimize=True)
            print(f"Saved {args.output_dir / filename} ({w}×{h})")

        tree = WINDOW + ".tabs.op.panes.list.tree"
        call(tree, "selection", "set", "d0")
        call("::analog_lens::inspect_selection")
        capture("operating-point.png")

        # Use the normal CSV loading path; substitute only the file dialog.
        call("rename", "tk_getOpenFile", "original_tk_getOpenFile")
        app.createcommand("tk_getOpenFile", lambda *args: str(
            ROOT / "examples" / "lookup-template.csv"))
        try:
            call("::analog_lens::load_lut")
        finally:
            app.deletecommand("tk_getOpenFile")
            call("rename", "original_tk_getOpenFile", "tk_getOpenFile")
        call("set", "::analog_lens::target_length", "0.3")
        call("set", "::analog_lens::target_gmid", "16")
        call("set", "::analog_lens::target_gm_u", "800")
        call("set", "::analog_lens::sizing_visible", 1)
        call("::analog_lens::toggle_sizing")
        call(WINDOW + ".tabs", "select", WINDOW + ".tabs.lut")
        app.update()
        pending = call("set", "::analog_lens::plot_after")
        if pending:
            call("after", "cancel", pending)
        call("::analog_lens::draw_plot")
        call("::analog_lens::calculate_size")
        capture("gmid-explorer.png")
        call("::analog_lens::keep_baseline")
        app.tk.eval('dict set ::mock::vectors {@m.xm1.m0[gm]} 0.001')
        call("::analog_lens::refresh")
        call("set", "::analog_lens::status", "DEMO ONLY · Synthetic baseline and current results; no simulation was run.")
        call(WINDOW + ".tabs", "select", WINDOW + ".tabs.compare")
        capture("compare-runs.png")
        call(WINDOW + ".tabs", "select", WINDOW + ".tabs.setup")
        capture("setup-help.png")
        call("::analog_lens::data_dialog")
        call("wm", "geometry", WINDOW + ".data", "760x440+40+40")
        capture("lookup-data.png", WINDOW + ".data")
        call("destroy", WINDOW + ".data")
        call("set", "::analog_lens::run_log", "DEMO ONLY — synthetic log for interface preview\n\nNo PDK simulation was run.\nNew simulator output appears here while an analysis is running.\nUse Copy log to retain diagnostics.")
        call("::analog_lens::log_dialog")
        call("wm", "geometry", WINDOW + ".log", "840x460+40+40")
        capture("run-log.png", WINDOW + ".log")
        call("destroy", WINDOW + ".log")
        if args.audit:
            call("set", "::analog_lens::sizing_visible", 0)
            call("::analog_lens::toggle_sizing")
            call("wm", "geometry", WINDOW, "900x640+20+20")
            for tab in ("op", "lut", "compare", "setup"):
                call(WINDOW + ".tabs", "select", WINDOW + ".tabs." + tab)
                capture("minimum-" + tab + ".png")
            call(WINDOW + ".tabs", "select", WINDOW + ".tabs.op")
            call("set", "::analog_lens::search", "no-match")
            call("::analog_lens::render")
            capture("empty-search.png")
            call("::analog_lens::clear_search")
            call("::analog_lens::close_window")
            for font in ("TkDefaultFont", "TkTextFont", "TkFixedFont"):
                call("font", "configure", font, "-size", 14)
            call("::analog_lens::show")
            call("after", "cancel", call("set", "::analog_lens::timer"))
            call("set", "::analog_lens::timer", "")
            call("set", "::analog_lens::summary", "DEMO ONLY · Larger system text")
            call("wm", "geometry", WINDOW, "900x640+20+20")
            for tab in ("op", "lut", "compare", "setup"):
                call(WINDOW + ".tabs", "select", WINDOW + ".tabs." + tab)
                capture("large-text-" + tab + ".png")
            call("::analog_lens::close_window")
            for font in ("TkDefaultFont", "TkTextFont", "TkFixedFont"):
                call("font", "configure", font, "-size", 10)
            app.tk.eval('''
                ttk::style theme create CaptureDark -parent clam -settings {
                    ttk::style configure . -background #202024 -foreground #f4f4f5
                    ttk::style configure TFrame -background #202024
                    ttk::style configure TLabel -foreground #f4f4f5
                    ttk::style configure Treeview -background #29292f -fieldbackground #29292f -foreground #f4f4f5
                    ttk::style configure TEntry -fieldbackground #29292f -foreground #f4f4f5
                    ttk::style configure TCombobox -fieldbackground #29292f -foreground #f4f4f5
                    ttk::style configure TSpinbox -fieldbackground #29292f -foreground #f4f4f5
                }
                ttk::style theme use CaptureDark
            ''')
            call("::analog_lens::show")
            call("after", "cancel", call("set", "::analog_lens::timer"))
            call("set", "::analog_lens::timer", "")
            call("set", "::analog_lens::summary", "DEMO ONLY · Dark host theme")
            call("wm", "geometry", WINDOW, "1180x820+20+20")
            for tab in ("op", "lut"):
                call(WINDOW + ".tabs", "select", WINDOW + ".tabs." + tab)
                capture("dark-" + tab + ".png")
    finally:
        if int(app.tk.call("winfo", "exists", WINDOW)):
            app.tk.call("::analog_lens::close_window")
        app.destroy()


if __name__ == "__main__":
    main()
