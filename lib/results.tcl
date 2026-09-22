# Durable project history; files contain dictionaries, never sourced Tcl.
namespace eval ::analog_lens {
    variable results_query {}; variable results_items {}; variable results_status {}
    variable results_filter All
}
proc ::analog_lens::history_directory {} {
    lassign [project_identity] key directory
    if {$key eq {}} {error {Save the testbench before using project history.}}
    return [file join $directory .analog-lens history [format %08x [zlib crc32 $key]]]
}
proc ::analog_lens::archive_run {} {
    set rawpath [get [get $::analog_lens::result_metadata raw] path]
    if {$rawpath eq {} || ![file isfile $rawpath]} {return}
    set directory [file join [history_directory] [clock microseconds]]
    file mkdir $directory
    set dest [file join $directory result.raw]
    file copy $rawpath $dest
    set metadata $::analog_lens::result_metadata
    dict set metadata original_raw $rawpath
    dict set metadata raw [file_signature $dest]
    dict set metadata archived_signature [raw_signature $dest]
    set deck [get [get $metadata input_deck] path]
    if {[file isfile $deck]} {file copy $deck [file join $directory input.spice]}
    set dep [get $metadata dependencies]
    if {[file isfile $dep]} {
        set copy [file join $directory dependencies.json]; file copy $dep $copy
        dict set metadata dependencies $copy
    }
    atomic_write [file join $directory result.metadata] $metadata
    set name "[get $metadata analysis] · [get $metadata captured_at]"
    if {[get [get $metadata verification] state] ne {}} {append name " · Sizing [get [get $metadata verification] state]"}
    atomic_write [file join $directory entry.alrun] [dict create format analog-lens-history schema 1 kind Run name $name \
        project [lindex [project_identity] 0] context $::analog_lens::active_context metadata $metadata records $::analog_lens::records]
    refresh_results_if_open
}
proc ::analog_lens::archive_baseline {name entry} {
    set directory [file join [history_directory] baseline-[clock microseconds]]
    file mkdir $directory
    atomic_write [file join $directory entry.alrun] [dict merge $entry [dict create format analog-lens-history schema 1 kind Baseline name $name project [lindex [project_identity] 0]]]
    refresh_results_if_open
}
proc ::analog_lens::project_catalog {} {
    set result {}; set key [lindex [project_identity] 0]
    foreach path [lsort -decreasing [glob -nocomplain -directory [history_directory] */entry.alrun]] {
        if {[file size $path] > 20000000} {continue}
        if {[catch {
            set entry [read_text $path]
            if {[get $entry format] ne "analog-lens-history" || [get $entry schema] ne "1" || [get $entry project] ne $key} {continue}
            validate_metadata [dict get $entry metadata]
            dict get $entry records; dict get $entry context
        }]} {continue}
        dict set entry path $path
        set models {}; foreach record [get $entry records] {lappend models [get $record model]}
        dict set entry models [join [lsort -unique $models] {, }]
        lappend result $entry
    }
    set directory [lindex [project_identity] 1]
    foreach path [lsort -decreasing [glob -nocomplain -directory [file join $directory .analog-lens lookups] */*.csv]] {
        if {[file size $path] > 50000000} {continue}
        if {[catch {set rows [parse_lut [read_text $path]]}]} {continue}
        set slices {}; set models {}
        foreach row $rows {lappend slices [get $row slice]; lappend models [lindex [get $row slice] 1]}
        lappend result [dict create kind Lookup name [file tail [file dirname $path]] path $path \
            models [join [lsort -unique $models] {, }] slices [lsort -unique $slices] samples [llength $rows]]
    }
    return $result
}
proc ::analog_lens::refresh_results_if_open {} {
    if {[llength [info commands winfo]] && [winfo exists $::analog_lens::window.results]} {refresh_results}
}
proc ::analog_lens::refresh_results {args} {
    set tree $::analog_lens::window.results.tree
    if {![winfo exists $tree]} {return}
    $tree delete [$tree children {}]; set ::analog_lens::results_items {}
    set query [string tolower [string trim $::analog_lens::results_query]]; set count 0
    foreach entry [project_catalog] {
        if {$::analog_lens::results_filter ne "All" && [get $entry kind] ne $::analog_lens::results_filter} {continue}
        if {$query ne {} && [string first $query [string tolower "[get $entry name] [get $entry models] [get $entry slices] [get $entry metadata]"]] < 0} {continue}
        set id r[incr count]; dict set ::analog_lens::results_items $id $entry
        set details [get $entry samples]
        if {[get $entry kind] eq "Lookup"} {append details { samples}} else {set details [get [get $entry metadata] pdk]}
        $tree insert {} end -id $id -values [list [get $entry kind] [get $entry name] [get $entry models] $details]
    }
    set ::analog_lens::results_status "$count entries · Select a run to load, a baseline to compare, or a lookup to explore."
}
proc ::analog_lens::selected_result {} {
    set tree $::analog_lens::window.results.tree
    set selected [$tree selection]
    if {[llength $selected] != 1} {error {Select one project result.}}
    return [dict get $::analog_lens::results_items [lindex $selected 0]]
}
proc ::analog_lens::open_project_result {} {
    set entry [selected_result]
    if {[get $entry kind] eq "Lookup"} {
        set path [get $entry path]; set rows [parse_lut [read_text $path]]
        set ::analog_lens::lut_file $path; set ::analog_lens::lut_rows $rows
        set ::analog_lens::lut_slice [get [lindex $rows 0] slice]
        rebuild_lookup_filters; set ::analog_lens::lookup_match_key {}; auto_select_lookup; open_tab lut
    } elseif {[get $entry kind] eq "Baseline"} {
        set name [get $entry name]
        if {[dict exists $::analog_lens::baselines $name] && [get $::analog_lens::baselines $name] ne $entry} {append name " ([clock seconds])"}
        dict set ::analog_lens::baselines $name $entry; set ::analog_lens::baseline_choice $name
        select_baseline; open_tab compare
    } else {
        if {$::analog_lens::run_channel ne {}} {error {Finish or cancel the current simulation first.}}
        if {[context_key [context]] ne [context_key [get $entry context]]} {error {Return to this run's schematic and hierarchy before loading it.}}
        set metadata [get $entry metadata]; set path [get [get $metadata raw] path]
        if {[raw_signature $path] ne [get $metadata archived_signature]} {error {Archived raw data changed or is missing.}}
        read_results $path [get $metadata analysis]
        set ::analog_lens::result_metadata $metadata
        set ::analog_lens::sample [get $metadata sample 0]; set ::analog_lens::dataset [get $metadata dataset 0]
        refresh; update_freshness
        set ::analog_lens::verification_result [get $metadata verification]
        set ::analog_lens::verification_summary {Historical result · Check source freshness before relying on it.}
        update_verification_text; open_tab op
    }
    project_flush
    set ::analog_lens::results_status "Opened [get $entry name]"
}
proc ::analog_lens::result_details {} {
    set entry [selected_result]; set text "[get $entry kind] · [get $entry name]\n[get $entry path]\n\n"
    if {[get $entry kind] eq "Lookup"} {
        foreach slice [get $entry slices] {append text "[join $slice { · }]\n"}
    } else {
        set m [get $entry metadata]
        foreach key {pdk corner temp_c analysis captured_at source conditions_source dependencies dependency_warnings} {append text "$key: [get $m $key]\n"}
    }
    set w $::analog_lens::window.results.details
    if {[winfo exists $w]} {destroy $w}
    toplevel $w; wm title $w {Result details}; wm geometry $w 680x400
    text $w.text -wrap word; text_style $w.text; pack $w.text -fill both -expand 1
    $w.text insert end $text; $w.text configure -state disabled; bind $w <Escape> [list destroy $w]
}
proc ::analog_lens::results_dialog {} {
    project_sync; history_directory; show
    set w $::analog_lens::window.results
    if {[winfo exists $w]} {raise $w; refresh_results; return}
    toplevel $w; wm title $w {Project results · Analog Lens}; wm geometry $w 940x560; wm minsize $w 640 360
    ttk::frame $w.search -padding 12; pack $w.search -fill x
    pack [label $w.search.label Search] -side left -padx {0 8}
    ttk::entry $w.search.query -textvariable ::analog_lens::results_query
    pack $w.search.query -side left -fill x -expand 1
    bind $w.search.query <KeyRelease> ::analog_lens::refresh_results
    ttk::combobox $w.search.kind -textvariable ::analog_lens::results_filter -values {All Run Baseline Lookup} -state readonly -width 10
    pack $w.search.kind -side left -padx 8; bind $w.search.kind <<ComboboxSelected>> ::analog_lens::refresh_results
    pack [button $w.search.refresh Refresh ::analog_lens::refresh_results] -side left
    ttk::frame $w.actions -padding 12; pack $w.actions -side bottom -fill x
    pack [button $w.actions.open {Open selected} ::analog_lens::open_project_result] -side left
    pack [button $w.actions.details Details ::analog_lens::result_details] -side left -padx 8
    pack [button $w.actions.batch {Characterization batch…} ::analog_lens::batch_dialog] -side left
    pack [button $w.actions.close Close [list destroy $w]] -side right
    ttk::label $w.status -textvariable ::analog_lens::results_status -wraplength 850 -padding 12; pack $w.status -side bottom -fill x
    ttk::treeview $w.tree -columns {kind name models details} -show headings -selectmode browse
    foreach {col title width} {kind Kind 85 name Name 320 models Models 230 details Details 180} {
        $w.tree heading $col -text $title; $w.tree column $col -width $width -minwidth 60
    }
    ttk::scrollbar $w.scroll -command [list $w.tree yview]; $w.tree configure -yscrollcommand [list $w.scroll set]
    pack $w.scroll -side right -fill y; pack $w.tree -fill both -expand 1
    bind $w.tree <Return> {::analog_lens::safe ::analog_lens::open_project_result}
    bind $w.tree <Double-1> {::analog_lens::safe ::analog_lens::open_project_result}
    bind $w <Escape> [list destroy $w]
    refresh_results; focus $w.search.query
}
