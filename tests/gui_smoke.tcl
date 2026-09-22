# Run inside IIC-OSIC-TOOLS: xvfb-run -a wish tests/gui_smoke.tcl
# This validates real Tk construction/events with contract-fixture xschem data.
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root tests mock_xschem.tcl]
source [file join $root analog_lens.tcl]
proc bgerror {message} {puts stderr "$message\n$::errorInfo"; exit 1}
::analog_lens::show
update
set rows [.analog_lens.tabs.op.canvas.content.panes.list.tree children {}]
if {[llength $rows] != 2} {error {Expected two device rows}}
.analog_lens.tabs.op.canvas.content.panes.list.tree selection set d1
::analog_lens::inspect_selection
::analog_lens::locate
::analog_lens::keep_baseline
set ::analog_lens::lut_rows [::analog_lens::parse_lut [::analog_lens::read_text [file join $root examples lookup-template.csv]]]
set ::analog_lens::lut_slice [dict get [lindex $::analog_lens::lut_rows 0] slice]
set ::analog_lens::target_length 0.3
set ::analog_lens::target_gmid 16
set ::analog_lens::target_gm_u 800
.analog_lens.tabs select .analog_lens.tabs.lut
update
::analog_lens::draw_plot
::analog_lens::calculate_size
foreach tab {op compare setup} {.analog_lens.tabs select .analog_lens.tabs.$tab; update}
wm geometry .analog_lens 900x640
update
::analog_lens::close_window
if {[namespace exists ::mocktk]} {
    puts {GUI Tcl command contract passed (mock widgets; no rendering).}
} else {
    puts {Native Tk smoke test passed.}
}
exit 0
