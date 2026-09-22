# Actual xschem/PDK integration. Invoked by tools/validate_iic.py, never by mocks.
proc fail {message} {
    puts stderr "LIVE CHECK FAILED: $message"
    if {[info exists ::analog_lens::run_log]} {puts stderr $::analog_lens::run_log}
    exit 1
}
proc require {condition message} {if {![uplevel 1 [list expr $condition]]} {fail $message}}
proc bgerror {message} {fail "$message\n$::errorInfo"}
set no_ask_quit 1
if {[catch {
    source [file join $::env(ANALOG_LENS_ROOT) analog_lens.tcl]
    set ::netlist_dir $::env(ANALOG_LENS_OUTPUT)
    ::analog_lens::show
    update
    set devices [::analog_lens::collect_devices]
    require {[llength $devices] == 2} {Expected a top-level MOS and a MOS inside x1.}
    ::analog_lens::run_op
    set deadline [expr {[clock milliseconds]+90000}]
    while {$::analog_lens::run_channel ne {}} {
        require {[clock milliseconds] < $deadline} {Simulator exceeded 90 seconds.}
        after 20 {set ::live_tick 1}; vwait ::live_tick
    }
    require {$::analog_lens::run_state eq "completed"} $::analog_lens::status
    require {[llength $::analog_lens::records] == 1} {Expected one top-level MOS result.}
    set values [dict get [lindex $::analog_lens::records 0] values]
    require {[dict get $values gm] > 0 && [dict get $values gmid] > 0} {Missing top-level MOS parameters.}
    ::analog_lens::export_report [file join $::env(ANALOG_LENS_OUTPUT) top.csv]
    .analog_lens.tabs.op.panes.list.tree selection set d0
    ::analog_lens::inspect_selection
    ::analog_lens::locate
    require {[lsearch -exact [xschem selected_set] M1] >= 0} {Cross-probing did not select M1.}
    ::analog_lens::color_devices
    set ::analog_lens::baseline_name {Live nominal}; ::analog_lens::keep_baseline
    ::analog_lens::save_session [file join $::env(ANALOG_LENS_OUTPUT) live.alsession]
    xschem unselect_all; xschem select instance x1
    require {[xschem descend 1 2]} {Could not descend into x1.}
    ::analog_lens::refresh
    require {[llength $::analog_lens::records] == 1} {Expected one MOS result inside x1.}
    set child [dict get [lindex $::analog_lens::records 0] values]
    require {[dict get $child gm] > 0} {Hierarchy mapping lost the child gm vector.}
    ::analog_lens::export_report [file join $::env(ANALOG_LENS_OUTPUT) child.csv]
    xschem go_back 2; ::analog_lens::refresh
    .analog_lens.tabs.op.panes.list.tree selection set d0
    ::analog_lens::inspect_selection
    set before [xschem get instances]
    ::analog_lens::place_annotation
    set canvas [xschem get current_win_path]
    event generate $canvas <Motion> -x 300 -y 200
    event generate $canvas <ButtonPress-1> -x 300 -y 200
    event generate $canvas <ButtonRelease-1> -x 300 -y 200
    update
    require {[xschem get instances] == $before+1} {Annotation placement did not add one object.}
    require {[string first {gm/Id} [::analog_lens::annotation M1]] >= 0} {Annotation has no device metrics.}
    ::analog_lens::close_window
    ::analog_lens::write_text [file join $::env(ANALOG_LENS_OUTPUT) passed.txt] {Real xschem run, hierarchy, cross-probing, highlighting, annotation and session checks passed.}
} message]} {fail "$message\n$::errorInfo"}
puts {Live xschem integration passed.}
exit 0
