# Actual xschem/PDK integration. Invoked by tools/validate_iic.py, never by mocks.
fconfigure stdout -buffering line
set live_stage startup
proc stage {name} {set ::live_stage $name; puts "LIVE STAGE: $name"}
proc fail {message} {
    puts stderr "LIVE CHECK FAILED: $message"
    catch {puts stderr "Open windows: [winfo children .]"}
    catch {capture_live [xschem get topwindow] failure.png}
    if {[info exists ::analog_lens::run_log]} {puts stderr $::analog_lens::run_log}
    exit 1
}
proc require {condition message} {if {![uplevel 1 [list expr $condition]]} {fail $message}}
proc bgerror {message} {fail "$message\n$::errorInfo"}
proc capture_live {window name} {
    raise $window; update
    set command [list python3 [file join $::env(ANALOG_LENS_ROOT) tools capture_live.py] \
        --output [file join $::env(ANALOG_LENS_OUTPUT) $name] \
        [winfo rootx $window] [winfo rooty $window] [winfo width $window] [winfo height $window]]
    if {[catch {exec {*}$command 2>@1} why]} {puts "Screenshot unavailable: $why"}
}
set no_ask_quit 1
after 300000 {fail "Timed out during $::live_stage"}
if {[catch {
    stage startup
    set netlist_show 0
    source [file join $::env(ANALOG_LENS_ROOT) analog_lens.tcl]
    set ::netlist_dir $::env(ANALOG_LENS_OUTPUT)
    ::analog_lens::show
    update
    set devices [::analog_lens::collect_devices]
    require {[llength $devices] == 2} {Expected a top-level MOS and a MOS inside x1.}
    stage isolated-op
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
    stage hierarchy-and-annotation
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
    # Embedded sidebar shares xschem's toplevel and follows its selection.
    stage sidebar
    xschem unselect_all; xschem select instance M1
    ::analog_lens::show_sidebar; update
    set panel $::analog_lens::sidebar
    require {[winfo toplevel $panel] eq [xschem get topwindow]} {Inspector is not embedded in xschem.}
    require {[winfo width $panel] > 200 && [winfo height $panel] > 200} {Embedded inspector has no usable geometry.}
    ::analog_lens::hide_sidebar; ::analog_lens::show_sidebar; update
    # xschem asks to save a modified parent before hierarchy traversal.
    # This is a generated testbench; persist its tested annotation explicitly.
    xschem save

    # Use native simulation and retain the caller callback and .control alterations.
    stage native-simulation
    set sim(spice,default) 0
    set sim(spice,0,cmd) {ngspice -b "$N"}
    set sim(spice,0,fg) 0
    set sim(spice,0,st) 0
    dict set ::analog_lens::integration_options result_analysis auto
    # PDK startup files can enable a modal netlist viewer. The native
    # simulation contract does not require a person to close that viewer.
    set netlist_show 0
    stage native-netlist
    xschem netlist
    stage native-launch
    set native_id [simulate {set ::native_callback_seen 1}]
    stage native-completion
    set deadline [expr {[clock milliseconds]+90000}]
    while {[info exists ::execute(pipe,$native_id)]} {
        require {[clock milliseconds] < $deadline} {Native simulator exceeded 90 seconds.}
        after 20 {set ::live_tick 1}; vwait ::live_tick
    }
    update
    ::analog_lens::attach_native_result
    require {[info exists ::native_callback_seen]} {Native simulation callback was lost.}
    require {[file tail [::analog_lens::raw rawfile]] eq "top.raw"} "Native results were not attached: $::analog_lens::native_message"
    ::analog_lens::refresh
    set native_values [dict get [lindex $::analog_lens::records 0] values]
    require {abs([dict get $native_values terminal_vds]-0.7) < 1e-5} {Native .control alter command was not preserved.}
    file copy -force [::analog_lens::raw rawfile] [file join $::env(ANALOG_LENS_OUTPUT) native-original.raw]
    ::analog_lens::export_report [file join $::env(ANALOG_LENS_OUTPUT) native.csv]
    set report [::analog_lens::read_text [file join $::env(ANALOG_LENS_OUTPUT) native.csv]]
    ::analog_lens::write_text [file join $::env(ANALOG_LENS_OUTPUT) native.csv] [string map [list [::analog_lens::raw rawfile] [file join $::env(ANALOG_LENS_OUTPUT) native-original.raw]] $report]
    ::analog_lens::update_freshness
    require {[string match {Current*} $::analog_lens::freshness]} "Native source state incorrect: $::analog_lens::freshness"
    set host [xschem get topwindow]
    wm geometry $host 1360x900+20+20; update; xschem zoom_full 0 0.8
    xschem unselect_all; xschem select instance M1
    ::analog_lens::refresh_sidebar
    capture_live $host integrated-inspector.png

    # Apply a real characterized curve, verify the property edit and one-step Undo.
    stage sizing-and-undo
    set ::analog_lens::lut_file $::env(ANALOG_LENS_LOOKUP)
    set ::analog_lens::lut_rows [::analog_lens::parse_lut [::analog_lens::read_text $::analog_lens::lut_file]]
    set ::analog_lens::lut_slice [dict get [lindex $::analog_lens::lut_rows 0] slice]
    ::analog_lens::rebuild_lookup_filters
    set rows {}; foreach row $::analog_lens::lut_rows {if {[dict get $row length_um] == 0.5} {lappend rows $row}}
    set point [lindex $rows [expr {[llength $rows]/2}]]
    set ::analog_lens::target_length 0.5
    set ::analog_lens::target_gmid [dict get $point gmid]
    set ::analog_lens::target_gm_u [expr {2e6*[dict get $point gm_s]}]
    set before_props [xschem getprop instance M1]
    ::analog_lens::preview_size
    capture_live .analog_lens.sizepreview sizing-preview.png
    set planned_width [dict get $::analog_lens::size_plan result width]
    require {abs($planned_width-20) < 1e-6} {Real lookup sizing did not scale width as expected.}
    ::analog_lens::apply_size_plan
    set selected [::analog_lens::current_device]
    set family [dict get $selected family]
    set width_key [expr {$family eq "ihp" ? "w" : "W"}]
    require {abs([::analog_lens::dimension_um [xschem getprop instance M1 $width_key] $family]-20) < 1e-5} {Sizing did not update the schematic width.}
    require {[string match {Out of date*} $::analog_lens::freshness]} {Sizing edit did not mark old results stale.}
    xschem undo
    require {[xschem getprop instance M1] eq $before_props} {One xschem Undo did not restore all geometry properties.}

    # Exercise an unsaved multifinger edit through native netlisting and verification.
    stage multifinger-verification
    xschem unselect_all; xschem select instance M1
    set ::analog_lens::target_fingers 2; set ::analog_lens::target_copies 2
    ::analog_lens::refresh
    ::analog_lens::preview_size
    set expected_geometry [dict get $::analog_lens::size_plan geometry]
    ::analog_lens::apply_size_plan 2
    set deadline [expr {[clock milliseconds]+90000}]
    while {[dict size $::analog_lens::native_jobs]} {
        require {[clock milliseconds] < $deadline} {Sized native simulation exceeded 90 seconds.}
        after 20 {set ::live_tick 1}; vwait ::live_tick
    }
    update; ::analog_lens::attach_native_result
    puts "VERIFY SUMMARY: $::analog_lens::verification_summary"
    puts "VERIFY NATIVE: $::analog_lens::native_message"
    puts "VERIFY SAVED STAMP: [::analog_lens::get $::analog_lens::result_metadata design_stamp]"
    puts "VERIFY CURRENT STAMP: [::analog_lens::design_stamp]"
    if {[dict exists $::analog_lens::pending_verifications $::analog_lens::project_key]} {
        puts "VERIFY APPLIED STAMP: [dict get $::analog_lens::pending_verifications $::analog_lens::project_key applied_stamp]"
    }
    require {[dict size $::analog_lens::verification_result] > 0} "Sizing verification missing: $::analog_lens::verification_summary"
    require {[dict get $::analog_lens::verification_result state] in {Pass Miss}} {Sizing targets were not measured.}
    lassign [::analog_lens::native_paths] native_directory native_deck
    set deck_text [regsub -all {\n[ \t]*\+[ \t]*} [::analog_lens::read_text $native_deck] { }]
    set sized_instance [lindex [regexp -all -inline -line {^XM1[^\n]*} $deck_text] 0]
    require {[regexp {(^|\s)(nf|ng)=2(\s|$)} $sized_instance]} "Finger count was not emitted by the installed symbol: $sized_instance"
    require {[regexp {(^|\s)(m|mult)=2(\s|$)} $sized_instance]} "Copy count was not emitted by the installed symbol: $sized_instance"
    ::analog_lens::verification_dialog
    capture_live .analog_lens.verification sizing-verification.png
    ::analog_lens::results_dialog
    require {[llength [.analog_lens.results.tree children {}]] >= 3} {Project history did not retain runs and baselines.}
    capture_live .analog_lens.results project-results.png
    ::analog_lens::write_text [file join $::env(ANALOG_LENS_OUTPUT) verification.tcldata] $::analog_lens::verification_result
    # Restore the baseline geometry for the existing raw/export comparison checks.
    xschem undo
    set ::analog_lens::target_fingers {}; set ::analog_lens::target_copies {}

    # Global waveform cursor B follows the nearest saved point in an actual DC raw.
    stage cursor
    ::analog_lens::read_results $::env(ANALOG_LENS_SWEEP) dc
    set ::analog_lens::sample 0; set ::analog_lens::dataset 0
    dict set ::analog_lens::integration_options follow_cursor 1
    set axis [lindex [::analog_lens::raw list] 0]
    set point [expr {[::analog_lens::raw points 0]/2}]
    xschem set cursor2_x [::analog_lens::raw value $axis $point 0]
    set ::analog_lens::cursor_key {}; ::analog_lens::follow_cursor
    require {abs($::analog_lens::sample-$point) <= 1} {Waveform cursor did not select its saved point.}
    require {[dict get [dict get [lindex $::analog_lens::records 0] values] gm] > 0} {Cursor-following lost gm data.}

    # Drive the actual asynchronous characterization GUI once per PDK.
    stage characterization
    # Undo/raw loading can clear the host selection. Select the target again
    # just as a user does before opening its model characterization form.
    xschem unselect_all; xschem select instance M1
    ::analog_lens::characterize_dialog
    array set ::analog_lens::char_edit {lengths 0.5 width 10 temp 27 vds 0.7 vsb 0 start 0.4 stop 1.0 step 0.1}
    ::analog_lens::start_characterization
    set deadline [expr {[clock milliseconds]+90000}]
    while {$::analog_lens::char_channel ne {}} {
        require {[clock milliseconds] < $deadline} {GUI characterization exceeded 90 seconds.}
        after 20 {set ::live_tick 1}; vwait ::live_tick
    }
    require {$::analog_lens::char_state eq "completed"} "$::analog_lens::char_status\n$::analog_lens::char_log"
    require {$::analog_lens::lut_file eq $::analog_lens::char_output} {Generated lookup was not loaded into the explorer.}
    capture_live .analog_lens.characterize characterization.png
    ::analog_lens::project_flush
    stage characterization-batch
    ::analog_lens::batch_dialog
    set ::analog_lens::batch_edit(corners) $::analog_lens::char_edit(corner)
    set ::analog_lens::batch_edit(temps) {27 85}
    set ::analog_lens::batch_edit(vds) 0.7
    set ::analog_lens::batch_edit(vsb) 0
    foreach attempt {first reused} {
        ::analog_lens::start_characterization 1
        set deadline [expr {[clock milliseconds]+90000}]
        while {$::analog_lens::char_channel ne {}} {
            require {[clock milliseconds] < $deadline} {Characterization batch exceeded 90 seconds.}
            after 20 {set ::live_tick 1}; vwait ::live_tick
        }
        require {$::analog_lens::char_state eq "completed"} "$::analog_lens::char_status\n$::analog_lens::char_log"
        if {$attempt eq "reused"} {require {[string first {Reusing verified cached samples} $::analog_lens::char_log] >= 0} {Completed batch conditions were not reused.}}
    }
    capture_live .analog_lens.batch characterization-batch.png
    ::analog_lens::project_flush
    stage project-persistence
    set session [::analog_lens::project_session_path $::analog_lens::project_key $::analog_lens::project_directory]
    require {[file isfile $session]} {Project session was not autosaved.}
    set restore_target $::analog_lens::target_gm_u
    set ::analog_lens::target_gm_u 1
    ::analog_lens::open_session $session
    require {$::analog_lens::target_gm_u == $restore_target} {Project session did not restore sizing targets.}
    ::analog_lens::close_window
    ::analog_lens::write_text [file join $::env(ANALOG_LENS_OUTPUT) passed.txt] {Real xschem run, hierarchy, cross-probing, annotation, embedded sidebar, native simulation/callback, cursor following, sizing/Undo, multifinger measured verification, project results browser, characterization batches/cache reuse and project persistence passed.}
} message]} {fail "$message\n$::errorInfo"}
puts {Live xschem integration passed.}
exit 0
