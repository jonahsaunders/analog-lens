# Session files are versioned Tcl dictionaries, parsed as data and never sourced.
namespace eval ::analog_lens {
    variable baselines {}; variable baseline_name {}; variable baseline_choice {}
    variable snapshot_metadata {}; variable session_path {}; variable session_geometry {}; variable session_sash {}
    variable comparison_rows {}
}
proc ::analog_lens::context_key {ctx} {
    if {[llength $ctx] != 3} {return $ctx}
    return [list [file normalize [lindex $ctx 1]] [lindex $ctx 2]]
}
proc ::analog_lens::atomic_write {path text} {
    set temp "${path}.[pid].[clock clicks].tmp"
    set f [open $temp {WRONLY CREAT EXCL} 0600]
    try {
        fconfigure $f -encoding utf-8 -translation lf
        puts -nonewline $f $text
        close $f; set f {}
        file rename -force $temp $path
    } finally {
        if {$f ne {}} {catch {close $f}}
        if {[file exists $temp]} {file delete $temp}
    }
}
proc ::analog_lens::validate_metadata {data} {
    dict size $data
    foreach key {temp_c vds_v vsb_v} {
        set value [get $data $key]
        if {$value ne {} && [number $value] eq {}} {error "Invalid session metadata: $key."}
    }
    foreach key {raw schematic} {if {[dict exists $data $key]} {dict size [dict get $data $key]}}
}
proc ::analog_lens::validate_session {data} {
    if {[get $data format] ne "analog-lens-session" || [get $data schema] ne "1"} {error "Unsupported Analog Lens session format."}
    set limits [dict get $data limits]
    foreach key {gmid_min gmid_max headroom_min current_floor} {
        set n [number [dict get $limits $key]]
        if {$n eq {} || $n < 0} {error "Invalid session target: $key."}
    }
    if {[dict get $limits gmid_min] >= [dict get $limits gmid_max]} {error "Invalid session gm/Id range."}
    validate_metadata [dict get $data declared]
    foreach key {corner temp_c vds_v vsb_v} {dict get $data declared $key}
    set bases [dict get $data baselines]; dict size $bases
    dict for {name entry} $bases {
        if {$name eq {} || [llength [dict get $entry context]] != 3} {error "Invalid baseline identity."}
        file normalize [lindex [dict get $entry context] 1]
        validate_metadata [dict get $entry metadata]
        foreach record [dict get $entry records] {
            foreach key {name model hierarchy values} {dict get $record $key}
            set values [dict get $record values]; dict size $values
            foreach key {id gm gds gmid gain ro headroom ft cgg_total} {
                set value [get $values $key]
                if {$value ne {} && [number $value] eq {}} {error "Invalid $key in baseline $name."}
            }
        }
    }
    set selected [get $data baseline_choice]
    if {$selected ne {} && ![dict exists $bases $selected]} {error "The selected baseline is missing."}
    set prefs [dict get $data preferences]
    foreach key {live only_review sizing_visible sort_desc} {
        if {[get $prefs $key] ni {0 1}} {error "Invalid session preference: $key."}
    }
    if {[get $prefs sort_key] ni {name model id gmid gain margin status}} {error "Invalid saved sort column."}
    if {[get $prefs lut_y] ni {gain ft density}} {error "Invalid saved plot metric."}
    foreach key {target_gmid target_gm_u} {
        set n [number [get $prefs $key]]
        if {$n eq {} || $n <= 0} {error "Invalid saved sizing target: $key."}
    }
    set length [get $prefs target_length]
    if {$length ne {} && ([number $length] eq {} || $length <= 0)} {error "Invalid saved sizing length."}
    set length [get $prefs lut_length All]
    if {$length ne "All" && ([number $length] eq {} || $length <= 0)} {error "Invalid saved chart length."}
    set slice [get $data lookup_slice]
    if {[llength $slice] ni {0 7}} {error "Invalid saved lookup slice."}
    if {[llength $slice]} {
        foreach value [lrange $slice 3 end] {if {[number $value] eq {}} {error "Invalid lookup conditions."}}
    }
    set geometry [get $data geometry]
    if {$geometry ne {} && ![regexp {^[0-9]{3,5}x[0-9]{3,5}$} $geometry]} {error "Invalid saved window size."}
    set sash [get $data sash]
    if {$sash ne {} && (![string is integer -strict $sash] || $sash < 0 || $sash > 10000)} {error "Invalid saved pane width."}
    if {[dict exists $data integration]} {
        set options [dict get $data integration]
        foreach key {follow_cursor auto_results device_saves auto_lookup} {
            if {[get $options $key] ni {0 1}} {error "Invalid integration setting: $key."}
        }
        if {[get $options result_analysis] ni {auto op dc tran}} {error "Invalid project analysis type."}
        dict get $options result_path
    }
    if {[dict exists $data geometry_options]} {
        set options [get $data geometry_options]
        foreach key {fingers copies} {
            set value [get $options $key]
            if {$value ne {} && (![string is integer -strict $value] || $value < 1 || $value > 1024)} {error {Invalid saved finger/copy count.}}
        }
        set tolerance [number [get $options tolerance]]
        if {$tolerance eq {} || $tolerance <= 0 || $tolerance > 100} {error {Invalid verification tolerance.}}
    }
    return $data
}
proc ::analog_lens::session_data {} {
    variable limits; variable declared; variable baselines; variable baseline_choice; variable lut_file; variable lut_slice
    variable session_path; variable window; variable session_geometry; variable session_sash; variable status
    if {[llength [info commands winfo]] && [winfo exists $window]} {
        # A newly constructed toplevel reports 1x1 until Tk has laid it out.
        # Startup integration may run at idle before that Configure event.
        set width [winfo width $window]; set height [winfo height $window]
        if {$width >= 100 && $height >= 100} {set session_geometry "${width}x${height}"}
        if {[winfo exists $window.tabs.op.canvas.content.panes] && $width >= 100} {set session_sash [$window.tabs.op.canvas.content.panes sashpos 0]}
    }
    set prefs {}
    foreach key {live only_review sizing_visible sort_key sort_desc lut_y lut_length target_gmid target_gm_u target_length} {
        dict set prefs $key [set ::analog_lens::$key]
    }
    foreach {key kind} {target_gm_u gm target_gmid gmid target_length length} {
        if {[get $prefs $key] ne {}} {dict set prefs $key [quantity [get $prefs $key] $kind]}
    }
    set data [dict create format analog-lens-session schema 1 limits $limits declared $declared baselines $baselines \
        baseline_choice $baseline_choice preferences $prefs geometry $session_geometry sash $session_sash \
        lookup_file $lut_file lookup_slice $lut_slice]
    if {[info exists ::analog_lens::integration_options]} {dict set data integration $::analog_lens::integration_options}
    dict set data geometry_options [dict create fingers $::analog_lens::target_fingers copies $::analog_lens::target_copies tolerance [quantity $::analog_lens::verification_tolerance percent]]
    validate_session $data
    return $data
}
proc ::analog_lens::save_session {path} {
    variable session_path; variable status
    set data [session_data]
    atomic_write $path "$data\n"
    set session_path [file normalize $path]; set status "Session saved: $session_path"
}
proc ::analog_lens::open_session {path} {
    if {$::analog_lens::run_channel ne {}} {error "Finish or cancel the current run before opening a session."}
    if {[file size $path] > 20000000} {error "Session exceeds the 20 MB limit."}
    apply_session_data [validate_session [read_text $path]] $path
}
proc ::analog_lens::apply_session_data {data path} {
    variable run_channel; variable limits; variable declared; variable baselines; variable baseline_choice; variable session_path
    variable lut_rows; variable lut_slice; variable lut_file; variable status; variable window; variable result_metadata
    variable session_geometry; variable session_sash
    # Validate everything, including referenced lookup data, before changing state.
    validate_session $data
    set lookup [get $data lookup_file]; set rows {}; set warning {}
    if {$lookup ne {}} {
        if {[file pathtype $lookup] eq "relative"} {set lookup [file join [file dirname $path] $lookup]}
        if {[file isfile $lookup]} {set rows [parse_lut [read_text $lookup]]} else {set warning { · Lookup file is missing; load it again.}; set lookup {}}
    }
    set geometry [get $data geometry_options {fingers {} copies {} tolerance 10}]
    set ::analog_lens::target_fingers [get $geometry fingers]; set ::analog_lens::target_copies [get $geometry copies]
    set ::analog_lens::verification_tolerance [get $geometry tolerance 10]
    set limits [dict get $data limits]; set declared [dict get $data declared]
    set baselines [dict get $data baselines]; set baseline_choice [get $data baseline_choice]
    if {[dict exists $data integration]} {set ::analog_lens::integration_options [dict get $data integration]}
    dict for {key value} [dict get $data preferences] {
        if {$key in {live only_review sizing_visible sort_key sort_desc lut_y lut_length target_gmid target_gm_u target_length}} {set ::analog_lens::$key $value}
    }
    set lut_rows $rows; set lut_file $lookup; set lut_slice [get $data lookup_slice]
    set session_geometry [get $data geometry]; set session_sash [get $data sash]
    set session_path [expr {$path eq {} ? {} : [file normalize $path]}]
    # Conditions are defaults for the next import/run. Do not relabel loaded results.
    if {[llength [info commands winfo]] && [winfo exists $window]} {
        dict for {key value} $limits {set ::analog_lens::edit_limits($key) $value}
        dict for {key value} $declared {set ::analog_lens::edit_conditions($key) $value}
        set ::analog_lens::lut_metric_label [dict get {gain {Intrinsic gain} ft {Estimated fT} density {Current density}} $::analog_lens::lut_y]
        rebuild_lookup_filters; toggle_sizing; restore_layout; render
    }
    select_baseline
    set status "Session opened: $session_path$warning · Load or run results for a current comparison."
}
proc ::analog_lens::restore_layout {} {
    variable window; variable session_geometry; variable session_sash
    if {$session_geometry ne {}} {
        ::scan $session_geometry {%dx%d} width height
        set width [expr {max(900,min($width,[winfo screenwidth $window]))}]
        set height [expr {max(640,min($height,[winfo screenheight $window]))}]
        wm geometry $window ${width}x${height}
    }
    if {$session_sash ne {}} {$window.tabs.op.canvas.content.panes sashpos 0 $session_sash}
}
proc ::analog_lens::session_dialog {action} {
    variable window; variable session_path
    set options [list -parent $window -filetypes {{{Analog Lens session} .alsession}}]
    if {$action eq "save"} {
        set name [expr {$session_path eq {} ? "analog-lens.alsession" : [file tail $session_path]}]
        set path [tk_getSaveFile {*}$options -title {Save analysis session} -defaultextension .alsession -initialfile $name]
        if {$path ne {}} {save_session $path}
    } else {
        set path [tk_getOpenFile {*}$options -title {Open analysis session}]
        if {$path ne {}} {open_session $path}
    }
}
proc ::analog_lens::select_baseline {} {
    variable baselines; variable baseline_choice; variable snapshot; variable snapshot_context; variable snapshot_metadata; variable window
    set snapshot {}; set snapshot_context {}; set snapshot_metadata {}
    if {[dict exists $baselines $baseline_choice]} {
        set entry [dict get $baselines $baseline_choice]
        set snapshot [dict get $entry records]; set snapshot_context [dict get $entry context]; set snapshot_metadata [dict get $entry metadata]
    }
    if {[llength [info commands winfo]] && [winfo exists $window.tabs.compare.canvas.content.saved.choice]} {
        $window.tabs.compare.canvas.content.saved.choice configure -values [dict keys $baselines]
    }
    if {[llength [info commands winfo]]} {render_compare}
}
proc ::analog_lens::comparison_data {before after} {
    set old {}; set current {}; set rows {}
    foreach r $before {dict set old [list [get $r name] [get $r model]] $r}
    foreach r $after {dict set current [list [get $r name] [get $r model]] $r}
    foreach key [lsort -unique [concat [dict keys $old] [dict keys $current]]] {
        set a [get $old $key]; set b [get $current $key]
        set state [expr {$a eq {} ? "Added" : $b eq {} ? "Removed" : "Matched"}]
        set row [dict create name [lindex $key 0] model [lindex $key 1] state $state]
        foreach metric {gmid id gain headroom ft} {
            set x [get [get $a values] $metric]; set y [get [get $b values] $metric]
            dict set row old_$metric $x; dict set row new_$metric $y
            dict set row change_$metric [expr {$x ne {} && $y ne {} ? $y-$x : {}}]
            dict set row percent_$metric [expr {$x ne {} && $y ne {} && $x != 0 ? 100*($y-$x)/abs($x) : {}}]
        }
        lappend rows $row
    }
    return $rows
}
proc ::analog_lens::export_comparison {path} {
    variable comparison_rows; variable snapshot_metadata; variable result_metadata
    set header {device model state}
    foreach metric {gmid id gain headroom ft} {lappend header baseline_$metric current_$metric change_$metric percent_$metric}
    lappend header baseline_metadata current_metadata
    set out "[csv_row $header]\n"
    foreach r $comparison_rows {
        set values [list [get $r name] [get $r model] [get $r state]]
        foreach metric {gmid id gain headroom ft} {foreach prefix {old new change percent} {lappend values [get $r ${prefix}_$metric]}}
        lappend values $snapshot_metadata $result_metadata
        append out [csv_row $values] \n
    }
    atomic_write $path $out
}
proc ::analog_lens::export_comparison_dialog {} {
    set path [tk_getSaveFile -parent $::analog_lens::window -title {Export comparison} -defaultextension .csv -initialfile comparison.csv]
    if {$path ne {}} {export_comparison $path; set ::analog_lens::status "Comparison saved: $path"}
}
