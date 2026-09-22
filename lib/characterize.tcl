# Asynchronous real PDK characterization, separate from the circuit simulation.
namespace eval ::analog_lens {
    variable char_channel {}; variable char_log {}; variable char_state idle; variable char_cancelled 0
    variable char_pid {}; variable char_identity {}; variable char_cancel_timer {}; variable char_output {}
    variable char_help {Set the device geometry and sweep, then generate a lookup.}
    variable char_error 0
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
    set previous $::analog_lens::char_context
    if {$::analog_lens::char_channel eq {}} {prepare_characterization $device}
    if {[winfo exists $w]} {
        if {$previous eq $::analog_lens::char_context} {raise $w; return}
        destroy $w
    }
    toplevel $w; wm title $w {Characterize installed PDK · Analog Lens}; wm transient $w $::analog_lens::window
    wm geometry $w 780x740; wm minsize $w 580 440
    ttk::frame $w.actions -padding 12; pack $w.actions -side bottom -fill x
    pack [button $w.actions.run {Generate lookup} {::analog_lens::characterization_action ::analog_lens::start_characterization}] -side left
    pack [button $w.actions.cancel {Cancel run} ::analog_lens::cancel_characterization] -side left -padx 8
    pack [button $w.actions.batch {PVT / bias batch…} ::analog_lens::batch_dialog] -side left
    pack [button $w.actions.close Close [list destroy $w]] -side right
    set b [dialog_page $w]
    ttk::label $b.status -textvariable ::analog_lens::char_status -wraplength 600 -padding 12; pack $b.status -side bottom -fill x
    ttk::frame $b.form -padding 12; pack $b.form -fill x
    pack [label $b.form.title "$pdk · $model" AL.Heading.TLabel] -fill x -pady {0 8}
    ttk::frame $b.form.fields; pack $b.form.fields -fill x
    set i 0
    foreach {key title} {lengths {Lengths (µm)} width {Total reference width (µm)} corner {Installed corner section} temp {Temperature (°C)} vds {Vds (V)} vsb {Vsb = Vs − Vb (V)} start {Starting |Vgs| (V)} stop {Ending |Vgs| (V)} step {|Vgs| step (V)}} {
        ttk::label $b.form.fields.l$key -text $title
        if {$key eq "corner"} {
            ttk::combobox $b.form.fields.$key -textvariable ::analog_lens::char_edit($key) -values [characterization_corners] -width 24
        } else {ttk::entry $b.form.fields.$key -textvariable ::analog_lens::char_edit($key) -width 24}
        hint $b.form.fields.$key [characterization_hint $key] ::analog_lens::char_help
        grid $b.form.fields.l$key -row $i -column 0 -sticky w -padx {0 16} -pady 3
        grid $b.form.fields.$key -row $i -column 1 -sticky ew -pady 3; incr i
    }
    grid columnconfigure $b.form.fields 1 -weight 1
    ttk::button $b.form.conditions -text {Use this device's conditions} -command {::analog_lens::characterization_action ::analog_lens::use_device_conditions}
    pack $b.form.conditions -anchor w -pady 4
    ttk::label $b.form.help -textvariable ::analog_lens::char_help -wraplength 600 -style AL.Muted.TLabel
    pack $b.form.help -fill x; wrapping $b.form.help
    ttk::label $b.form.corners -textvariable ::analog_lens::corner_note -wraplength 600 -style AL.Muted.TLabel
    pack $b.form.corners -fill x; wrapping $b.form.corners
    ttk::label $b.form.note -text {Runs real ngspice DC sweeps with the installed vendor models, one finger and one copy. Existing circuit results stay loaded. Output is stored with this project. Close hides progress; Cancel stops characterization.} -wraplength 600 -style AL.Muted.TLabel
    pack $b.form.note -fill x -pady {12 0}
    text $b.log -height 7 -wrap word -state disabled; text_style $b.log 1
    pack $b.log -fill both -expand 1 -padx 12
    wrapping $b.form.title; wrapping $b.form.note; wrapping $b.status
    log_area $b
    ttk::progressbar $b.progress -mode indeterminate
    dialog_content [list $b.form $b.status $b.logarea]
    dialog_chrome $w $b.form.fields.lengths $w.actions.run
    action_bar $w.actions {run cancel batch close}
    update_characterization_ui
}
proc ::analog_lens::characterization_command {output} {
    variable char_edit; variable char_device; variable root
    set model [supported_model $char_device]; set pdk $::analog_lens::char_pdk
    if {$pdk ne [active_pdk]} {error {The active PDK changed. Close and reopen Characterize for the current model.}}
    if {$pdk ni {sky130A gf180mcuD ihp-sg13g2 ihp-sg13cmos5l}} {error {Choose an installed IIC PDK.}}
    set python [auto_execok python3]; if {$python eq {}} {error {Python 3 is missing from the IIC environment.}}
    set normalized [normalized_characterization]
    set lengths [dict get $normalized lengths]; set clean {}
    foreach length $lengths {
        if {$length eq {}} {continue}
        if {[number $length] eq {} || $length <= 0} {error {Lengths must be positive numbers in micrometers.}}
        lappend clean $length
    }
    if {![llength $clean]} {error {Enter at least one length.}}
    set command [list {*}$python -u [file join $root tools characterize.py] --pdk $pdk --model $model --output $output --lengths {*}$clean]
    foreach {key option} {width width temp temp vds vds vsb vsb start vgs-start stop vgs-stop step vgs-step} {
        lappend command --$option [dict get $normalized $key]
    }
    if {![regexp {^[A-Za-z0-9_]+$} $char_edit(corner)]} {error {Use an installed library section name for the corner.}}
    lappend command --corner $char_edit(corner)
    if {[info exists ::env(PDK_ROOT)]} {lappend command --pdk-root $::env(PDK_ROOT)}
    return $command
}
proc ::analog_lens::start_characterization {{batch 0}} {
    variable char_channel; variable char_log; variable char_state; variable char_cancelled
    variable char_output; variable char_project; variable char_pid; variable char_identity; variable char_status
    if {$char_channel ne {}} {error {Characterization is already running.}}
    project_sync
    if {$::analog_lens::project_directory eq {}} {error {Save the testbench to create a project lookup directory.}}
    set char_project $::analog_lens::project_key
    set model [supported_model $::analog_lens::char_device]
    set directory [file join $::analog_lens::project_directory .analog-lens lookups "$model-[clock milliseconds]"]
    set char_output [file join $directory lookup.csv]
    if {$batch} {set command [batch_command $char_output]} else {set command [characterization_command $char_output]}
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
        set rows [parse_lut [read_text $::analog_lens::char_output]]
        if {[lindex [project_identity] 0] eq $::analog_lens::char_project} {
            set ::analog_lens::lut_rows $rows; set ::analog_lens::lut_file $::analog_lens::char_output
            set ::analog_lens::lut_slice [get [lindex $rows 0] slice]
            rebuild_lookup_filters; set ::analog_lens::lookup_match_key {}; auto_select_lookup; project_flush
            set char_status "Loaded [llength $rows] measured samples. CSV and provenance: $::analog_lens::char_output"
        } else {set char_status "Complete. Project changed; load $::analog_lens::char_output when you return."}
        set char_state completed
    } why]} {
        append char_log "\n$::errorInfo\n"
        set char_state failed; set char_status "Generated lookup could not be loaded: $why"
    }
    refresh_results_if_open
    update_characterization_ui
}
proc ::analog_lens::update_characterization_ui {} {
    set idle [expr {$::analog_lens::char_channel eq {}}]
    foreach dialog {characterize batch} {
        set w $::analog_lens::window.$dialog
        if {![winfo exists $w]} {continue}
        set b $w.page.canvas.content
        set_enabled $w.actions.run $idle
        set_enabled $w.actions.cancel [expr {!$idle && !$::analog_lens::char_cancelled}]
        set fields [expr {$dialog eq "batch" ? "corners temps vds vsb" : "lengths width corner temp vds vsb start stop step"}]
        foreach key $fields {set_enabled $b.form.fields.$key $idle}
        foreach name {save load batch} {set_enabled $w.actions.$name $idle}
        set_enabled $b.form.conditions $idle
        $w.actions.run configure -text [expr {$idle ? ($dialog eq "batch" ? "Run / resume batch" : "Generate lookup") : "Running…"}]
        $b.status configure -style [expr {$::analog_lens::char_error || $::analog_lens::char_state eq "failed" ? "AL.Error.TLabel" : "AL.TLabel"}]
        if {$idle} {$b.progress stop; pack forget $b.progress} else {
            if {![winfo ismapped $b.progress]} {pack $b.progress -in $w.page.canvas.content -before $b.logarea -fill x -padx 12 -pady 6; $b.progress start}
        }
        set position [$b.log yview]; set follow [expr {[lindex $position 1] >= .99}]
        $b.log configure -state normal; $b.log delete 1.0 end; $b.log insert end $::analog_lens::char_log; $b.log configure -state disabled
        if {$follow} {$b.log see end} else {$b.log yview moveto [lindex $position 0]}
    }
}

