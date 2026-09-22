# Linux/IIC run lifecycle, diagnostics, and explicit result provenance.
namespace eval ::analog_lens {
    variable run_cancelled 0; variable run_cancel_timer {}; variable run_processes {}
    variable run_state idle; variable run_feedback {}; variable result_metadata {}; variable run_metadata {}
    variable declared [dict create corner {} temp_c {} vds_v {} vsb_v {}]
    variable conditions_message {}; variable environment_report {}
}
proc ::analog_lens::process_identity {id} {
    if {![string is integer -strict $id] || $id <= 1} {return {}}
    if {[catch {read_text /proc/$id/stat} stat]} {return {}}
    # The process name may contain spaces and parentheses; fields follow its last ')'.
    set fields [split [string trim [string range $stat [expr {[string last ) $stat]+1}] end]]]
    return [list [lindex $fields 19] [lindex $fields 0]]
}
proc ::analog_lens::signal_run {signal} {
    variable run_processes
    dict for {id identity} $run_processes {
        lassign [process_identity $id] started state
        if {$started eq $identity && $state ni {Z X {}}} {
            exec /bin/kill -$signal -- $id 2>@1
        }
    }
}
proc ::analog_lens::cancel_run {} {
    variable run_channel; variable run_cancelled; variable run_cancel_timer; variable run_state; variable status
    if {$run_channel eq {} || $run_cancelled} {return}
    signal_run TERM
    set run_cancelled 1; set run_state cancelling
    set status {Stopping this operating-point run… Existing loaded results will be kept.}
    set run_cancel_timer [after 2000 ::analog_lens::force_cancel_run]
    update_run_controls
}
proc ::analog_lens::force_cancel_run {} {
    variable run_channel; variable run_cancelled; variable run_cancel_timer; variable status
    set run_cancel_timer {}
    if {$run_channel ne {} && $run_cancelled} {
        if {[catch {signal_run KILL} msg]} {set status "Could not stop the simulator: $msg. Open Run log."}
    }
}
proc ::analog_lens::update_run_feedback {} {
    variable run_channel; variable run_started; variable run_state; variable run_feedback
    if {$run_channel eq {}} {set run_feedback {}; return}
    set elapsed [expr {max(0,[clock seconds]-$run_started)}]
    set label [expr {$run_state eq "cancelling" ? "Stopping" : "Running"}]
    set run_feedback "$label · [format %d:%02d [expr {$elapsed/60}] [expr {$elapsed%60}]] elapsed · Close hides this window; Cancel stops the run."
}
proc ::analog_lens::file_signature {path} {
    if {$path eq {}} {return {}}
    set value [dict create path [file normalize $path]]
    if {[file isfile $path]} {dict set value size [file size $path]; dict set value modified [file mtime $path]}
    return $value
}
proc ::analog_lens::capture_metadata {} {
    variable declared; variable sample; variable dataset; variable version
    set pdk {}; if {[info exists ::env(PDK)]} {set pdk $::env(PDK)}
    set rawpath {}; catch {set rawpath [raw rawfile]}
    set type {}; catch {set type [raw sim_type]}
    set sch {}; catch {set sch [xschem get current_name]}
    return [dict merge $declared [dict create pdk $pdk analysis $type sample $sample dataset $dataset \
        captured_at [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%SZ} -gmt 1] \
        extension_version $version raw [raw_signature $rawpath] schematic [file_signature $sch] \
        conditions_source {User-declared; not inferred from the simulator}]]
}
proc ::analog_lens::capture_result_metadata {} {
    variable result_metadata
    set next [capture_metadata]; set same [expr {$result_metadata ne {}}]
    foreach key {raw analysis} {
        if {[get $next $key] ne [get $result_metadata $key]} {set same 0}
    }
    if {$same} {
        foreach key {pdk corner temp_c vds_v vsb_v captured_at schematic input_deck input_crc32 run_context design_stamp source dependencies dependency_hash dependency_warnings observed_conditions verification conditions_source} {
            if {[dict exists $result_metadata $key]} {dict set next $key [dict get $result_metadata $key]}
        }
    }
    set result_metadata $next
}
proc ::analog_lens::condition_label {key} {
    return [get {pdk PDK corner Corner temp_c Temperature vds_v Vds vsb_v Vsb analysis Analysis sample Sample dataset Dataset} $key $key]
}
proc ::analog_lens::condition_differences {a b} {
    set differences {}
    foreach key {pdk corner temp_c vds_v vsb_v analysis sample dataset} {
        set x [get $a $key]; set y [get $b $key]
        if {$x eq {} || $y eq {}} {continue}
        if {[number $x] ne {} && [number $y] ne {}} {set same [expr {$x == $y}]} else {set same [string equal $x $y]}
        if {!$same} {lappend differences "[condition_label $key]: $x → $y"}
    }
    return $differences
}
proc ::analog_lens::apply_conditions {} {
    variable declared; variable edit_conditions; variable conditions_message; variable result_metadata
    if {$::analog_lens::run_channel ne {}} {set conditions_message {Finish or cancel the run before changing recorded conditions.}; return}
    set next [dict create corner [string trim $edit_conditions(corner)]]
    foreach key {temp_c vds_v vsb_v} {
        set value [string trim $edit_conditions($key)]
        if {$value ne {} && [number $value] eq {}} {set conditions_message "$key must be blank (unknown) or a finite number."; return}
        dict set next $key $value
    }
    set declared $next
    if {$result_metadata ne {}} {set result_metadata [recorded_conditions [dict merge $result_metadata $declared]]}
    set conditions_message {Conditions recorded as user-declared metadata. Simulation settings are unchanged.}
    render_compare; schedule_plot
}
proc ::analog_lens::environment_checks {} {
    set checks {}
    set simulator [auto_execok ngspice]
    lappend checks [list ngspice [expr {$simulator ne {} ? "Ready" : "Missing"}] \
        [expr {$simulator ne {} ? $simulator : "Launch xschem from the IIC terminal so ngspice is on PATH."}]]
    set pdk {}; if {[info exists ::env(PDKPATH)]} {set pdk $::env(PDKPATH)}
    if {$pdk eq {} && [info exists ::env(PDK_ROOT)] && [info exists ::env(PDK)]} {set pdk [file join $::env(PDK_ROOT) $::env(PDK)]}
    set found [expr {$pdk ne {} && [file isdirectory $pdk]}]
    lappend checks [list {PDK directory} [expr {$found ? "Found" : "Check"}] \
        [expr {$found ? $pdk : "Use sak-pdk in the IIC terminal, then reopen your project's xschem."}]]
    set init {}; if {[info exists ::env(SPICE_USERINIT_DIR)]} {set init $::env(SPICE_USERINIT_DIR)}
    lappend checks [list {Simulator initialization} [expr {$init ne {} && [file isdirectory $init] ? "Found" : "Check"}] \
        [expr {$init ne {} ? "$init — verify this matches the active PDK (including IHP OSDI setup)." : "SPICE_USERINIT_DIR is unset. Verify the PDK's ngspice initialization, especially IHP OSDI."}]]
    set directory {}; if {[info exists ::netlist_dir]} {set directory $::netlist_dir}
    set writable [expr {$directory ne {} && [file isdirectory $directory] && [file writable $directory]}]
    lappend checks [list {Simulation directory} [expr {$writable ? "Ready" : "Check"}] \
        [expr {$writable ? [file normalize $directory] : "Choose or create a writable simulation directory in xschem."}]]
    set top 0; catch {set top [expr {[xschem get currsch] == 0 && [xschem get netlist_type] eq "spice"}]}
    lappend checks [list Testbench [expr {$top ? "Ready" : "Check"}] {Run from the top-level testbench with SPICE netlisting selected.}]
    set api [expr {![catch {raw loaded} loaded]}]
    lappend checks [list {Result API} [expr {$api ? "Ready" : "Missing"}] \
        [expr {$api ? "xschem's raw API responds." : "Use an IIC xschem build with the raw API."}]]
    return $checks
}
proc ::analog_lens::check_environment {} {
    variable environment_report; variable window
    set environment_report "IIC-OSIC-TOOLS readiness\n\n"
    foreach check [environment_checks] {lassign $check label state detail; append environment_report "$label — $state\n$detail\n\n"}
    append environment_report {These checks inspect paths and APIs. Use tools/validate_iic.py for real simulation and PDK checks.}
    set w $window.environment
    if {[winfo exists $w]} {destroy $w}
    toplevel $w; wm title $w {Environment check · Analog Lens}; wm transient $w $window
    wm geometry $w 760x560; wm minsize $w 500 300
    ttk::frame $w.actions -padding 12; pack $w.actions -side bottom -fill x
    pack [button $w.actions.copy {Copy report} {::analog_lens::copy_text $::analog_lens::environment_report}] -side left
    pack [button $w.actions.close Close [list destroy $w]] -side right
    text $w.text -wrap word; text_style $w.text
    ttk::scrollbar $w.scroll -command [list $w.text yview]; $w.text configure -yscrollcommand [list $w.scroll set]
    pack $w.scroll -side right -fill y; pack $w.text -fill both -expand 1
    $w.text insert end $environment_report; $w.text configure -state disabled
    bind $w <Escape> [list destroy $w]; bind $w <Control-w> [list destroy $w]
}
