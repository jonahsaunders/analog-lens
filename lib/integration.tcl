# Native xschem integration. Host commands are observed, never replaced.
namespace eval ::analog_lens {
    variable integration_options [dict create follow_cursor 0 auto_results 1 device_saves 1 auto_lookup 1 result_path {} result_analysis auto]
    variable integration_timer {}; variable integration_started 0; variable integration_internal 0
    variable project_key {}; variable project_directory {}; variable project_message {Open a saved testbench.}
    variable project_defaults {}; variable project_memory {}; variable project_saved {}; variable project_blocked {}
    variable project_last_save 0; variable edit_revisions {}; variable edit_traces {}
    variable native_stack {}; variable native_jobs {}; variable native_pending {}; variable native_message {}
    variable netlist_states {}
    variable sidebar {}; variable sidebar_title {Select a transistor}; variable sidebar_metrics {}
    variable freshness_state unverified; variable native_result_state idle
    variable freshness {Results not verified against this schematic}; variable cursor_message {}; variable cursor_key {}
    variable sidebar_open 0; variable sidebar_owner {}; variable integration_watch {}
}
proc ::analog_lens::project_identity {} {
    set top {}; catch {set top [xschem get schname 0]}
    if {$top eq {} || ![file isfile $top]} {return {}}
    set top [file normalize $top]; set directory [file dirname $top]
    set search $directory
    while {1} {
        if {[file isfile [file join $search xschemrc]]} {set directory $search; break}
        set parent [file dirname $search]; if {$parent eq $search} {break}; set search $parent
    }
    return [list $top $directory]
}
proc ::analog_lens::project_session_path {key directory} {
    set name [regsub -all {[^A-Za-z0-9_.-]} [file rootname [file tail $key]] _]
    return [file join $directory .analog-lens sessions "$name-[format %08x [zlib crc32 $key]].alsession"]
}
proc ::analog_lens::project_flush {} {
    variable project_key; variable project_directory; variable project_memory; variable project_saved; variable project_blocked
    variable project_message; variable project_last_save
    if {$project_key eq {}} {return}
    set data [session_data]; dict set data project_source $project_key
    dict set project_memory $project_key $data
    if {[dict exists $project_blocked $project_key] || [get $project_saved $project_key] eq $data} {return}
    set path [project_session_path $project_key $project_directory]
    if {[catch {file mkdir [file dirname $path]; atomic_write $path "$data\n"} why]} {
        set project_message "Session kept in memory; could not save: $why"; return
    }
    dict set project_saved $project_key $data
    set project_last_save [clock milliseconds]
    set project_message "[file tail $project_key] · Session autosaved"
}
proc ::analog_lens::project_sync {} {
    variable project_key; variable project_directory; variable project_defaults; variable project_memory
    variable project_saved; variable project_blocked; variable project_message; variable records; variable result_metadata
    variable run_channel; variable integration_options; variable project_last_save
    if {$run_channel ne {}} {return}
    lassign [project_identity] key directory
    if {$key eq $project_key} {return}
    project_flush
    if {$project_defaults eq {}} {set project_defaults [session_data]}
    set project_key $key; set project_directory $directory
    set ::analog_lens::verification_result {}; set ::analog_lens::verification_summary {}; set ::analog_lens::verification_advice {}; set ::analog_lens::dependency_cache {}; set ::analog_lens::native_result_state idle
    set records {}; set result_metadata {}; set ::analog_lens::active_context {}; set ::analog_lens::watch_key {}
    set data $project_defaults; set path {}
    if {$key ne {}} {
        set path [project_session_path $key $directory]
        if {[dict exists $project_memory $key]} {
            set data [dict get $project_memory $key]
        } elseif {[file isfile $path]} {
            if {[catch {
                if {[file size $path] > 20000000} {error {Session exceeds 20 MB.}}
                set candidate [validate_session [read_text $path]]
                if {[get $candidate project_source] ne $key} {error {Session belongs to a different testbench.}}
                set data $candidate
            } why]} {
                dict set project_blocked $key $why
                set data $project_defaults
            }
        }
    }
    if {[catch {apply_session_data $data $path} why]} {
        if {$key ne {}} {dict set project_blocked $key $why}
        apply_session_data $project_defaults {}
    }
    set ::analog_lens::cursor_key {}; set ::analog_lens::integration_watch {}
    set project_last_save [clock milliseconds]
    if {$key eq {}} {set project_message {Save the testbench to enable project memory.}} elseif {[dict exists $project_blocked $key]} {
        set project_message "Session needs attention: [dict get $project_blocked $key]. Original file preserved."
    } else {set project_message "[file tail $key] · Project session restored"}
}
proc ::analog_lens::design_stamp {} {
    set identity [project_identity]; set key [lindex $identity 0]
    set revision [get $::analog_lens::edit_revisions $key 0]
    return [dict create project $key revision $revision file [file_signature $key]]
}
proc ::analog_lens::note_design_edit {args} {
    if {$::analog_lens::integration_internal} {return}
    if {[catch {xschem get modified} modified] || $modified != 1} {return}
    set key [lindex [project_identity] 0]
    if {$key ne {}} {dict incr ::analog_lens::edit_revisions $key}
}
proc ::analog_lens::watch_design_edits {} {
    set var ::tctx::[xschem get current_win_path]_netlist
    if {![namespace exists ::tctx] || [lsearch -exact [trace info variable $var] {write ::analog_lens::note_design_edit}] >= 0} {return}
    trace add variable $var write ::analog_lens::note_design_edit
    dict set ::analog_lens::edit_traces $var 1
}
proc ::analog_lens::update_freshness {} {
    set saved [get $::analog_lens::result_metadata design_stamp]
    if {$saved eq {}} {
        set ::analog_lens::freshness_state unverified
        set ::analog_lens::freshness {Source state unverified · Run the testbench to verify.}
    } elseif {$saved ne [design_stamp]} {
        set ::analog_lens::freshness_state stale
        set ::analog_lens::freshness {Out of date · Schematic changed; rerun before relying on these values.}
    } else {set ::analog_lens::freshness_state current; set ::analog_lens::freshness {Current · Results match the recorded schematic state.}}
    set deps [dependency_status]
    switch -- [get $deps state] {
        changed {set ::analog_lens::freshness_state stale; set ::analog_lens::freshness {Out of date · A schematic, symbol or model dependency changed.}}
        partial {append ::analog_lens::freshness { · Some dependencies unresolved.}}
        unverified {append ::analog_lens::freshness { · Dependencies unverified.}}
    }
    set ::analog_lens::conditions_confidence [condition_confidence [current_device]]
    if {$::analog_lens::verification_result ne {} && [get $::analog_lens::verification_result current] && $::analog_lens::freshness_state eq "stale"} {
        dict set ::analog_lens::verification_result current 0
        set ::analog_lens::verification_summary {Previous sizing verdict is out of date · Rerun the updated circuit.}
        update_verification_text
    }
}
proc ::analog_lens::raw_signature {path} {
    set sig [file_signature $path]
    if {![file isfile $path]} {return $sig}
    set f [open $path rb]
    try {
        set prefix [read $f 65536]
        if {[file size $path] > 65536} {seek $f -65536 end; append prefix [read $f]}
        dict set sig edge_crc32 [zlib crc32 $prefix]
    } finally {close $f}
    return $sig
}
proc ::analog_lens::native_paths {} {
    if {![info exists ::netlist_dir]} {error {Set xschem's netlist directory first.}}
    set directory [file normalize $::netlist_dir]
    set name {}; catch {set name [xschem get netlist_name]}
    if {$name eq {}} {set name [file rootname [file tail [xschem get schname 0]]].spice}
    if {[file extension $name] ne ".spice"} {set name [file rootname $name].spice}
    return [list $directory [file join $directory $name]]
}
proc ::analog_lens::native_deck {original saves} {
    # The generated deck is disposable; original schematic/control commands stay intact.
    regsub -all {(?s)\n\* BEGIN ANALOG LENS SAVES\n.*?\* END ANALOG LENS SAVES\n} $original \n original
    set block "\n* BEGIN ANALOG LENS SAVES\n.save all\n$saves\n* END ANALOG LENS SAVES\n"
    set lines [split $original \n]; set insert 1
    # Insert after the SPICE title, before controls can start an analysis.
    return [join [linsert $lines $insert [string trim $block \n]] \n]
}
proc ::analog_lens::observe_netlist {command code result operation} {
    if {[lindex $command 1] ne "netlist" || $code || $result eq "1"} {return}
    # Record the source when the deck is generated, not when Simulate is
    # clicked: Simulate alone can run an old deck after schematic edits.
    catch {
        if {[xschem get currsch] != 0} {return}
        lassign [native_paths] directory deck
        foreach arg [lrange $command 2 end] {
            if {[string match -* $arg]} {continue}
            if {[file pathtype $arg] eq "relative"} {set arg [file join $directory $arg]}
            if {[file normalize $arg] ne $deck} {return}
            break
        }
        if {[file isfile $deck]} {
            dict set ::analog_lens::netlist_states $deck [dict create signature [raw_signature $deck] stamp [design_stamp]]
        }
    }
}
proc ::analog_lens::native_enter {command operation} {
    # A trace must never interrupt the user's simulator or callback.
    set job {}
    if {[catch {
        if {[get $::analog_lens::integration_options auto_results] && [xschem get netlist_type] eq "spice" && [xschem get currsch] == 0} {
            project_sync
            lassign [native_paths] directory deck
            set stamp {}
            set state [get $::analog_lens::netlist_states $deck]
            if {[get $state signature] eq [raw_signature $deck]} {set stamp [get $state stamp]}
            set before {}; foreach path [glob -nocomplain -directory $directory *.raw] {dict set before $path [raw_signature $path]}
            set configured [get $::analog_lens::integration_options result_path]
            if {$configured ne {}} {
                if {[file pathtype $configured] eq "relative"} {set configured [file join $directory $configured]}
                set configured [file normalize $configured]
                dict set before $configured [raw_signature $configured]
            }
            set options {}; if {$configured ne {}} {set options [list --extra $configured]}
            set before_stamps [project_helper raw-stamps $directory {*}$options]
            set cmd {}; catch {set cmd $::sim(spice,$::sim(spice,default),cmd)}
            if {[get $::analog_lens::integration_options device_saves] && [string match *ngspice* $cmd] && [file isfile $deck]} {
                incr ::analog_lens::integration_internal
                try {
                    set saves [save_lines [collect_devices $deck]]
                    if {$saves ne {}} {atomic_write $deck [native_deck [read_text $deck] $saves]}
                    if {$stamp ne {}} {
                        dict set ::analog_lens::netlist_states $deck signature [raw_signature $deck]
                    }
                } finally {incr ::analog_lens::integration_internal -1}
            }
            set dependencies {}
            if {[file isfile $deck]} {set dependencies [dependency_snapshot $deck]}
            set job [dict create context [context] project $::analog_lens::project_key directory $directory \
                before $before before_stamps $before_stamps preferred $configured default [file rootname $deck].raw \
                analysis [get $::analog_lens::integration_options result_analysis] \
                metadata [recorded_conditions [dict merge [capture_metadata] $dependencies [dict create design_stamp $stamp input_deck [file_signature $deck] source native-simulation]]]]
            set ::analog_lens::native_result_state running; set ::analog_lens::native_message {xschem simulation running… Results will be checked when it finishes.}
        }
    } why]} {set ::analog_lens::native_result_state attachment_failed; set ::analog_lens::native_message "Automatic results unavailable: $why"; set job {}}
    lappend ::analog_lens::native_stack $job
}
proc ::analog_lens::native_leave {command code result operation} {
    set job [lindex $::analog_lens::native_stack end]
    set ::analog_lens::native_stack [lrange $::analog_lens::native_stack 0 end-1]
    if {$job eq {} || $code || ![string is integer -strict $result] || $result < 0} {return}
    dict set ::analog_lens::native_jobs $result $job
    if {[info exists ::execute(pipe,$result)]} {
        trace add variable ::execute(pipe,$result) unset [list ::analog_lens::native_finished $result]
    } else {after idle [list ::analog_lens::native_finished $result]}
}
proc ::analog_lens::native_finished {id args} {
    if {![dict exists $::analog_lens::native_jobs $id]} {return}
    set job [dict get $::analog_lens::native_jobs $id]; dict unset ::analog_lens::native_jobs $id
    if {![info exists ::execute(exitcode,$id)] || $::execute(exitcode,$id) != 0} {
        set ::analog_lens::native_result_state failed; set ::analog_lens::native_message {xschem simulation did not complete successfully; previous results retained.}; verification_failed failed; return
    }
    if {[catch {
        set candidates [glob -nocomplain -directory [dict get $job directory] *.raw]
        set preferred [dict get $job preferred]
        if {$preferred ne {}} {set candidates [list $preferred]}
        set options {}; if {$preferred ne {}} {set options [list --extra $preferred]}
        set stamps [project_helper raw-stamps [dict get $job directory] {*}$options]
        set changed {}
        foreach path $candidates {
            if {![file isfile $path] || [file size $path] == 0} {continue}
            if {[raw_signature $path] ne [get [dict get $job before] $path] ||
                [get $stamps $path] ne [get [get $job before_stamps] $path]} {lappend changed $path}
        }
        set default [dict get $job default]
        if {$preferred eq {} && $default in $changed} {set changed [list $default]}
        if {[llength $changed] != 1} {error {No unique new raw file. Set Result file in Project settings; ensure the testbench writes it.}}
        dict set job raw [lindex $changed 0]
        dict set ::analog_lens::native_pending [dict get $job project] $job
        set ::analog_lens::native_result_state pending; set ::analog_lens::native_message {Run complete · Return to its top-level testbench to attach results.}
        after idle ::analog_lens::attach_native_result
    } why]} {set ::analog_lens::native_result_state attachment_failed; set ::analog_lens::native_message "Results not attached: $why"}
}
proc ::analog_lens::attach_native_result {} {
    set key [lindex [project_identity] 0]
    if {$::analog_lens::run_channel ne {} || ![dict exists $::analog_lens::native_pending $key] || [xschem get currsch] != 0} {return}
    set job [dict get $::analog_lens::native_pending $key]
    if {[lindex [context] 0] ne [lindex [dict get $job context] 0]} {return}
    dict unset ::analog_lens::native_pending $key
    incr ::analog_lens::integration_internal
    try {
        set path [dict get $job raw]; set type [dict get $job analysis]
        if {$type eq "auto"} {set type [raw_plot_type $path]}
        read_results $path $type
        set ::analog_lens::sample 0; set ::analog_lens::dataset 0
        set metadata [dict merge [dict get $job metadata] [dict create raw [raw_signature $path] analysis $type sample 0 dataset 0]]
        set ::analog_lens::result_metadata $metadata
        refresh
        catch {atomic_write [file rootname $path].metadata $metadata}
        finish_result_run
        set ::analog_lens::native_result_state loaded; set ::analog_lens::native_message "Loaded [file tail $path] · $type"
    } on error {why options} {set ::analog_lens::native_result_state attachment_failed; set ::analog_lens::native_message "Could not attach results: $why"} finally {incr ::analog_lens::integration_internal -1}
}
proc ::analog_lens::raw_plot_type {path} {
    set f [open $path rb]
    try {set header [read $f 4096]} finally {close $f}
    if {![regexp -nocase {Plotname:[ \t]*([^\r\n]+)} $header -> plot]} {error {Raw file has no recognizable plot header.}}
    if {[string match -nocase *operating* $plot]} {return op}
    if {[string match -nocase *transient* $plot]} {return tran}
    if {[string match -nocase *dc* $plot]} {return dc}
    error "Unsupported first plot: $plot. Choose OP, DC or transient in Project settings."
}
proc ::analog_lens::run_testbench {} {
    if {$::analog_lens::run_channel ne {}} {error {Wait for the current operating-point run.}}
    if {[xschem get currsch] != 0} {error {Save subcircuit changes and return to the top-level testbench to run.}}
    if {![llength [info commands ::simulate]]} {error {xschem's simulation command is unavailable.}}
    set busy ::tctx::[xschem get current_win_path]_simulate_id
    if {[info exists $busy]} {error {This testbench is already running. Use xschem's Simulate control to stop it.}}
    incr ::analog_lens::integration_internal
    try {xschem netlist} finally {incr ::analog_lens::integration_internal -1}
    ::simulate
}
proc ::analog_lens::nearest_sample {axis target dset} {
    set count [raw points $dset]
    if {$count < 1} {error {This dataset contains no samples.}}
    set lo 0; set hi [expr {$count-1}]
    set first [raw value $axis 0 $dset]; set last [raw value $axis $hi $dset]
    if {[number $first] eq {} || [number $last] eq {} || ($count > 1 && $first == $last)} {error {Cursor needs a monotonic sweep axis.}}
    set ascending [expr {$last >= $first}]
    while {$hi-$lo > 1} {
        set mid [expr {($lo+$hi)/2}]; set value [raw value $axis $mid $dset]
        if {($ascending && $value < $target) || (!$ascending && $value > $target)} {set lo $mid} else {set hi $mid}
    }
    set a [raw value $axis $lo $dset]; set b [raw value $axis $hi $dset]
    return [expr {abs($target-$a) <= abs($target-$b) ? $lo : $hi}]
}
proc ::analog_lens::follow_cursor {} {
    variable cursor_message; variable cursor_key; variable sample; variable dataset
    if {![get $::analog_lens::integration_options follow_cursor] || [raw sim_type] ni {dc tran}} {set cursor_message {}; return}
    set x [xschem get cursor2_x]; set dset $dataset
    set graph {}; catch {set graph [xschem get graph_lastsel]}
    if {[string is integer -strict $graph] && $graph >= 0} {
        set sweep {}; catch {set sweep [xschem getprop rect 2 $graph sweep]}
        if {$sweep ne {} && [lindex $sweep 0] ne [lindex [raw list] 0]} {
            set cursor_message {Cursor not followed: this graph uses a custom sweep axis. Choose saved Sample and Dataset.}; return
        }
        set local {}; catch {set local [xschem getprop rect 2 $graph cursor2_x]}
        if {[number $local] ne {}} {set x $local}
        set choice {}; catch {set choice [xschem getprop rect 2 $graph dataset]}
        if {[string is integer -strict $choice] && $choice >= 0 && $choice < [raw datasets]} {set dset $choice}
        set alternate {}; catch {set alternate [xschem getprop rect 2 $graph rawfile]}
        if {$alternate ne {} && [file normalize $alternate] ne [file normalize [raw rawfile]]} {
            set cursor_message {This graph uses another raw file. Load it before following its cursor.}; return
        }
    }
    if {[number $x] eq {}} {return}
    set axis [lindex [raw list] 0]
    set key [list [raw rawfile] $dset $axis $x]
    if {$key eq $cursor_key} {return}
    set cursor_key $key; set dataset $dset; set sample [nearest_sample $axis $x $dset]
    refresh
    set cursor_message "Cursor B · Nearest saved sample $sample · $axis = [raw value $axis $sample $dset]"
}
proc ::analog_lens::current_device {} {
    set owners [xschem selected_set]
    if {[llength $owners] != 1} {return {}}
    set owner [lindex $owners 0]
    set fresh {}
    foreach r [scan __AUTO__ $owner] {if {[get $r owner] eq $owner} {set fresh $r; break}}
    if {$fresh eq {}} {return {}}
    if {[context] eq $::analog_lens::active_context} {
        foreach r $::analog_lens::records {
            if {[get $r owner] ne $owner} {continue}
            set same 1
            foreach key {model width length fingers multiplier} {if {[get $r $key] ne [get $fresh $key]} {set same 0}}
            if {$same} {return [dict merge $r $fresh]}
        }
    }
    return $fresh
}
proc ::analog_lens::sidebar_action {command} {
    if {[catch {uplevel #0 $command} why]} {set ::analog_lens::native_message $why}
}
proc ::analog_lens::show_sidebar {} {
    variable sidebar; variable sidebar_open
    configure_styles
    set top [xschem get top_path]; set drawing [xschem get current_win_path]
    if {![winfo exists $drawing] || [winfo manager $drawing] ne "pack"} {error {The current xschem drawing does not support the embedded panel. Use Open analysis window.}}
    set parent [dict get [pack info $drawing] -in]
    set base [expr {$parent eq "." ? {} : $parent}]
    set panel $base.analog_lens_panel
    if {$sidebar ne {} && $sidebar ne $panel && [winfo exists $sidebar]} {destroy $sidebar}
    set sidebar $panel; set sidebar_open 1
    if {![winfo exists $panel]} {
        set ::analog_lens::sidebar_metrics {}
        ttk::frame $panel -padding 10 -width 310 -style AL.TFrame
        pack propagate $panel 0
        ttk::frame $panel.head; pack $panel.head -fill x -pady {0 6}
        pack [label $panel.head.title {Analog Lens} AL.Heading.TLabel] -side left
        ttk::button $panel.head.close -text Hide -command ::analog_lens::hide_sidebar -width 5
        pack $panel.head.close -side right
        foreach {name var} {project project_message freshness freshness conditions conditions_confidence verification verification_summary title sidebar_title} {
            ttk::label $panel.$name -textvariable ::analog_lens::$var -wraplength 280 -style AL.Muted.TLabel
            pack $panel.$name -fill x -pady {0 6}
        }
        $panel.title configure -style AL.Heading.TLabel
        ttk::frame $panel.actions; pack $panel.actions -side bottom -fill x -pady {6 0}
        set i 0
        foreach {name title command} {
            run {Run testbench} ::analog_lens::run_testbench
            op {Operating point} ::analog_lens::run_op
            charts {Analysis…} ::analog_lens::show
            size {Size selected…} ::analog_lens::size_selected
            characterize {Characterize…} ::analog_lens::characterize_dialog
            results {Project results…} ::analog_lens::results_dialog
            verify {Sizing verification…} ::analog_lens::verification_dialog
            settings {Project settings…} ::analog_lens::project_settings
        } {
            ttk::button $panel.actions.$name -text $title -command [list ::analog_lens::sidebar_action $command] -width 0
            grid $panel.actions.$name -row [expr {$i/2}] -column [expr {$i%2}] -sticky ew -padx 2 -pady 3
            incr i
        }
        grid columnconfigure $panel.actions {0 1} -weight 1
        ttk::label $panel.native -textvariable ::analog_lens::native_message -wraplength 280 -style AL.Muted.TLabel
        pack $panel.native -side bottom -fill x -pady 6
        ttk::label $panel.cursor -textvariable ::analog_lens::cursor_message -wraplength 280 -style AL.Muted.TLabel
        pack $panel.cursor -side bottom -fill x -pady 4
        text $panel.metrics -wrap word -height 8 -width 30 -state disabled
        text_style $panel.metrics 1
        ttk::scrollbar $panel.scroll -command [list $panel.metrics yview]
        $panel.metrics configure -yscrollcommand [list $panel.scroll set]
        pack $panel.scroll -side right -fill y
        pack $panel.metrics -fill both -expand 1
    }
    pack $panel -in $parent -side right -fill y -before $drawing
    refresh_sidebar
}
proc ::analog_lens::hide_sidebar {} {
    set ::analog_lens::sidebar_open 0
    if {$::analog_lens::sidebar ne {} && [winfo exists $::analog_lens::sidebar]} {destroy $::analog_lens::sidebar}
}
proc ::analog_lens::refresh_sidebar {} {
    variable sidebar; variable sidebar_title; variable sidebar_metrics; variable sidebar_owner
    if {$sidebar eq {} || ![winfo exists $sidebar]} {return}
    set r [current_device]; set text {}
    if {$r eq {}} {set sidebar_title {Select one transistor}; set text {Click a transistor in the schematic to inspect it, size it, or characterize its model.}} else {
        set sidebar_title "[get $r name] · [get $r model]"
        foreach {key title unit} {id Current A gmid {gm/Id} 1/V gm gm S gain Gain V/V headroom Headroom V ft {fT estimate} Hz} {
            append text [format "%-12s %s\n" $title [eng [get [get $r values] $key] $unit]]
        }
        append text "\nW: [get $r width]\nL: [get $r length]\n\n[join [get [get $r values] issues] \n]"
    }
    if {$text ne $sidebar_metrics} {
        $sidebar.metrics configure -state normal; $sidebar.metrics delete 1.0 end
        $sidebar.metrics insert end $text; $sidebar.metrics configure -state disabled; set sidebar_metrics $text
    }
    foreach name {size characterize} {set_enabled $sidebar.actions.$name [expr {$r ne {}}]}
    set_enabled $sidebar.actions.run [expr {$::analog_lens::run_channel eq {}}]
    set_enabled $sidebar.actions.op [expr {$::analog_lens::run_channel eq {}}]
}
proc ::analog_lens::project_settings {} {
    show
    set w $::analog_lens::window.project
    if {[winfo exists $w]} {raise $w; return}
    toplevel $w; wm title $w {Project integration · Analog Lens}; wm transient $w $::analog_lens::window
    set b [dialog_page $w]
    ttk::frame $b.body -padding 16; pack $b.body -fill both -expand 1
    dict for {key value} $::analog_lens::integration_options {set ::analog_lens::integration_edit($key) $value}
    foreach {key title} {auto_results {Attach results after xschem simulations} device_saves {Add device saves to generated ngspice decks} follow_cursor {Follow waveform cursor B (nearest saved point)} auto_lookup {Select compatible lookup curves for the device}} {
        ttk::checkbutton $b.body.$key -text $title -variable ::analog_lens::integration_edit($key)
        pack $b.body.$key -anchor w -pady 4
    }
    pack [label $b.body.resultlabel {Result file (blank = detect; relative paths use netlist directory)}] -fill x -pady {12 4}
    ttk::entry $b.body.result -textvariable ::analog_lens::integration_edit(result_path) -width 58; pack $b.body.result -fill x
    pack [label $b.body.analysislabel {Analysis to load}] -anchor w -pady {8 4}
    ttk::combobox $b.body.analysis -textvariable ::analog_lens::integration_edit(result_analysis) -values {auto op dc tran} -state readonly; pack $b.body.analysis -anchor w
    pack [label $b.body.note {The testbench must write a raw file. Control blocks stay intact. Sessions autosave in the project's .analog-lens folder; an invalid existing session is preserved.} AL.Muted.TLabel] -fill x -pady 12
    $b.body.note configure -wraplength 460
    pack [button $b.body.apply {Apply settings} [list ::analog_lens::apply_project_settings $w]] -anchor e
    ttk::frame $w.actions -padding 12; pack $w.actions -before $w.page -side bottom -fill x
    destroy $b.body.apply
    pack [button $w.actions.apply {Apply settings} [list ::analog_lens::apply_project_settings $w]] -side right
    pack [button $w.actions.cancel Cancel [list ::analog_lens::close_dialog $w]] -side right -padx 8
    wm geometry $w 720x510; wm minsize $w 580 360
    wrapping $b.body.note; wrapping $b.body.resultlabel
    dialog_chrome $w $b.body.auto_results $w.actions.apply
}
proc ::analog_lens::apply_project_settings {w} {
    set next $::analog_lens::integration_options
    foreach key [dict keys $next] {dict set next $key $::analog_lens::integration_edit($key)}
    set data [session_data]; dict set data integration $next; validate_session $data
    set ::analog_lens::integration_options $next; set ::analog_lens::cursor_key {}
    project_flush; close_dialog $w
}
proc ::analog_lens::integration_tick {} {
    set ::analog_lens::integration_timer {}
    if {![llength [info commands xschem]]} {return}
    if {[catch {
        project_sync; watch_design_edits
        if {$::analog_lens::run_channel eq {}} {
            attach_native_result
            set key [list [context] [raw rawfile] [raw sim_type]]
            if {$key ne $::analog_lens::integration_watch} {
                set ::analog_lens::integration_watch $key
                if {[catch {refresh} why]} {set ::analog_lens::status $why}
            }
            if {[catch {follow_cursor} why]} {set ::analog_lens::cursor_message $why}
            if {[get $::analog_lens::integration_options auto_lookup]} {auto_select_lookup}
        }
        update_freshness
        refresh_workspace
        if {$::analog_lens::sidebar_open} {
            set host [xschem get top_path].analog_lens_panel
            if {$::analog_lens::sidebar ne $host || ![winfo exists $host]} {show_sidebar}
            refresh_sidebar
        }
        if {[clock milliseconds]-$::analog_lens::project_last_save > 2000} {project_flush; set ::analog_lens::project_last_save [clock milliseconds]}
    } why]} {set ::analog_lens::native_message "Integration: $why"}
    set ::analog_lens::integration_timer [after 400 ::analog_lens::integration_tick]
}
proc ::analog_lens::integration_exit {args} {catch {project_flush}}
proc ::analog_lens::start_integration {} {
    if {$::analog_lens::integration_started} {return}
    set ::analog_lens::integration_started 1
    set ::analog_lens::project_defaults [session_data]
    trace add execution ::xschem leave ::analog_lens::observe_netlist
    if {[llength [info commands ::simulate]]} {
        trace add execution ::simulate enter ::analog_lens::native_enter
        trace add execution ::simulate leave ::analog_lens::native_leave
    }
    trace add execution ::exit enter ::analog_lens::integration_exit
    integration_tick
    catch {show_sidebar}
}