namespace eval ::analog_lens {
    variable batch_edit
    array set batch_edit {corners {} temps {27 85} vds {} vsb 0}
}
proc ::analog_lens::batch_command {output} {
    variable char_edit; variable batch_edit
    # Validate shared geometry/sweep fields with the single-job command first.
    set single [characterization_command $output]
    set normalized [normalized_characterization]
    set command [list {*}[auto_execok python3] -u [file join $::analog_lens::root tools batch_characterize.py] \
        --pdk $::analog_lens::char_pdk --model [supported_model $::analog_lens::char_device] \
        --output $output --cache [file join $::analog_lens::project_directory .analog-lens cache] \
        --lengths {*}[dict get $normalized lengths]]
    foreach {key option} {width width start vgs-start stop vgs-stop step vgs-step} {lappend command --$option [dict get $normalized $key]}
    foreach {key option} {corners corners temps temps vds vds-values vsb vsb-values} {
        set values $batch_edit($key)
        if {$key ne "corners"} {set values [quantity_list $values [expr {$key eq "temps" ? "temperature" : "voltage"}]]}
        if {![llength $values]} {error "Enter at least one $key value."}
        foreach value $values {
            if {$key eq "corners"} {
                if {![regexp {^[A-Za-z0-9_]+$} $value]} {error {Use installed library section names for corners.}}
            } elseif {[number $value] eq {}} {error "$key values must be finite numbers."}
        }
        lappend command --$option {*}$values
    }
    if {[info exists ::env(PDK_ROOT)]} {lappend command --pdk-root $::env(PDK_ROOT)}
    return $command
}
proc ::analog_lens::batch_preset {action} {
    set w $::analog_lens::window.batch
    if {$action eq "save"} {
        batch_command [file join $::analog_lens::project_directory validation-only.csv]
        set path [tk_getSaveFile -parent $w -defaultextension .albatch -initialfile characterization.albatch]
        if {$path ne {}} {atomic_write $path [dict create format analog-lens-batch-preset schema 1 pdk $::analog_lens::char_pdk \
            model [supported_model $::analog_lens::char_device] shared [array get ::analog_lens::char_edit] grid [array get ::analog_lens::batch_edit]]}
    } else {
        set path [tk_getOpenFile -parent $w -filetypes {{{Batch preset} .albatch}}]
        if {$path eq {}} {return}
        if {[file size $path] > 100000} {error {Batch preset is too large.}}
        set data [read_text $path]
        if {[get $data format] ne "analog-lens-batch-preset" || [get $data schema] ne "1" || [get $data pdk] ne $::analog_lens::char_pdk ||
            [get $data model] ne [supported_model $::analog_lens::char_device]} {error {Preset must match the selected PDK and model.}}
        set old_shared [array get ::analog_lens::char_edit]; set old_grid [array get ::analog_lens::batch_edit]
        try {
            foreach key [array names ::analog_lens::char_edit] {set ::analog_lens::char_edit($key) [dict get $data shared $key]}
            foreach key [array names ::analog_lens::batch_edit] {set ::analog_lens::batch_edit($key) [dict get $data grid $key]}
            batch_command [file join $::analog_lens::project_directory validation-only.csv]
        } on error {why options} {
            array set ::analog_lens::char_edit $old_shared; array set ::analog_lens::batch_edit $old_grid
            return -options $options $why
        }
    }
}
proc ::analog_lens::batch_dialog {} {
    characterize_dialog
    set w $::analog_lens::window.batch
    if {[winfo exists $w]} {raise $w; return}
    set ::analog_lens::batch_edit(corners) $::analog_lens::char_edit(corner)
    set ::analog_lens::batch_edit(vds) $::analog_lens::char_edit(vds)
    toplevel $w; wm title $w {Characterization batch · Analog Lens}; wm geometry $w 720x580; wm minsize $w 560 460
    set b [dialog_page $w]
    ttk::frame $b.form -padding 12; pack $b.form -fill x
    pack [label $b.form.title {PVT and bias grid} AL.Heading.TLabel] -anchor w
    ttk::label $b.form.note -text {Enter space-separated values. Every combination uses the lengths, reference width and gate sweep in the Characterize window. Completed conditions are cached; repeat the request to resume after cancellation.} -wraplength 650
    pack $b.form.note -fill x -pady 10
    ttk::frame $b.form.fields; pack $b.form.fields -fill x
    set row 0
    foreach {key title} {corners {Installed corner sections} temps {Temperatures (°C)} vds {Vds values (V; signed)} vsb {Vsb values (V)}} {
        ttk::label $b.form.fields.l$key -text $title
        if {$key eq "corners"} {
            ttk::combobox $b.form.fields.$key -textvariable ::analog_lens::batch_edit($key) -values [characterization_corners] -width 36
        } else {ttk::entry $b.form.fields.$key -textvariable ::analog_lens::batch_edit($key) -width 36}
        grid $b.form.fields.l$key -row $row -column 0 -sticky w -padx {0 12} -pady 6
        grid $b.form.fields.$key -row $row -column 1 -sticky ew; incr row
    }
    grid columnconfigure $b.form.fields 1 -weight 1
    ttk::frame $w.actions -padding 12; pack $w.actions -before $w.page -side bottom -fill x
    foreach {name title command} {
        run {Run / resume batch} {::analog_lens::characterization_action {::analog_lens::start_characterization 1}}
        cancel Cancel ::analog_lens::cancel_characterization
        save {Save preset…} {::analog_lens::batch_preset save}
        load {Load preset…} {::analog_lens::batch_preset load}
    } {pack [button $w.actions.$name $title $command] -side left -padx 3}
    ttk::label $b.status -textvariable ::analog_lens::char_status -wraplength 650 -padding 12; pack $b.status -side bottom -fill x
    text $b.log -wrap word -state disabled; text_style $b.log 1; pack $b.log -fill both -expand 1 -padx 12
    pack [button $w.actions.close Close [list ::analog_lens::close_dialog $w]] -side right
    wrapping $b.form.title; wrapping $b.form.note; wrapping $b.status
    log_area $b
    ttk::progressbar $b.progress -mode indeterminate
    dialog_content [list $b.form $b.status $b.logarea]
    dialog_chrome $w $b.form.fields.corners $w.actions.run
    action_bar $w.actions {run cancel save load close}
    update_characterization_ui
}
