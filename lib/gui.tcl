namespace eval ::analog_lens {
    variable window .analog_lens
    variable detail_title {Select a transistor}; variable detail_subtitle {}; variable summary {}
    variable lut_file {}; variable slice_labels {}; variable slice_label {}; variable sizing_text {}
    variable plot_after {}; variable watch_key {}
}
proc ::analog_lens::safe {command} {
    variable status; variable window
    if {[catch {uplevel #0 $command} msg]} {
        set status $msg
        set action [lindex $command 0]
        if {$action eq "::analog_lens::refresh"} {
            catch {render}
            foreach key {sample dataset} {
                if {[string match -nocase *$key* $msg]} {
                    set w $window.tabs.op.point.$key
                    if {[winfo exists $w]} {$w state invalid; focus $w}
                }
            }
        } else {
            tk_messageBox -parent $window -title {Analog Lens} -icon warning -type ok \
                -message {The action could not be completed.} -detail $msg
        }
    }
}

proc ::analog_lens::install_menu {} {
    if {![llength [info commands winfo]] || ![llength [info commands xschem]]} {return}
    set bar [xschem get top_path].menubar
    if {![winfo exists $bar] || [winfo exists $bar.analog_lens]} {return}
    set m $bar.analog_lens; menu $m -tearoff 0
    $m add command -label {Open Analog Lens} -command ::analog_lens::show
    $m add command -label {Inspect selected transistor} -command {::analog_lens::show; ::analog_lens::follow_selection}
    $m add separator
    foreach {name title} {run {Run operating point} load {Load results…} refresh {Refresh results} export {Export CSV…} log {Run log}} {
        $m add command -label $title -command [list ::analog_lens::menu_action $name]
    }
    $m add separator
    foreach {name title} {lut {gm/Id explorer} compare {Compare runs} setup {Setup & help}} {
        $m add command -label $title -command [list ::analog_lens::open_tab $name]
    }
    $bar add cascade -label {Analog Lens} -menu $m
}
proc ::analog_lens::active_pdk {} {
    if {[info exists ::env(PDK)]} {return $::env(PDK)}
    return {auto-detect from symbols}
}
proc ::analog_lens::button {path label command} {
    ttk::button $path -text $label -width 0 -style AL.TButton -command [list ::analog_lens::safe $command]
    return $path
}
proc ::analog_lens::label {path text {style AL.TLabel}} {ttk::label $path -text $text -style $style; return $path}
proc ::analog_lens::show {} {
    variable window; variable status; variable timer; variable summary
    if {[winfo exists $window]} {raise $window; focus $window; return}
    configure_styles
    toplevel $window; wm title $window {Analog Lens · xschem}
    wm geometry $window 1180x820; wm minsize $window 900 640
    wm protocol $window WM_DELETE_WINDOW ::analog_lens::close_window
    ttk::frame $window.root -style AL.TFrame -padding 16; pack $window.root -fill both -expand 1
    set root $window.root
    ttk::frame $root.head -style AL.TFrame; pack $root.head -fill x -pady {0 12}
    pack [label $root.head.title {Analog Lens} AL.Title.TLabel] -side left
    set summary "[active_pdk]  ·  ngspice"
    ttk::label $root.head.pdk -textvariable ::analog_lens::summary -style AL.Muted.TLabel
    pack $root.head.pdk -side right -padx {12 0}
    ttk::frame $root.tools -style AL.TFrame; pack $root.tools -fill x -pady {0 8}
    foreach {n text cmd} {run {Run operating point} run_op load {Load results…} load_results refresh Refresh refresh export {Export CSV…} export_dialog log {Run log} log_dialog} {
        button $root.tools.$n $text ::analog_lens::$cmd
    }
    $root.tools.run configure -style AL.Primary.TButton
    layout_toolbar
    ttk::progressbar $root.progress -mode indeterminate -length 160
    ttk::notebook $window.tabs -style AL.TNotebook
    # Reserve feedback before the expanding content so it survives short windows.
    ttk::label $root.status -textvariable ::analog_lens::status -style AL.Muted.TLabel -wraplength 850
    pack $root.status -side bottom -fill x -pady {10 0}; wrapping $root.status
    pack $window.tabs -in $root -fill both -expand 1
    foreach {n title} {op {Operating point} lut {gm/Id explorer} compare {Compare runs} setup {Setup & help}} {
        ttk::frame $window.tabs.$n -style AL.TFrame -padding 12
        $window.tabs add $window.tabs.$n -text $title
        build_$n $window.tabs.$n
    }
    install_shortcuts
    bind $window <Configure> {::analog_lens::schedule_layout %W}
    foreach var {target_length target_gmid target_gm_u} {
        trace add variable ::analog_lens::$var write ::analog_lens::invalidate_sizing
    }
    trace add variable ::analog_lens::run_log write ::analog_lens::update_log
    if {[catch {refresh} msg]} {set status $msg; render}
    update_run_controls
    set timer [after 800 ::analog_lens::tick]
    focus $root.tools.run
}

proc ::analog_lens::close_window {} {
    variable window; variable timer; variable plot_after; variable layout_after
    foreach id [list $timer $plot_after $layout_after] {if {$id ne {}} {after cancel $id}}
    set timer {}; set plot_after {}; set layout_after {}
    foreach var {target_length target_gmid target_gm_u} {
        trace remove variable ::analog_lens::$var write ::analog_lens::invalidate_sizing
    }
    trace remove variable ::analog_lens::run_log write ::analog_lens::update_log
    destroy $window
}

proc ::analog_lens::build_op {w} {
    variable colors
    ttk::frame $w.filters -style AL.TFrame; pack $w.filters -fill x -pady {0 10}
    label $w.filters.find {Find device}
    ttk::entry $w.filters.search -textvariable ::analog_lens::search -width 18
    bind $w.filters.search <KeyRelease> ::analog_lens::render
    bind $w.filters.search <Escape> {::analog_lens::clear_search; break}
    button $w.filters.clear Clear ::analog_lens::clear_search
    ttk::checkbutton $w.filters.review -style AL.TCheckbutton -text {Needs review} -variable ::analog_lens::only_review -command ::analog_lens::render
    ttk::checkbutton $w.filters.follow -style AL.TCheckbutton -text {Follow schematic} -variable ::analog_lens::live
    flow_controls $w.filters {find search clear review follow} 800
    ttk::frame $w.point -style AL.TFrame; pack $w.point -fill x -pady {0 10}
    label $w.point.type_label {Load analysis}
    ttk::combobox $w.point.type -textvariable ::analog_lens::analysis_type -values {op dc tran} -state readonly -width 5
    foreach n {type_label type} {pack $w.point.$n -side left -padx {0 8}}
    foreach n {sample dataset} {
        pack [label $w.point.${n}_label [string totitle $n]] -side left -padx {0 6}
        ttk::spinbox $w.point.$n -from 0 -to 100000000 -width 6 -textvariable ::analog_lens::$n \
            -validate key -validatecommand [list ::analog_lens::integer_input %P] \
            -command {::analog_lens::safe ::analog_lens::refresh}
        pack $w.point.$n -side left -padx {0 12}
        bind $w.point.$n <Return> {::analog_lens::safe ::analog_lens::refresh; break}
    }
    pack [button $w.point.color {Color by gm/Id} ::analog_lens::color_devices] -side right
    ttk::panedwindow $w.panes -orient horizontal; pack $w.panes -fill both -expand 1
    ttk::frame $w.panes.list -style AL.TFrame
    ttk::frame $w.panes.detail -style AL.TFrame -padding {16 0 0 0}
    $w.panes add $w.panes.list -weight 3; $w.panes add $w.panes.detail -weight 2
    bind $w.panes <Configure> ::analog_lens::constrain_panes
    bind $w.panes <ButtonRelease-1> ::analog_lens::constrain_panes
    set l $w.panes.list
    ttk::frame $l.head -style AL.TFrame
    ttk::label $l.head.count -textvariable ::analog_lens::device_summary -style AL.Muted.TLabel
    pack $l.head.count -side left
    ttk::menubutton $l.head.sort -textvariable ::analog_lens::sort_label -menu $l.head.sort.menu -takefocus 1
    menu $l.head.sort.menu -tearoff 0
    foreach {key title} {name Device type Type id {Id / Ic} gmid gm/Id gain gm/gds margin {Headroom} status Check} {
        $l.head.sort.menu add radiobutton -label $title -variable ::analog_lens::sort_key -value $key \
            -command [list ::analog_lens::sort_table $key 0]
    }
    $l.head.sort.menu add separator
    $l.head.sort.menu add checkbutton -label Descending -variable ::analog_lens::sort_desc -command ::analog_lens::apply_sort
    pack $l.head.sort -side right
    grid $l.head -row 0 -column 0 -columnspan 2 -sticky ew -pady {0 8}
    ttk::treeview $l.tree -columns {name type id gmid gain margin status} -show headings -selectmode browse -style AL.Treeview -height 6
    foreach {key title width} {name Device 90 type Type 55 id {Id / Ic} 84 gmid {gm/Id · 1/V} 98 gain gm/gds 78 margin {Margin · V} 88 status Check 92} {
        $l.tree heading $key -text $title -command [list ::analog_lens::sort_table $key]
        set width [expr {max($width,[font measure ALHeading "$title ↓"]+18)}]
        $l.tree column $key -width $width -minwidth $width -anchor [expr {$key in {id gmid gain margin} ? "e" : "w"}]
    }
    $l.tree tag configure review -foreground [dict get $colors warning]
    $l.tree tag configure missing -foreground [dict get $colors muted]
    ttk::scrollbar $l.scroll -command [list $l.tree yview]
    ttk::scrollbar $l.horizontal -orient horizontal -command [list $l.tree xview]
    $l.tree configure -yscrollcommand [list $l.scroll set] -xscrollcommand [list $l.horizontal set]
    grid $l.tree -row 1 -column 0 -sticky nsew; grid $l.scroll -row 1 -column 1 -sticky ns
    grid $l.horizontal -row 2 -column 0 -sticky ew
    grid rowconfigure $l 1 -weight 1; grid columnconfigure $l 0 -weight 1
    bind $l.tree <<TreeviewSelect>> ::analog_lens::inspect_selection
    bind $l.tree <Double-1> {::analog_lens::safe ::analog_lens::locate}
    bind $l.tree <Return> {::analog_lens::safe ::analog_lens::locate; break}
    ttk::label $l.empty -textvariable ::analog_lens::empty_text -style AL.Muted.TLabel -justify center -anchor center -wraplength 300
    set d $w.panes.detail
    ttk::label $d.title -textvariable ::analog_lens::detail_title -style AL.Heading.TLabel
    ttk::label $d.subtitle -textvariable ::analog_lens::detail_subtitle -style AL.Muted.TLabel -wraplength 280
    grid $d.title -row 0 -column 0 -columnspan 2 -sticky ew -pady {0 6}
    grid $d.subtitle -row 1 -column 0 -columnspan 2 -sticky ew -pady {0 10}; wrapping $d.subtitle
    text $d.text -wrap word -height 8 -width 30 -state disabled
    text_style $d.text 1
    ttk::scrollbar $d.scroll -command [list $d.text yview]; $d.text configure -yscrollcommand [list $d.scroll set]
    grid $d.text -row 2 -column 0 -sticky nsew; grid $d.scroll -row 2 -column 1 -sticky ns
    ttk::frame $d.actions -style AL.TFrame
    grid $d.actions -row 3 -column 0 -columnspan 2 -sticky ew -pady {10 0}
    grid [button $d.locate {Locate in schematic} ::analog_lens::locate] -in $d.actions -row 0 -column 0 -columnspan 2 -sticky ew -pady {0 6}
    grid [button $d.copy {Copy details} ::analog_lens::copy_detail] -in $d.actions -row 1 -column 0 -sticky ew -padx {0 6}
    grid [button $d.annotate {Place annotation} ::analog_lens::place_annotation] -in $d.actions -row 1 -column 1 -sticky ew
    grid columnconfigure $d.actions 0 -weight 1; grid columnconfigure $d.actions 1 -weight 1
    grid rowconfigure $d 2 -weight 1; grid columnconfigure $d 0 -weight 1
}

proc ::analog_lens::render {} {
    variable records; variable search; variable only_review; variable window; variable selected
    variable device_summary; variable empty_text
    set tree $window.tabs.op.panes.list.tree
    if {![winfo exists $tree]} {return}
    set before $selected; $tree delete [$tree children {}]; set i -1; set reviews 0
    foreach r $records {
        incr i; set v [get $r values]
        if {[get $v status] eq "Review"} {incr reviews}
        if {$only_review && [get $v status] ne "Review"} {continue}
        if {$search ne {} && [string first [string tolower $search] [string tolower "[get $r name] [get $r model]"]] < 0} {continue}
        set tag [expr {[get $v status] eq "Review" ? "review" : "normal"}]
        if {[get $v gm] eq {}} {set tag missing}
        $tree insert {} end -id d$i -tags $tag -values [list [get $r name] [get $r type] "[eng [get $v id] A]  " "[eng [get $v gmid]]  " "[eng [get $v gain]]  " "[eng [get $v headroom]]  " [get $v status]]
        if {[get $r name] eq $before} {$tree selection set d$i; $tree focus d$i}
    }
    apply_sort
    set count [llength [$tree children {}]]
    set device_summary "$count of [llength $records] devices · $reviews to review"
    set empty $window.tabs.op.panes.list.empty
    if {!$count} {
        set selected {}
        set filtered [expr {$search ne {} || $only_review}]
        set ::analog_lens::detail_title {Device details}
        set ::analog_lens::detail_subtitle {Select a device to inspect its metrics.}
        set empty_text [expr {$filtered ? "No matching devices\nClear the search or review filter." : "No device results\nRun operating point or load results.\nDescend into a circuit to inspect its devices."}]
        place $empty -in $tree -relx 0.5 -rely 0.5 -anchor center -relwidth 0.9
        set_detail {}; schedule_plot
    } else {
        place forget $empty
        if {![llength [$tree selection]]} {
            set first [lindex [$tree children {}] 0]; $tree selection set $first; $tree focus $first
        }
    }
    inspect_selection; render_compare; update_run_controls
}

proc ::analog_lens::chosen {} {
    variable records; variable window
    set tree $window.tabs.op.panes.list.tree
    if {![winfo exists $tree] || ![llength [$tree selection]]} {return {}}
    return [lindex $records [string range [lindex [$tree selection] 0] 1 end]]
}
proc ::analog_lens::set_detail {text} {
    variable window
    set w $window.tabs.op.panes.detail.text
    if {![winfo exists $w]} {return}
    $w configure -state normal; $w delete 1.0 end; $w insert end $text; $w configure -state disabled
}
proc ::analog_lens::inspect_selection {} {
    variable selected; variable detail_title; variable detail_subtitle
    set r [chosen]; if {$r eq {}} {return}
    set selected [get $r name]; set v [get $r values]
    set detail_title "[get $r name]  ·  [get $v status]"
    set detail_subtitle "[get $r model]\n[get $r family] · [get $r type]"
    set text {}
    foreach {key textlabel unit} {gmid {gm/Id} 1/V gain {Intrinsic gain} V/V id {Id / Ic} A gm gm S gds {gds / go} S ro ro Ω vgs Vgs V vds Vds V vth Vth V vdsat {Vdsat / vdss} V headroom {Model headroom} V cgg_total {Total Cgg} F ft {fT estimate} Hz} {
        append text [format "%-17s %s\n" $textlabel [eng [get $v $key] $unit]]
    }
    if {[regexp {npn|pnp} [get $r type]]} {
        foreach {key textlabel unit} {ib Ib A beta {DC beta} {} vbe Vbe V vbc Vbc V vce Vce V} {
            append text [format "%-17s %s\n" $textlabel [eng [get $v $key] $unit]]
        }
    }
    append text "\nW: [get $r width]   L: [get $r length]\nFingers: [get $r fingers]   Multiplier: [get $r multiplier]\nDimensions shown as entered.\n\n"
    if {[llength [get $v issues]]} {append text "CHECKS\n[join [get $v issues] \n\n]\n\n"}
    append text "Headroom = |Vds| − |model Vdsat|. This is a model-based check. Intrinsic gain is a device metric; fT is gm/(2πCgg), not circuit bandwidth.\n\nRAW DEVICE\n[get $r path]\n"
    if {[get $r family] eq "ihp"} {append text "\nPSP Cgg includes cgsol + cgdol. Missing overlap data leaves fT unavailable."}
    set_detail $text; schedule_plot; update_run_controls
}
proc ::analog_lens::locate {} {
    variable active_context
    set r [chosen]; if {$r eq {}} {error "Select a device first."}
    if {[context] ne $active_context} {error "The schematic changed. Refresh first."}
    xschem unselect_all; xschem select instance [get $r owner]
    catch {xschem zoom_full 1 0.8}
}
proc ::analog_lens::follow_selection {} {
    variable window; variable records
    set owner [lindex [xschem selected_set] 0]
    set tree $window.tabs.op.panes.list.tree
    if {$owner eq {} || ![winfo exists $tree]} {return}
    set i -1
    foreach r $records {
        incr i
        if {[get $r owner] eq $owner && [$tree exists d$i]} {
            if {[$tree selection] ne "d$i"} {$tree selection set d$i; $tree see d$i; inspect_selection}; return
        }
    }
}
proc ::analog_lens::tick {} {
    variable timer; variable window; variable live; variable watch_key; variable run_channel; variable status
    if {![winfo exists $window]} {set timer {}; return}
    if {$run_channel eq {}} {
        if {![catch {list [context] [raw rawfile] [raw sim_type] [xschem get instances]} key] && $watch_key ne $key} {
            set watch_key $key
            if {[catch {refresh} msg]} {set status $msg; render}
        }
        if {$live} {catch {follow_selection}}
    }
    set timer [after 800 ::analog_lens::tick]
}
proc ::analog_lens::sort_table {key {toggle 1}} {
    variable sort_key; variable sort_desc
    if {$toggle} {set sort_desc [expr {$sort_key eq $key ? !$sort_desc : 0}]}
    set sort_key $key; apply_sort
}
proc ::analog_lens::apply_sort {} {
    variable window; variable records; variable sort_key; variable sort_desc; variable sort_label
    set tree $window.tabs.op.panes.list.tree
    if {![winfo exists $tree]} {return}
    set map [dict create id id gmid gmid gain gain margin headroom]
    set pairs {}; set missing {}
    foreach item [$tree children {}] {
        set r [lindex $records [string range $item 1 end]]
        if {[dict exists $map $sort_key]} {
            set value [number [get [get $r values] [dict get $map $sort_key]]]
            if {$value eq {}} {lappend missing $item; continue}
        } elseif {$sort_key eq "status"} {set value [get [get $r values] status]} else {set value [get $r $sort_key]}
        lappend pairs [list $value $item]
    }
    set mode [expr {[dict exists $map $sort_key] ? "-real" : "-dictionary"}]
    set direction [expr {$sort_desc ? "-decreasing" : "-increasing"}]
    foreach p [lsort $mode $direction -index 0 $pairs] {$tree move [lindex $p 1] {} end}
    foreach item $missing {$tree move $item {} end}
    foreach {key title} {name Device type Type id {Id / Ic} gmid {gm/Id · 1/V} gain gm/gds margin {Margin · V} status Check} {
        if {$key eq $sort_key} {
            set sort_label "Sort: $title [expr {$sort_desc ? "↓" : "↑"}]"
            append title [expr {$sort_desc ? " ↓" : " ↑"}]
        }
        $tree heading $key -text $title
    }
}

proc ::analog_lens::place_annotation {} {
    variable root
    set r [chosen]; if {$r eq {}} {error "Select a device first."}
    set name [get $r name]
    if {![regexp {^[A-Za-z0-9_:.]+$} $name]} {error "Use the inspector for array elements; annotation symbols currently require scalar names."}
    xschem place_symbol [file join $root symbols analog_lens.sym] "name=analoglens1 ref=$name"
    set ::analog_lens::status {Click in the schematic to place the annotation. This adds a schematic object.}
}
proc ::analog_lens::color_devices {} {
    variable records; variable active_context; variable limits; variable status
    if {[context] ne $active_context || ![llength $records]} {error "Refresh the current schematic's results first."}
    # Use standard xschem palette layers. The user's active palette owns RGB.
    # This intentionally adds highlights; clearing is the normal xschem action.
    foreach r $records {
        set v [get [get $r values] gmid]
        if {$v eq {}} {continue}
        set color [expr {$v < [dict get $limits gmid_min] ? 8 : $v > [dict get $limits gmid_max] ? 6 : 4}]
        xschem set hilight_color $color
        xschem hilight_instname -fast [get $r owner]
    }
    xschem redraw
    set status {gm/Id colors applied: layer 8 = below target, layer 4 = in range, layer 6 = above target. Clear using xschem's Highlight menu.}
}
proc ::analog_lens::update_run_controls {} {
    variable window; variable run_channel; variable records; variable active_context
    variable lut_rows; variable lut_slice
    if {![winfo exists $window]} {return}
    set idle [expr {$run_channel eq {}}]
    set current [expr {$idle && [llength $records] > 0 && ![catch {context} ctx] && $ctx eq $active_context}]
    foreach n {run load refresh} {set_enabled $window.root.tools.$n $idle}
    set_enabled $window.root.tools.export $current
    set_enabled $window.tabs.compare.keep $current
    set_enabled $window.tabs.op.point.color $current
    foreach n {locate annotate copy} {set_enabled $window.tabs.op.panes.detail.$n [expr {$current && [chosen] ne {}}]}
    foreach n {sample dataset} {
        set_enabled $window.tabs.op.point.$n $idle
        if {$current} {$window.tabs.op.point.$n state !invalid}
    }
    set w $window.tabs.op.point.type
    $w state [expr {$idle ? "!disabled readonly" : "disabled"}]
    set has_lut [expr {[llength $lut_rows] > 0 && $lut_slice ne {}}]
    set_enabled $window.tabs.lut.size.calc $has_lut
    set_enabled $window.tabs.lut.tools.data $has_lut
    set_enabled $window.tabs.lut.tools.sizing $has_lut
    if {$idle} {
        $window.root.tools.run configure -text {Run operating point}
        $window.root.progress stop; pack forget $window.root.progress
    } else {
        $window.root.tools.run configure -text {Running…}
        pack $window.root.progress -before $window.tabs -fill x -pady {0 8}
        $window.root.progress start 25
    }
}

proc ::analog_lens::export_dialog {} {
    variable records
    if {![llength $records]} {error "Load or run an operating point first."}
    set path [tk_getSaveFile -parent $::analog_lens::window -title {Export transistor analysis} -defaultextension .csv -initialfile analog-lens-report.csv]
    if {$path ne {}} {export_report $path; set ::analog_lens::status "Saved: $path"}
}
proc ::analog_lens::log_dialog {} {
    variable window; variable log_rendered
    set w $window.log
    if {[winfo exists $w]} {raise $w; focus $w.text; return}
    set log_rendered {}
    toplevel $w; wm title $w {Run log · Analog Lens}; wm transient $w $window
    wm geometry $w 840x460; wm minsize $w 480 280
    ttk::frame $w.actions -style AL.TFrame -padding 12
    pack $w.actions -side bottom -fill x
    ttk::checkbutton $w.actions.follow -text {Follow new output} -variable ::analog_lens::log_follow -style AL.TCheckbutton
    pack $w.actions.follow -side left
    pack [button $w.actions.copy {Copy log} {::analog_lens::copy_text $::analog_lens::run_log}] -side left -padx 12
    pack [button $w.actions.close Close [list destroy $w]] -side right
    ttk::label $w.status -textvariable ::analog_lens::status -style AL.Muted.TLabel -padding 12 -wraplength 750
    pack $w.status -fill x; wrapping $w.status
    text $w.text -wrap none -width 80 -height 20 -state disabled; text_style $w.text 1
    ttk::scrollbar $w.scroll -command [list $w.text yview]
    ttk::scrollbar $w.horizontal -orient horizontal -command [list $w.text xview]
    $w.text configure -yscrollcommand [list $w.scroll set] -xscrollcommand [list $w.horizontal set]
    pack $w.horizontal -side bottom -fill x
    pack $w.scroll -side right -fill y; pack $w.text -fill both -expand 1
    bind $w <Escape> [list destroy $w]
    set mod [expr {[tk windowingsystem] eq "aqua" ? "Command" : "Control"}]
    bind $w <$mod-w> [list destroy $w]
    update_log; focus $w.text
}
proc ::analog_lens::update_log {args} {
    variable window; variable run_log; variable log_follow; variable log_rendered
    set w $window.log.text
    if {![winfo exists $w]} {return}
    set position [$w yview]
    set tail [expr {[llength $position] == 2 && [lindex $position 1] >= 0.99}]
    $w configure -state normal
    if {$log_rendered ne {} && [string first $log_rendered $run_log] == 0} {
        $w insert end [string range $run_log [string length $log_rendered] end]
    } else {
        $w delete 1.0 end
        $w insert end [expr {$run_log eq {} ? "No operating-point output yet. Run an analysis to see diagnostics here." : $run_log}]
    }
    set log_rendered $run_log
    $w configure -state disabled
    if {$log_follow && $tail} {$w see end} elseif {[llength $position]} {$w yview moveto [lindex $position 0]}
}

proc ::analog_lens::build_lut {w} {
    variable colors
    ttk::frame $w.tools -style AL.TFrame; pack $w.tools -fill x -pady {0 8}
    pack [button $w.tools.load {Load lookup CSV…} ::analog_lens::load_lut] -side left -padx {0 12}
    pack [label $w.tools.label Curve] -side left -padx {0 8}
    ttk::combobox $w.tools.metric -state readonly -values {{Intrinsic gain} {Estimated fT} {Current density}} \
        -textvariable ::analog_lens::lut_metric_label -width 17
    pack $w.tools.metric -side left -padx {0 12}
    bind $w.tools.metric <<ComboboxSelected>> ::analog_lens::select_metric
    pack [button $w.tools.data {View data} ::analog_lens::data_dialog] -side right
    ttk::checkbutton $w.tools.sizing -text {Sizing estimate} -style AL.TCheckbutton -variable ::analog_lens::sizing_visible -command ::analog_lens::toggle_sizing
    pack $w.tools.sizing -side right -padx {0 12}
    ttk::label $w.source -textvariable ::analog_lens::lut_source -style AL.Muted.TLabel -wraplength 800
    pack $w.source -fill x -pady {0 8}; wrapping $w.source
    pack [label $w.slice_label {Model / corner / temperature / bias / reference width}] -anchor w -pady {0 4}
    ttk::combobox $w.slice -state readonly -textvariable ::analog_lens::slice_label
    pack $w.slice -fill x -pady {0 10}; bind $w.slice <<ComboboxSelected>> ::analog_lens::select_slice
    # Pack this form before the flexible plot: it must remain usable at minimum size.
    ttk::labelframe $w.size -text {Sizing estimate} -style AL.TLabelframe -padding 10
    set col 0
    foreach {name title} {length {Length (µm)} gmid {gm/Id (1/V)} gm {Target gm (µS)}} {
        label $w.size.${name}label $title
        if {$name eq "length"} {ttk::combobox $w.size.$name -textvariable ::analog_lens::target_length -width 10 -state readonly
        } elseif {$name eq "gmid"} {ttk::entry $w.size.$name -textvariable ::analog_lens::target_gmid -width 12
        } else {ttk::entry $w.size.$name -textvariable ::analog_lens::target_gm_u -width 12}
        grid $w.size.${name}label -row 0 -column $col -sticky w -padx {0 12}
        grid $w.size.$name -row 1 -column $col -sticky ew -padx {0 12}
        grid columnconfigure $w.size $col -weight 1; incr col
        bind $w.size.$name <Return> {::analog_lens::calculate_size; break}
    }
    button $w.size.calc Calculate ::analog_lens::calculate_size
    grid $w.size.calc -row 1 -column 3 -sticky e
    ttk::label $w.result -textvariable ::analog_lens::sizing_text -style AL.TLabel -wraplength 750
    ttk::label $w.error -textvariable ::analog_lens::sizing_error -style AL.Error.TLabel -wraplength 750
    grid $w.result -in $w.size -row 2 -column 0 -columnspan 4 -sticky ew -pady {8 0}; wrapping $w.result
    grid $w.error -in $w.size -row 3 -column 0 -columnspan 4 -sticky ew; wrapping $w.error
    ttk::label $w.note -textvariable ::analog_lens::lut_note -style AL.Muted.TLabel -wraplength 750
    pack $w.note -side bottom -fill x -pady {6 0}; wrapping $w.note
    canvas $w.plot -background [dict get $colors field] -highlightthickness 1 \
        -highlightbackground [dict get $colors border] -height 240
    pack $w.plot -fill both -expand 1
    bind $w.plot <Configure> ::analog_lens::schedule_plot
    toggle_sizing
    # The window can close while its lookup data remains in this xschem session.
    $w.slice configure -values [dict keys $::analog_lens::slice_labels]
    if {$::analog_lens::lut_slice ne {}} {
        $w.size.length configure -values [lsort -real [dict keys [lut_curves $::analog_lens::lut_rows $::analog_lens::lut_slice gain]]]
    }
}

proc ::analog_lens::load_lut {} {
    variable lut_rows; variable lut_slices; variable slice_labels; variable slice_label; variable lut_file; variable window
    set path [tk_getOpenFile -parent $::analog_lens::window -title {Load measured gm/Id lookup data} -filetypes {{{CSV lookup table} .csv}}]
    if {$path eq {}} {return}
    set parsed [parse_lut [read_text $path]]
    set lut_rows $parsed; set lut_file $path; set lut_slices {}; set slice_labels {}
    foreach r $lut_rows {dict set lut_slices [dict get $r slice] 1}
    foreach s [dict keys $lut_slices] {
        lassign $s pdk model corner temp vds vsb width
        dict set slice_labels "$pdk · $model · $corner · $temp °C · Vds=$vds · Vsb=$vsb · W=$width µm" $s
    }
    set labels [dict keys $slice_labels]; $window.tabs.lut.slice configure -values $labels
    set ::analog_lens::lut_source [file tail $path]
    if {[lsearch -glob [dict keys $lut_slices] DEMO_ONLY*] >= 0} {append ::analog_lens::lut_source { · DEMO ONLY — synthetic data, not a characterized PDK}}
    set slice_label [lindex $labels 0]; select_slice
}
proc ::analog_lens::select_slice {} {
    variable slice_labels; variable slice_label; variable lut_slice; variable lut_rows; variable window; variable target_length
    if {![dict exists $slice_labels $slice_label]} {return}
    set lut_slice [dict get $slice_labels $slice_label]
    set lengths [lsort -real [dict keys [lut_curves $lut_rows $lut_slice gain]]]
    $window.tabs.lut.size.length configure -values $lengths; set target_length [lindex $lengths 0]
    set ::analog_lens::sizing_text {}; schedule_plot; update_run_controls
}
proc ::analog_lens::schedule_plot {} {
    variable plot_after
    if {$plot_after ne {}} {after cancel $plot_after}
    set plot_after [after 80 ::analog_lens::draw_plot]
}
proc ::analog_lens::draw_plot {} {
    variable window; variable plot_after; variable lut_rows; variable lut_slice; variable lut_y; variable lut_note; variable colors
    set plot_after {}; set c $window.tabs.lut.plot
    if {![winfo exists $c]} {return}
    $c delete all; set width [winfo width $c]; set height [winfo height $c]
    if {$width < 180 || $height < 140} {
        $c create text [expr {$width/2}] [expr {$height/2}] -text {Enlarge the window or use View data to read the curves.} \
            -width [expr {max(100,$width-24)}] -fill [dict get $colors muted] -font ALBody -justify center
        return
    }
    set curves [lut_curves $lut_rows $lut_slice $lut_y]
    if {![dict size $curves]} {
        set lut_note {No curves for this metric. Load lookup data or choose another curve.}
        $c create text [expr {$width/2}] [expr {$height/2}] -text "Load a lookup CSV to see process curves.\nA CSV template is included in the examples folder." -fill [dict get $colors muted] -font ALHeading -justify center
        return
    }
    set xs {}; set ys {}
    dict for {length points} $curves {foreach p $points {lappend xs [lindex $p 0]; lappend ys [lindex $p 1]}}
    set xmin [lindex [lsort -real $xs] 0]; set xmax [lindex [lsort -real $xs] end]
    set ymin [lindex [lsort -real $ys] 0]; set ymax [lindex [lsort -real $ys] end]
    if {$xmax <= $xmin} {set xmax [expr {$xmin+1}]}
    if {$ymax <= $ymin} {set ymax [expr {$ymin+1}]}
    set dy [expr {($ymax-$ymin)*0.1}]; set ymin [expr {max(0,$ymin-$dy)}]; set ymax [expr {$ymax+$dy}]
    set left [expr {max(88,[font measure ALBody [eng $ymax]]+24)}]; set right [expr {$width-28}]; set top 26; set bottom [expr {$height-65}]
    for {set i 0} {$i <= 4} {incr i} {
        set x [expr {$left+($right-$left)*$i/4.0}]; set y [expr {$bottom-($bottom-$top)*$i/4.0}]
        $c create line $left $y $right $y -fill [dict get $colors grid]
        $c create text [expr {$left-10}] $y -anchor e -text [eng [expr {$ymin+($ymax-$ymin)*$i/4.0}]] -fill [dict get $colors muted] -font ALBody
        $c create text $x [expr {$bottom+15}] -text [format %.3g [expr {$xmin+($xmax-$xmin)*$i/4.0}]] -fill [dict get $colors muted] -font ALBody
    }
    $c create line $left $top $left $bottom $right $bottom -fill [dict get $colors border]
    $c create text [expr {($left+$right)/2}] [expr {$bottom+39}] -text {gm/Id (1/V)} -fill [dict get $colors fg] -font ALBody
    set labels [dict create gain {Intrinsic gain (V/V)} ft {fT estimate (Hz)} density {Current density (A/µm)}]
    $c create text $left 12 -anchor w -text [dict get $labels $lut_y] -fill [dict get $colors fg] -font ALHeading
    set series_colors [dict get $colors curves]; set dashes {{} {8 3} {3 3} {8 3 2 3} {12 4} {2 4}}; set n 0; set legend {}
    dict for {length points} $curves {
        set coords {}; set color [lindex $series_colors [expr {$n%6}]]
        foreach p $points {
            lassign $p x y
            lappend coords [expr {$left+($x-$xmin)/($xmax-$xmin)*($right-$left)}] [expr {$bottom-($y-$ymin)/($ymax-$ymin)*($bottom-$top)}]
        }
        if {[llength $coords] >= 4} {$c create line {*}$coords -fill $color -width 2.5 -dash [lindex $dashes [expr {$n%6}]]}
        # Label each curve directly at its last point. Offsets spread nearby labels.
        if {[llength $coords]} {
            $c create text [lindex $coords end-1] [expr {[lindex $coords end]-10-($n%2)*12}] -anchor e -text "$length µm" -fill $color -font ALBody
        }
        lappend legend "L=$length µm"; incr n
    }
    set lut_note "[join $legend {   ·   }]\nFixed model, corner, bias, temperature and reference width."
    set r [chosen]
    if {$r ne {}} {
        set v [get $r values]; set x [number [get $v gmid]]; set y [number [get $v $lut_y]]
        set model [get $r model]; set lutmodel [lindex $lut_slice 1]
        regsub {^(sky130_fd_pr__|gf180mcu_fd_pr__)} $model {} model
        regsub {^(sky130_fd_pr__|gf180mcu_fd_pr__)} $lutmodel {} lutmodel
        if {$model eq $lutmodel && $lut_y ne "density" && $x ne {} && $y ne {} && $x >= $xmin && $x <= $xmax && $y >= $ymin && $y <= $ymax} {
            set px [expr {$left+($x-$xmin)/($xmax-$xmin)*($right-$left)}]; set py [expr {$bottom-($y-$ymin)/($ymax-$ymin)*($bottom-$top)}]
            $c create oval [expr {$px-5}] [expr {$py-5}] [expr {$px+5}] [expr {$py+5}] -fill [dict get $colors fg] -outline [dict get $colors field] -width 2
            append lut_note "\nDot: [get $r name], actual circuit result. Confirm its corner, temperature and bias match this curve."
        }
    }
}
proc ::analog_lens::calculate_size {} {
    variable lut_rows; variable lut_slice; variable target_length; variable target_gmid; variable target_gm_u
    variable sizing_text; variable sizing_error; variable window
    set sizing_text {}; set sizing_error {}
    foreach {name value title} [list gmid $target_gmid {gm/Id} gm $target_gm_u {Target gm}] {
        set w $window.tabs.lut.size.$name; $w state !invalid
        if {[number $value] eq {} || $value <= 0} {
            set sizing_error "$title must be a finite number greater than zero."
            $w state invalid; focus $w; return
        }
    }
    if {[catch {sizing $lut_rows $lut_slice $target_length $target_gmid $target_gm_u} result]} {
        set sizing_error $result
        $window.tabs.lut.size.gmid state invalid; focus $window.tabs.lut.size.gmid; return
    }
    set sizing_text "Estimated Id: [eng [get $result id] A]   ·   Total width: [format %.4g [get $result width]] µm\nWidth scaling is an estimate. Map to the PDK's fingers/multiplicity and verify by simulation."
}

proc ::analog_lens::build_compare {w} {
    pack [label $w.title {Compare before and after} AL.Heading.TLabel] -anchor w -pady {0 6}
    ttk::label $w.info -text {Keep a baseline, edit the circuit, then run operating point again at the same hierarchy level.} -style AL.Muted.TLabel -wraplength 780
    pack $w.info -fill x -pady {0 12}; wrapping $w.info
    ttk::frame $w.actions -style AL.TFrame; pack $w.actions -fill x -pady {0 12}
    pack [button $w.keep {Keep current results as baseline} ::analog_lens::keep_baseline] -in $w.actions -side left
    pack [button $w.copy {Copy comparison} [list ::analog_lens::copy_table $w.tree]] -in $w.actions -side right
    ttk::label $w.summary -textvariable ::analog_lens::compare_summary -style AL.Muted.TLabel -wraplength 780
    pack $w.summary -fill x -pady {0 8}; wrapping $w.summary
    pack [label $w.note {Baseline stays in memory for this session. Copy comparison to retain both runs.} AL.Muted.TLabel] -side bottom -fill x -pady {10 0}
    wrapping $w.note
    ttk::frame $w.table; pack $w.table -fill both -expand 1
    ttk::treeview $w.tree -columns {name old new delta oldgain newgain} -show headings -style AL.Treeview -height 6
    foreach {key title} {name Device old {Baseline gm/Id} new {Current gm/Id} delta {Change (%)} oldgain {Baseline gm/gds} newgain {Current gm/gds}} {
        $w.tree heading $key -text $title
        set width [expr {max(125,[font measure ALHeading $title]+24)}]
        $w.tree column $key -width $width -minwidth $width -anchor [expr {$key eq "name" ? "w" : "e"}]
    }
    ttk::scrollbar $w.y -command [list $w.tree yview]
    ttk::scrollbar $w.x -orient horizontal -command [list $w.tree xview]
    $w.tree configure -yscrollcommand [list $w.y set] -xscrollcommand [list $w.x set]
    grid $w.tree -in $w.table -row 0 -column 0 -sticky nsew
    grid $w.y -in $w.table -row 0 -column 1 -sticky ns
    grid $w.x -in $w.table -row 1 -column 0 -sticky ew
    grid columnconfigure $w.table 0 -weight 1; grid rowconfigure $w.table 0 -weight 1
}

proc ::analog_lens::keep_baseline {} {
    variable records; variable snapshot; variable active_context; variable snapshot_context; variable status
    if {![llength $records]} {error "Load or run an operating point first."}
    set snapshot $records; set snapshot_context $active_context; render_compare
    set status "Baseline saved for [llength $records] devices. Edit the circuit, then run operating point again."
}

proc ::analog_lens::render_compare {} {
    variable window; variable snapshot; variable records; variable snapshot_context; variable active_context; variable compare_summary
    set tree $window.tabs.compare.tree; if {![winfo exists $tree]} {return}
    $tree delete [$tree children {}]
    set_enabled $window.tabs.compare.copy 0
    if {![llength $snapshot]} {
        set compare_summary {No baseline yet. Load results, then keep a baseline to start a comparison.}; return
    }
    if {$snapshot_context ne $active_context} {
        set compare_summary "Baseline belongs to [lindex $snapshot_context 1] ([lindex $snapshot_context 2]). Return to that hierarchy to compare."; return
    }
    set old {}; foreach r $snapshot {dict set old [list [get $r name] [get $r model]] [get $r values]}
    foreach r $records {
        set key [list [get $r name] [get $r model]]; if {![dict exists $old $key]} {continue}
        set a [dict get $old $key]; set b [get $r values]; set delta {—}
        if {[get $a gmid] ne {} && [get $a gmid] > 0 && [get $b gmid] ne {}} {
            set delta [format {%+.2f} [expr {100*([get $b gmid]/[get $a gmid]-1)}]]
        }
        $tree insert {} end -values [list [get $r name] [eng [get $a gmid]] [eng [get $b gmid]] $delta [eng [get $a gain]] [eng [get $b gain]]]
    }
    set count [llength [$tree children {}]]
    set compare_summary "$count matched devices · Baseline: [lindex $snapshot_context 1] · Same device name and model required."
    if {!$count} {set compare_summary {No matching devices. Return to the baseline hierarchy and load results with the same device names and models.}}
    set_enabled $window.tabs.compare.copy [expr {$count > 0}]
}

proc ::analog_lens::build_setup {w} {
    pack [label $w.title {Bias targets} AL.Heading.TLabel] -anchor w -pady {0 6}
    pack [label $w.intro {Design checks for your circuit, not universal device limits.} AL.Muted.TLabel] -fill x -pady {0 12}
    wrapping $w.intro
    ttk::frame $w.targets -style AL.TFrame; pack $w.targets -fill x
    set col 0
    foreach {key title} {gmid_min {Min gm/Id (1/V)} gmid_max {Max gm/Id (1/V)} headroom_min {Min headroom (V)} current_floor {Current floor (A)}} {
        set ::analog_lens::edit_limits($key) [dict get $::analog_lens::limits $key]
        label $w.targets.${key}label $title
        ttk::entry $w.targets.$key -width 12 -textvariable ::analog_lens::edit_limits($key)
        grid $w.targets.${key}label -row 0 -column $col -sticky w -padx {0 12}
        grid $w.targets.$key -row 1 -column $col -sticky ew -padx {0 12}
        grid columnconfigure $w.targets $col -weight 1; incr col
        bind $w.targets.$key <Return> {::analog_lens::apply_targets; break}
    }
    ttk::frame $w.actions -style AL.TFrame; pack $w.actions -fill x -pady {10 12}
    pack [button $w.apply {Apply targets} ::analog_lens::apply_targets] -in $w.actions -side right
    ttk::label $w.message -textvariable ::analog_lens::targets_message -style AL.Muted.TLabel -wraplength 620
    pack $w.message -in $w.actions -side left -fill x -expand 1 -padx {0 12}; wrapping $w.message
    ttk::separator $w.separator; pack $w.separator -fill x -pady {0 12}
    pack [label $w.help_title {Workflow & reference} AL.Heading.TLabel] -anchor w -pady {0 8}
    ttk::frame $w.reference; pack $w.reference -fill both -expand 1
    set help "1  Open your top-level testbench with the PDK and models configured as usual.\n2  Click Operating point. The extension generates a separate netlist and saves transistor parameters automatically.\n3  Descend into your circuit. The list follows the current hierarchy. Select a transistor to inspect it.\n4  Load measured lookup CSV data in gm/Id explorer, or keep a baseline to compare an edit.\n\nPDK adapters\n• SKY130A (SKY130B naming compatibility): BSIM, sky130_fd_pr wrappers.\n• GF180MCU-D (A/B/C naming compatibility): BSIM, internal m0 devices.\n• IHP SG13G2 and SG13CMOS5L: PSP/OSDI, internal n<model> devices.\n• IHP vertical NPN: Ic, Ib, gm, go, Vbe, Vbc capture; MOS-only metrics remain unavailable.\n\nNgspice must be on PATH. The IIC-OSIC-TOOLS environment supplies PDK setup and OSDI loading. This version runs ngspice; VACASK and Xyce are not supported.\n\nOperating point preserves your source schematic. Its disposable netlist removes top-level .control blocks and analyses, retains models, sources and parameters, then inserts an OP run. Changes made only inside your .control block (alter, alterparam, pre_osdi, etc.) must also be present in the deck/environment, or use Load results from your own simulation.\n\nFor loaded DC/transient data, Sample and Dataset select the exact saved point. Missing parameters show —. No time interpolation or guessed values.\n\nUse Export CSV to save results. The lookup template and optional MAT converter are included in the extension folder."
    set modifier [expr {[tk windowingsystem] eq "aqua" ? "Command" : "Ctrl"}]
    append help "\n\nKeyboard shortcuts\n$modifier+F  Find a device\n$modifier+O  Load results\n$modifier+R  Refresh results\n$modifier+Shift+R  Run operating point\n$modifier+Shift+S  Export CSV\n$modifier+1–4  Switch tabs\n$modifier+W  Close this window\nTab / Shift+Tab  Move between controls\nReturn  Locate the selected device, calculate sizing, or apply the focused form\nEscape in search  Clear filters\n\nThe Sort menu is a keyboard-accessible alternative to clicking table headers. View data opens a table of the plotted lookup values."
    text $w.help -wrap word -height 8 -width 50; text_style $w.help
    $w.help insert end $help; $w.help configure -state disabled
    ttk::scrollbar $w.scroll -command [list $w.help yview]; $w.help configure -yscrollcommand [list $w.scroll set]
    grid $w.help -in $w.reference -row 0 -column 0 -sticky nsew
    grid $w.scroll -in $w.reference -row 0 -column 1 -sticky ns
    grid rowconfigure $w.reference 0 -weight 1; grid columnconfigure $w.reference 0 -weight 1
}

proc ::analog_lens::apply_targets {} {
    variable limits; variable edit_limits; variable targets_message; variable window; variable status
    set next {}; set targets_message {}
    set labels [dict create gmid_min {Minimum gm/Id} gmid_max {Maximum gm/Id} headroom_min {Minimum headroom} current_floor {Current floor}]
    foreach key [dict keys $labels] {$window.tabs.setup.targets.$key state !invalid}
    $window.tabs.setup.message configure -style AL.Error.TLabel
    foreach key [dict keys $labels] {
        set n [number $edit_limits($key)]
        if {$n eq {} || $n < 0} {
            set targets_message "[dict get $labels $key] must be a finite, nonnegative number."
            $window.tabs.setup.targets.$key state invalid; focus $window.tabs.setup.targets.$key; return
        }
        dict set next $key $n
    }
    if {[dict get $next gmid_min] >= [dict get $next gmid_max]} {
        set targets_message {Minimum gm/Id must be less than maximum gm/Id.}
        $window.tabs.setup.targets.gmid_min state invalid; focus $window.tabs.setup.targets.gmid_min; return
    }
    set limits $next
    if {[catch {refresh} message]} {set status $message; render}
    $window.tabs.setup.message configure -style AL.Muted.TLabel
    set targets_message {Targets applied to this session.}
}
