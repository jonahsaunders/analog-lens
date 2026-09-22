namespace eval ::analog_lens {
    variable records {}; variable index {}; variable sample 0; variable dataset 0
    variable status {Open a schematic, then run Operating point or load a raw file.}
    variable active_context {}; variable run_channel {}; variable run_log {}; variable run_file {}
    variable run_context {}; variable run_devices {}; variable snapshot {}; variable snapshot_context {}
    variable live 1; variable timer {}; variable selected {}; variable search {}; variable only_review 0
    variable analysis_type op; variable run_started 0
}
proc ::analog_lens::raw {args} {
    # xschem 3.4 uses `raw`; older builds expose the read-only `raw_query` API.
    if {![catch {xschem raw {*}$args} result]} {return $result}
    if {[lindex $args 0] in {list value values loaded points rawfile sim_type datasets}} {
        return [xschem raw_query {*}$args]
    }
    error $result
}
proc ::analog_lens::context {} {
    return [list [xschem get current_win_path] [xschem get current_name] [xschem get sch_path]]
}
proc ::analog_lens::property {inst names} {
    foreach name $names {
        if {![catch {xschem getprop instance $inst $name} v] && $v ne {}} {return $v}
    }
    return {}
}
proc ::analog_lens::scan {{hierarchy __AUTO__}} {
    if {$hierarchy eq "__AUTO__"} {set hierarchy {}; catch {set hierarchy [xschem get sim_sch_path]}}
    set result {}
    for {set i 0} {$i < [xschem get instances]} {incr i} {
        set name [property $i {name}]
        set symbol [property $i {cell::name}]
        set type [property $i {cell::type}]
        if {$type eq {}} {catch {set type [xschem getprop symbol $symbol type]}}
        if {![regexp {^(nmos|pmos|npn|pnp|vertical_npn|vertical_pnp)$} $type]} {continue}
        if {[property $i {spice_ignore}] eq "true"} {continue}
        set model [property $i {model}]
        catch {set model [xschem translate $name @model]}
        set prefix [property $i {spiceprefix}]
        if {$prefix eq {}} {catch {set prefix [xschem translate $name @spiceprefix]}}
        if {$prefix eq "@spiceprefix"} {set prefix {}}
        set names [list $name]
        if {![catch {xschem expandlabel $name} ex] && [lindex $ex 1] > 1} {set names [split [lindex $ex 0] ,]}
        foreach expanded $names {
            lappend result [dict create name $expanded owner $name inst $i type $type model $model \
                symbol $symbol prefix $prefix hierarchy $hierarchy family [family $symbol $model] \
                width [property $i {W w}] length [property $i {L l}] \
                fingers [property $i {nf ng}] multiplier [property $i {mult m}]]
        }
    }
    return $result
}
proc ::analog_lens::measure {device} {
    variable index; variable sample; variable dataset
    set resolution [resolve_vectors $device $index]
    set values {}
    dict for {metric vector} [dict get $resolution vectors] {
        if {![catch {raw value $vector $sample $dataset} value]} {dict set values $metric [number $value]}
    }
    set out [dict merge $device $resolution]
    dict set out values [metrics $values [get $device family] [get $device type]]
    return $out
}
proc ::analog_lens::refresh {} {
    variable records; variable index; variable status; variable active_context; variable sample; variable dataset
    variable run_channel
    if {$run_channel ne {}} {return}
    set records {}; set active_context [context]
    if {[raw loaded] < 0} {error "No simulation results are loaded. Click Operating point, or Load results."}
    set type [raw sim_type]
    if {$type ni {op dc tran}} {error "Device analysis needs real OP, DC or transient data. The current plot is '$type'."}
    if {![string is integer -strict $sample] || $sample < 0 || ![string is integer -strict $dataset] || $dataset < 0} {error "Sample and dataset must be nonnegative integers."}
    if {$dataset >= [raw datasets]} {error "Dataset is outside the loaded results."}
    if {$sample >= [raw points $dataset]} {error "Sample is outside the loaded results."}
    set index [vector_index [raw list]]
    foreach device [scan] {lappend records [measure $device]}
    capture_result_metadata
    set reviews 0; set missing 0
    foreach r $records {
        if {[get [get $r values] status] eq "Review"} {incr reviews}
        if {[get [get $r values] gm] eq {}} {incr missing}
    }
    set status "[llength $records] devices at this hierarchy level · $reviews to review · $type, sample $sample, dataset $dataset"
    if {$missing} {append status " · $missing missing gm (rerun Operating point)"}
    if {[llength [info commands ::analog_lens::render]]} {render}
}
proc ::analog_lens::load_results {} {
    variable sample; variable dataset; variable analysis_type
    set file [tk_getOpenFile -parent $::analog_lens::window -title {Load ngspice simulation results} -filetypes {{{SPICE results} {.raw}} {{All files} *}}]
    if {$file eq {}} {return}
    read_results $file $analysis_type
    set sample 0; set dataset 0
    refresh
}
proc ::analog_lens::read_results {file type} {
    if {![file isfile $file] || [file size $file] == 0} {error "Results file is missing or empty: $file"}
    raw read $file $type
    if {[raw loaded] < 0 || [file normalize [raw rawfile]] ne [file normalize $file] || [raw sim_type] ne $type} {
        error "xschem did not load the requested $type plot. Existing results were not analyzed as new data."
    }
    set ::analog_lens::result_metadata {}
    set sidecar [file rootname $file].metadata
    if {[file isfile $sidecar] && [file size $sidecar] < 1000000} {
        if {![catch {set metadata [read_text $sidecar]; validate_metadata $metadata}] &&
            [get $metadata raw] eq [file_signature $file] && [get $metadata analysis] eq $type} {
            set ::analog_lens::result_metadata $metadata
        }
    }
}
proc ::analog_lens::walk_devices {{depth 0}} {
    if {$depth > 48} {error "Hierarchy exceeds 48 levels; check for recursive symbols."}
    set hierarchy [string trimleft [xschem get sch_path] .]
    set result [scan $hierarchy]
    set count [xschem get instances]
    for {set i 0} {$i < $count} {incr i} {
        if {[property $i {cell::type}] ne "subcircuit" || [property $i {spice_ignore}] eq "true"} {continue}
        # A custom netlisting format may replace the implementation completely.
        if {[property $i {spice_sym_def}] ne {}} {continue}
        set name [property $i {name}]
        set copies 1
        catch {set copies [lindex [xschem expandlabel $name] 1]}
        if {![string is integer -strict $copies] || $copies < 1} {set copies 1}
        set base [xschem get currsch]
        xschem unselect_all
        xschem select instance $i
        try {
            set ok [xschem descend 1 2]
            if {!$ok} {error "Cannot read subcircuit $name. Check its schematic before running analysis."}
            for {set n 1} {$n <= $copies} {incr n} {
                if {$n > 1} {xschem change_sch_path $n}
                lappend result {*}[walk_devices [expr {$depth+1}]]
            }
        } finally {
            while {[xschem get currsch] > $base} {xschem go_back 2}
        }
    }
    return $result
}
proc ::analog_lens::collect_devices {} {
    set selected [xschem selected_set]
    set keep_exists [info exists ::keep_symbols]
    if {$keep_exists} {set saved_keep $::keep_symbols}
    set ::keep_symbols 1
    try {return [walk_devices]} finally {
        if {$keep_exists} {set ::keep_symbols $saved_keep} else {unset ::keep_symbols}
        xschem unselect_all
        foreach inst $selected {catch {xschem select instance $inst}}
        xschem redraw
    }
}
proc ::analog_lens::op_deck {original saves rawfile} {
    # Preserve model includes, parameters, sources, and hierarchy. Replace only
    # top-level simulator controls and analyses in this disposable copied deck.
    set out {}; set control 0; set subckt 0; set skip_plus 0
    foreach line [split $original \n] {
        set trimmed [string trim $line]
        if {[regexp -nocase {^\.control(?:\s|$)} $trimmed]} {set control 1; continue}
        if {[regexp -nocase {^\.endc(?:\s|$)} $trimmed]} {set control 0; continue}
        if {$control} {continue}
        if {[regexp -nocase {^\.subckt(?:\s|$)} $trimmed]} {incr subckt}
        if {[regexp -nocase {^\.ends(?:\s|$)} $trimmed]} {incr subckt -1}
        if {$skip_plus && [string match +* $trimmed]} {continue}
        set skip_plus 0
        if {!$subckt && [regexp -nocase {^\.(op|ac|dc|tran|noise|pz|tf|sens|four|save|end)(?:\s|$)} $trimmed]} {set skip_plus 1; continue}
        append out $line \n
    }
    if {$control || $subckt} {error "Unbalanced .control or .subckt in generated netlist."}
    if {[regexp {["\n\r]} $rawfile]} {error "Simulation path cannot contain quotes or newlines."}
    append out "\n* Analog Lens isolated operating-point analysis\n$saves\n.control\nset filetype=ascii\nop\nwrite \"$rawfile\"\nquit\n.endc\n.end\n"
    return $out
}
proc ::analog_lens::run_op {} {
    variable run_channel; variable run_log; variable run_file; variable run_context; variable status
    variable run_devices; variable run_started
    variable run_cancelled; variable run_processes; variable run_state
    variable run_metadata
    if {$run_channel ne {}} {error "An operating-point run is already in progress."}
    if {[xschem get currsch] != 0} {error "Return to the top-level testbench before running Operating point. You can inspect results inside any hierarchy afterward."}
    if {[xschem get netlist_type] ne "spice"} {error "Select SPICE netlisting in xschem first. This version runs ngspice."}
    set binary [auto_execok ngspice]
    if {$binary eq {}} {error "ngspice is not on PATH. Run xschem inside IIC-OSIC-TOOLS."}
    set run_context [context]
    set run_devices [collect_devices]
    if {![llength $run_devices]} {error "No supported transistor symbols were found in this testbench."}
    set directory [file normalize $::netlist_dir]
    file mkdir $directory
    # Every run gets new files, so a failed run cannot load stale results.
    set stem "[file rootname [file tail [xschem get current_name]]].analog-lens-[clock milliseconds]"
    set original [file join $directory ${stem}-source.spice]
    set deck [file join $directory ${stem}.spice]
    set run_file [file join $directory ${stem}.raw]
    xschem netlist $original
    if {![file isfile $original]} {error "xschem did not generate the analysis netlist."}
    write_text $deck [op_deck [read_text $original] [save_lines $run_devices] $run_file]
    set run_metadata [dict merge [capture_metadata] [dict create analysis op sample 0 dataset 0 \
        run_context $run_context raw [file_signature $run_file] input_deck [file_signature $deck] \
        input_crc32 [format %08x [zlib crc32 [read_text $deck]]]]]
    set run_log {}; set run_started [clock seconds]; set run_cancelled 0; set run_processes {}
    set previous [pwd]
    try {
        cd $directory
        set run_channel [open [list | {*}$binary -b $deck 2>@1] r]
    } finally {cd $previous}
    foreach id [pid $run_channel] {dict set run_processes $id [lindex [process_identity $id] 0]}
    set run_state running
    fconfigure $run_channel -blocking 0 -buffering none -encoding utf-8
    fileevent $run_channel readable ::analog_lens::run_readable
    set status {Running ngspice operating point… You can keep working in xschem.}
    if {[llength [info commands ::analog_lens::update_run_controls]]} {update_run_controls}
}
proc ::analog_lens::run_readable {} {
    variable run_channel; variable run_log; variable run_file; variable run_context; variable status
    variable sample; variable dataset
    variable run_cancelled; variable run_cancel_timer; variable run_processes; variable run_state
    variable run_metadata; variable result_metadata
    if {$run_channel eq {}} {return}
    if {[catch {read $run_channel} chunk]} {set chunk "\n$chunk"}
    append run_log $chunk
    # Keep the GUI log bounded while preserving the end containing diagnostics.
    if {[string length $run_log] > 2000000} {set run_log [string range $run_log end-1999999 end]}
    if {![eof $run_channel]} {return}
    set ch $run_channel; set run_channel {}
    fileevent $ch readable {}
    fconfigure $ch -blocking 1
    set failed [catch {close $ch} why]
    if {$run_cancel_timer ne {}} {after cancel $run_cancel_timer; set run_cancel_timer {}}
    set run_processes {}
    if {$run_cancelled} {
        set run_state cancelled
        append run_log "\nCancelled by the user. Partial results were not loaded.\n"
        set status {Run cancelled. Previous loaded results are unchanged. Adjust the circuit and run again.}
    } elseif {$failed || ![file exists $run_file] || [file size $run_file] == 0 || [regexp -nocase {(?m)^(fatal error|error:|doanalyses:)} $run_log]} {
        set run_state failed
        set status {Operating point failed. Open Run log for ngspice's error.}
        if {$failed} {append run_log "\n$why"}
    } elseif {[context] ne $run_context} {
        set run_state completed
        set status "Run finished. Return to the original testbench and load $run_file"
    } elseif {[catch {read_results $run_file op; set sample 0; set dataset 0; refresh} why]} {
        set run_state failed
        set status "Could not load results: $why"
    } else {set run_state completed}
    catch {write_text [file rootname $run_file].log $run_log}
    if {[file exists $run_file] && !$run_cancelled} {
        set metadata [dict merge $run_metadata [dict create raw [file_signature $run_file] run_state $run_state]]
        catch {atomic_write [file rootname $run_file].metadata $metadata}
        if {$run_state eq "completed" && [context] eq $run_context} {set result_metadata $metadata}
    }
    if {[llength [info commands ::analog_lens::update_run_controls]]} {update_run_controls}
}
proc ::analog_lens::export_report {filename} {
    variable records; variable active_context; variable sample; variable dataset
    set out [csv_row {instance model family hierarchy width length fingers multiplier sample dataset id_A gm_S gds_S gmid_1_V intrinsic_gain ro_ohm vgs_V vds_V headroom_V cgg_total_F ft_est_Hz status notes raw_file metadata}]
    append out \n
    foreach r $records {
        set v [get $r values]
        set row [list [get $r name] [get $r model] [get $r family] [get $r hierarchy] \
            [get $r width] [get $r length] [get $r fingers] [get $r multiplier] $sample $dataset]
        foreach key {id gm gds gmid gain ro vgs vds headroom cgg_total ft status} {lappend row [get $v $key]}
        lappend row [join [get $v issues] {; }] [raw rawfile]
        lappend row $::analog_lens::result_metadata
        append out [csv_row $row] \n
    }
    write_text $filename $out
}
proc ::analog_lens::annotation {name} {
    # Called by the optional annotation symbol; reads current loaded data.
    variable records
    foreach r $records {
        if {[get $r name] eq $name} {
            set v [get $r values]
            return "gm/Id = [eng [get $v gmid] 1/V]\ngm/gds = [eng [get $v gain]]\nId = [eng [get $v id] A]\nmargin = [eng [get $v headroom] V]"
        }
    }
    return {Open Analog Lens and refresh}
}
