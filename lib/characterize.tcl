# Asynchronous real PDK characterization, separate from the circuit simulation.
namespace eval ::analog_lens {
    variable char_channel {}; variable char_log {}; variable char_state idle; variable char_cancelled 0
    variable char_pid {}; variable char_identity {}; variable char_cancel_timer {}; variable char_output {}
    variable char_project {}; variable char_status {}; variable char_device {}; variable char_pdk {}; variable char_edit
    array set char_edit {lengths {0.5 1} width 10 corner tt temp 27 vds 0.9 vsb 0 start 0.1 stop 1.8 step 0.025}
}
proc ::analog_lens::characterize_dialog {} {
    set device [current_device]; if {$device eq {}} {error {Select one supported MOS in the schematic.}}
    set model [supported_model $device]
    set pdk [active_pdk]
    if {$::analog_lens::char_channel ne {}} {
        set device $::analog_lens::char_device; set model [supported_model $device]; set pdk $::analog_lens::char_pdk
    }
    if {$pdk ni {sky130A gf180mcuD ihp-sg13g2 ihp-sg13cmos5l}} {error {Select an installed IIC PDK before characterizing.}}
    show
    set w $::analog_lens::window.characterize
    if {[winfo exists $w]} {raise $w; return}
    if {$::analog_lens::char_channel eq {}} {
        set ::analog_lens::char_device $device
        set ::analog_lens::char_pdk $pdk
        set length [dimension_um [get $device length] [get $device family]]
        set ::analog_lens::char_edit(lengths) [list $length [expr {2*$length}]]
        set voltage [dict get {sky130A 1.8 gf180mcuD 3.3 ihp-sg13g2 1.2 ihp-sg13cmos5l 1.2} $pdk]
        set ::analog_lens::char_edit(stop) $voltage
        set sign [expr {[get $device type] eq "pmos" ? -1 : 1}]
        set ::analog_lens::char_edit(vds) [expr {$sign*$voltage/2}]
        set ::analog_lens::char_edit(corner) [dict get {sky130A tt gf180mcuD typical ihp-sg13g2 mos_tt ihp-sg13cmos5l mos_tt} $pdk]
    }
    toplevel $w; wm title $w {Characterize installed PDK · Analog Lens}; wm transient $w $::analog_lens::window
    wm geometry $w 680x650; wm minsize $w 540 550
    ttk::frame $w.actions -padding 12; pack $w.actions -side bottom -fill x
    pack [button $w.actions.run {Generate lookup} ::analog_lens::start_characterization] -side left
    pack [button $w.actions.cancel {Cancel run} ::analog_lens::cancel_characterization] -side left -padx 8
    pack [button $w.actions.close Close [list destroy $w]] -side right
    ttk::label $w.status -textvariable ::analog_lens::char_status -wraplength 600 -padding 12; pack $w.status -side bottom -fill x
    ttk::frame $w.form -padding 12; pack $w.form -fill x
    pack [label $w.form.title "$pdk · $model" AL.Heading.TLabel] -anchor w -pady {0 8}
    ttk::frame $w.form.fields; pack $w.form.fields -fill x
    set i 0
    foreach {key title} {lengths {Lengths (µm, separated by spaces)} width {Total reference width (µm)} corner {Installed corner section} temp {Temperature (°C)} vds {Vds (V; negative for PMOS)} vsb {Vsb = Vs − Vb (V)} start {Starting |Vgs| (V)} stop {Ending |Vgs| (V)} step {|Vgs| step (V)}} {
        ttk::label $w.form.fields.l$key -text $title
        ttk::entry $w.form.fields.$key -textvariable ::analog_lens::char_edit($key) -width 24
        grid $w.form.fields.l$key -row $i -column 0 -sticky w -padx {0 16} -pady 3
        grid $w.form.fields.$key -row $i -column 1 -sticky ew -pady 3; incr i
    }
    grid columnconfigure $w.form.fields 1 -weight 1
    ttk::label $w.form.note -text {Runs real ngspice DC sweeps with the installed vendor models, one finger and one copy. Existing circuit results stay loaded. Output is stored with this project. Close hides progress; Cancel stops characterization.} -wraplength 600 -style AL.Muted.TLabel
    pack $w.form.note -fill x -pady {12 0}
    text $w.log -height 7 -wrap word -state disabled; text_style $w.log 1
    pack $w.log -fill both -expand 1 -padx 12
    bind $w <Escape> [list destroy $w]
    update_characterization_ui
}
proc ::analog_lens::characterization_command {output} {
    variable char_edit; variable char_device; variable root
    set model [supported_model $char_device]; set pdk $::analog_lens::char_pdk
    if {$pdk ne [active_pdk]} {error {The active PDK changed. Close and reopen Characterize for the current model.}}
    if {$pdk ni {sky130A gf180mcuD ihp-sg13g2 ihp-sg13cmos5l}} {error {Choose an installed IIC PDK.}}
    set python [auto_execok python3]; if {$python eq {}} {error {Python 3 is missing from the IIC environment.}}
    set lengths [split [string trim $char_edit(lengths)]]; set clean {}
    foreach length $lengths {
        if {$length eq {}} {continue}
        if {[number $length] eq {} || $length <= 0} {error {Lengths must be positive numbers in micrometers.}}
        lappend clean $length
    }
    if {![llength $clean]} {error {Enter at least one length.}}
    set command [list {*}$python -u [file join $root tools characterize.py] --pdk $pdk --model $model --output $output --lengths {*}$clean]
    foreach {key option} {width width temp temp vds vds vsb vsb start vgs-start stop vgs-stop step vgs-step} {
        if {[number $char_edit($key)] eq {}} {error "$key must be a finite number."}
        lappend command --$option $char_edit($key)
    }
    if {![regexp {^[A-Za-z0-9_]+$} $char_edit(corner)]} {error {Use an installed library section name for the corner.}}
    lappend command --corner $char_edit(corner)
    if {[info exists ::env(PDK_ROOT)]} {lappend command --pdk-root $::env(PDK_ROOT)}
    return $command
}
proc ::analog_lens::start_characterization {} {
    variable char_channel; variable char_log; variable char_state; variable char_cancelled
    variable char_output; variable char_project; variable char_pid; variable char_identity; variable char_status
    if {$char_channel ne {}} {error {Characterization is already running.}}
    project_sync
    if {$::analog_lens::project_directory eq {}} {error {Save the testbench to create a project lookup directory.}}
    set char_project $::analog_lens::project_key
    set model [supported_model $::analog_lens::char_device]
    set directory [file join $::analog_lens::project_directory .analog-lens lookups "$model-[clock milliseconds]"]
    set char_output [file join $directory lookup.csv]
    set command [characterization_command $char_output]
    file mkdir $directory
    set char_channel [open [list | {*}$command 2>@1] r]
    set char_pid [lindex [pid $char_channel] 0]; set char_identity [lindex [process_identity $char_pid] 0]
    fconfigure $char_channel -blocking 0 -buffering none -encoding utf-8
    fileevent $char_channel readable ::analog_lens::characterization_readable
    set char_log {}; set char_state running; set char_cancelled 0
    set char_status {Running real ngspice sweeps…}; update_characterization_ui
}
proc ::analog_lens::signal_characterization {signal} {
    if {$::analog_lens::char_channel eq {}} {return}
    lassign [process_identity $::analog_lens::char_pid] started state
    if {$started eq $::analog_lens::char_identity && $state ni {Z X {}}} {exec /bin/kill -$signal -- $::analog_lens::char_pid 2>@1}
}
proc ::analog_lens::cancel_characterization {} {
    if {$::analog_lens::char_channel eq {} || $::analog_lens::char_cancelled} {return}
    signal_characterization TERM
    set ::analog_lens::char_cancelled 1; set ::analog_lens::char_state cancelling
    set ::analog_lens::char_status {Stopping characterization… Previous lookup data is retained.}
    set ::analog_lens::char_cancel_timer [after 2000 {catch {::analog_lens::signal_characterization KILL}}]
    update_characterization_ui
}
proc ::analog_lens::characterization_readable {} {
    variable char_channel; variable char_log; variable char_state; variable char_status; variable char_cancel_timer
    append char_log [read $char_channel]
    if {[string length $char_log] > 200000} {set char_log [string range $char_log end-199999 end]}
    if {![eof $char_channel]} {update_characterization_ui; return}
    set channel $char_channel; set char_channel {}; fileevent $channel readable {}; fconfigure $channel -blocking 1
    set failed [catch {close $channel} why]
    if {$char_cancel_timer ne {}} {after cancel $char_cancel_timer; set char_cancel_timer {}}
    if {$::analog_lens::char_cancelled} {set char_state cancelled; set char_status {Cancelled · Previous lookup data retained.}} elseif {$failed || ![file isfile $::analog_lens::char_output]} {
        set char_state failed; set char_status {Characterization failed. See the log below; prior lookup data is unchanged.}
    } elseif {[catch {
        set rows [parse_lut [read_text $::analog_lens::char_output]]]
        if {[lindex [project_identity] 0] eq $::analog_lens::char_project} {
            set ::analog_lens::lut_rows $rows; set ::analog_lens::lut_file $::analog_lens::char_output
            set ::analog_lens::lut_slice [get [lindex $rows 0] slice]
            rebuild_lookup_filters; set ::analog_lens::lookup_match_key {}; auto_select_lookup; project_flush
            set char_status "Loaded [llength $rows] measured samples. CSV and provenance: $::analog_lens::char_output"
        } else {set char_status "Complete. Project changed; load $::analog_lens::char_output when you return."}
        set char_state completed
    } why]} {set char_state failed; set char_status "Generated lookup could not be loaded: $why"}
    update_characterization_ui
}
proc ::analog_lens::update_characterization_ui {} {
    set w $::analog_lens::window.characterize
    if {![winfo exists $w]} {return}
    set idle [expr {$::analog_lens::char_channel eq {}}]
    set_enabled $w.actions.run $idle; set_enabled $w.actions.cancel [expr {!$idle && !$::analog_lens::char_cancelled}]
    foreach key {lengths width corner temp vds vsb start stop step} {set_enabled $w.form.fields.$key $idle}
    $w.log configure -state normal; $w.log delete 1.0 end; $w.log insert end $::analog_lens::char_log; $w.log configure -state disabled; $w.log see end
}
