#!/usr/bin/env python3
"""Capture real Tk widgets with the repository's synthetic demo fixtures.

Run on Linux with Python tkinter, Pillow (XCB support), and an X11 display:
    xvfb-run -a -s '-screen 0 1440x1000x24' python3 tools/capture_screenshots.py
No xschem, ngspice, or installed PDK is needed. No simulation is performed.
"""

from pathlib import Path
import os
import tkinter as tk

from PIL import ImageGrab


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs" / "images"
WINDOW = ".analog_lens"


def main():
    if not os.environ.get("DISPLAY"):
        raise SystemExit("An X11 display is required; see the xvfb-run command above.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
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

        def capture(filename):
            # Let the debounced canvas redraw finish after geometry changes.
            settled = tk.BooleanVar(app, False)
            app.after(250, settled.set, True)
            app.wait_variable(settled)
            app.update_idletasks()
            app.update()
            x = int(call("winfo", "rootx", WINDOW))
            y = int(call("winfo", "rooty", WINDOW))
            w = int(call("winfo", "width", WINDOW))
            h = int(call("winfo", "height", WINDOW))
            screen_w = int(call("winfo", "screenwidth", WINDOW))
            screen_h = int(call("winfo", "screenheight", WINDOW))
            if x < 0 or y < 0 or x + w > screen_w or y + h > screen_h:
                raise RuntimeError("Display is too small; use at least 1440x1000.")
            image = ImageGrab.grab(bbox=(x, y, x + w, y + h),
                                   xdisplay=os.environ["DISPLAY"])
            image.save(OUTPUT / filename, optimize=True)
            print(f"Saved {OUTPUT / filename} ({w}×{h})")

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
        call(WINDOW + ".tabs", "select", WINDOW + ".tabs.lut")
        app.update()
        pending = call("set", "::analog_lens::plot_after")
        if pending:
            call("after", "cancel", pending)
        call("::analog_lens::draw_plot")
        call("::analog_lens::calculate_size")
        capture("gmid-explorer.png")
    finally:
        if int(app.tk.call("winfo", "exists", WINDOW)):
            app.tk.call("::analog_lens::close_window")
        app.destroy()


if __name__ == "__main__":
    main()
