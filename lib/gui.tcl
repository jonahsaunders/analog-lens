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
                    set w $window.tabs.op.canvas.content.point.$key
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
    $m add command -label {Show inspector sidebar} -command {::analog_lens::sidebar_action ::analog_lens::show_sidebar}
    $m add command -label {Open analysis window} -command ::analog_lens::show
    $m add command -label {Run testbench} -command {::analog_lens::sidebar_action ::analog_lens::run_testbench}
    $m add command -label {Inspect selected transistor} -command {::analog_lens::show; ::analog_lens::follow_selection}
    $m add separator
    foreach {name title} {run {Run operating point} load {Load results…} refresh {Refresh results} export {Export CSV…} log {Run log}} {
        $m add command -label $title -command [list ::analog_lens::menu_action $name]
    }
    $m add separator
    foreach {name title} {design {Size & verify} lut {gm/Id explorer} compare {Compare runs} setup {Setup & help}} {
        $m add command -label $title -command [list ::analog_lens::open_tab $name]
    }
    $m add separator
    $m add command -label {Open session…} -command {::analog_lens::show; ::analog_lens::safe {::analog_lens::session_dialog open}}
    $m add command -label {Save session…} -command {::analog_lens::show; ::analog_lens::safe {::analog_lens::session_dialog save}}
    $m add command -label {Check environment} -command {::analog_lens::show; ::analog_lens::check_environment}
    $m add command -label {Set up this project…} -command ::analog_lens::setup_dialog
    $m add command -label {Project results…} -command {::analog_lens::sidebar_action ::analog_lens::results_dialog}
    $m add command -label {Project settings…} -command ::analog_lens::project_settings
    $m add command -label {Characterize selected model…} -command {::analog_lens::sidebar_action ::analog_lens::characterize_dialog}
    $bar add cascade -label {Analog Lens} -menu $m
    after idle ::analog_lens::start_integration
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
    foreach {n text cmd} {run {Run operating point} run_op cancel Cancel cancel_run load {Load results…} load_results refresh Refresh refresh export {Export CSV…} export_dialog log {Run log} log_dialog} {
        button $root.tools.$n $text ::analog_lens::$cmd
    }
    ttk::menubutton $root.tools.session -text Session -menu $root.tools.session.menu -style AL.TButton
    menu $root.tools.session.menu -tearoff 0
    $root.tools.session.menu add command -label {Open session…} -command {::analog_lens::safe {::analog_lens::session_dialog open}}
    $root.tools.session.menu add command -label {Save session…} -command {::analog_lens::safe {::analog_lens::session_dialog save}}
    $root.tools.session.menu add separator
    $root.tools.session.menu add command -label {Check environment} -command ::analog_lens::check_environment
    $root.tools.session.menu add command -label {Set up this project…} -command ::analog_lens::setup_dialog
    $root.tools.session.menu add command -label {Project results…} -command {::analog_lens::safe ::analog_lens::results_dialog}
    $root.tools.session.menu add command -label {Project integration…} -command ::analog_lens::project_settings
    $root.tools.session.menu add command -label {Show inspector sidebar} -command {::analog_lens::sidebar_action ::analog_lens::show_sidebar}
    $root.tools.run configure -style AL.Primary.TButton
    layout_toolbar
    ttk::progressbar $root.progress -mode indeterminate -length 160
    ttk::label $root.elapsed -textvariable ::analog_lens::run_feedback -style AL.Muted.TLabel -wraplength 800
    wrapping $root.elapsed
    ttk::notebook $window.tabs -style AL.TNotebook
    # Reserve feedback before the expanding content so it survives short windows.
    ttk::label $root.status -textvariable ::analog_lens::status -style AL.Muted.TLabel -wraplength 850
    pack $root.status -side bottom -fill x -pady {10 0}; wrapping $root.status
    ttk::label $root.freshness -textvariable ::analog_lens::freshness -style AL.Muted.TLabel -wraplength 850
    pack $root.freshness -side bottom -fill x; wrapping $root.freshness
    pack $window.tabs -in $root -fill both -expand 1
    foreach {n title} {op {Operating point} lut {gm/Id explorer} compare {Compare runs} setup {Setup & help} design {Size & verify}} {
        ttk::frame $window.tabs.$n -style AL.TFrame -padding 12
        $window.tabs add $window.tabs.$n -text $title
        if {$n eq "design"} {
            build_$n $window.tabs.$n
        } else {
            build_$n [tab_page $window.tabs.$n]
        }
    }
    bind $window.tabs <<NotebookTabChanged>> ::analog_lens::workflow_toolbar
    install_shortcuts
    bind $window <Configure> {::analog_lens::schedule_layout %W; ::analog_lens::tab_content_geometry %W}
    bind $root <Configure> [list ::analog_lens::schedule_layout $window]
    foreach var {target_length target_gmid target_gm_u} {
        trace add variable ::analog_lens::$var write ::analog_lens::invalidate_sizing
    }
    trace add variable ::analog_lens::run_log write ::analog_lens::update_log
    if {[catch {refresh} msg]} {set status $msg; render}
    style_children $window
    update_run_controls
    restore_layout
    set timer [after 800 ::analog_lens::tick]
    focus $root.tools.run
}

proc ::analog_lens::close_window {} {
    variable window; variable timer; variable plot_after; variable layout_after
    set ::analog_lens::session_geometry "[winfo width $window]x[winfo height $window]"
    set ::analog_lens::session_sash [$window.tabs.op.canvas.content.panes sashpos 0]
    foreach id [list $timer $plot_after $layout_after] {if {$id ne {}} {after cancel $id}}
    set timer {}; set plot_after {}; set layout_after {}
    foreach var {target_length target_gmid target_gm_u} {
        trace remove variable ::analog_lens::$var write ::analog_lens::invalidate_sizing
    }
    trace remove variable ::analog_lens::run_log write ::analog_lens::update_log
    catch {project_flush}
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
    set tree $window.tabs.op.canvas.content.panes.list.tree
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
    set empty $window.tabs.op.canvas.content.panes.list.empty
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
    set tree $window.tabs.op.canvas.content.panes.list.tree
    if {![winfo exists $tree] || ![llength [$tree selection]]} {return {}}
    return [lindex $records [string range [lindex [$tree selection] 0] 1 end]]
}
proc ::analog_lens::set_detail {text} {
    variable window
    set w $window.tabs.op.canvas.content.panes.detail.text
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
    set tree $window.tabs.op.canvas.content.panes.list.tree
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
    update_run_feedback
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
    set tree $window.tabs.op.canvas.content.panes.list.tree
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
    set_enabled $window.root.tools.cancel [expr {!$idle && !$::analog_lens::run_cancelled}]
    $window.root.tools.session.menu entryconfigure 0 -state [expr {$idle ? "normal" : "disabled"}]
    set_enabled $window.root.tools.export $current
    set_enabled $window.tabs.compare.canvas.content.keep $current
    set_enabled $window.tabs.op.canvas.content.point.color $current
    foreach n {locate annotate copy} {set_enabled $window.tabs.op.canvas.content.panes.detail.$n [expr {$current && [chosen] ne {}}]}
    foreach n {sample dataset} {
        set_enabled $window.tabs.op.canvas.content.point.$n $idle
        if {$current} {$window.tabs.op.canvas.content.point.$n state !invalid}
    }
    set w $window.tabs.op.canvas.content.point.type
    $w state [expr {$idle ? "!disabled readonly" : "disabled"}]
    set has_lut [expr {[llength $lut_rows] > 0 && $lut_slice ne {}}]
    set_enabled $window.tabs.lut.canvas.content.size.calc $has_lut
    set_enabled $window.tabs.lut.canvas.content.tools.data $has_lut
    set_enabled $window.tabs.lut.canvas.content.tools.sizing $has_lut
    update_run_feedback
    if {$idle} {
        $window.root.tools.run configure -text {Run operating point}
        $window.root.progress stop; pack forget $window.root.progress
        pack forget $window.root.elapsed
    } else {
        $window.root.tools.run configure -text {Running…}
        pack $window.root.progress -before $window.tabs -fill x -pady {0 8}
        pack $window.root.elapsed -before $window.root.progress -fill x -pady {0 4}
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
    set mod Control
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
    pack [button $w.tools.characterize {Characterize…} ::analog_lens::characterize_dialog] -side left -padx {0 10}
    ttk::combobox $w.tools.metric -state readonly -values {{Intrinsic gain} {Estimated fT} {Current density}} \
        -textvariable ::analog_lens::lut_metric_label -width 17
    pack $w.tools.metric -side left -padx {0 12}
    bind $w.tools.metric <<ComboboxSelected>> ::analog_lens::select_metric
    pack [button $w.tools.data {View data} ::analog_lens::data_dialog] -side right
    ttk::checkbutton $w.tools.sizing -text {Sizing estimate} -style AL.TCheckbutton -variable ::analog_lens::sizing_visible -command ::analog_lens::toggle_sizing
    pack $w.tools.sizing -side right -padx {0 12}
    ttk::label $w.source -textvariable ::analog_lens::lut_source -style AL.Muted.TLabel -wraplength 800
    pack $w.source -fill x -pady {0 8}; wrapping $w.source
    build_lookup_filters $w
    # Pack this form before the flexible plot: it must remain usable at minimum size.
    ttk::labelframe $w.size -text {Sizing estimate} -style AL.TLabelframe -padding 10
    set col 0
    foreach {name title} {length {Length (µm)} gmid {gm/Id (1/V)} gm {Target gm (µS)}} {
        label $w.size.${name}label $title
        if {$name eq "length"} {ttk::combobox $w.size.$name -textvariable ::analog_lens::target_display(target_length) -width 10 -state readonly
        } elseif {$name eq "gmid"} {ttk::entry $w.size.$name -textvariable ::analog_lens::target_display(target_gmid) -width 12
        } else {ttk::entry $w.size.$name -textvariable ::analog_lens::target_display(target_gm_u) -width 12}
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
    set col 0
    foreach {key title} {target_fingers {Fingers (blank: preserve)} target_copies {Copies (blank: preserve)} verification_tolerance {Target tolerance (%)}} {
        ttk::label $w.size.${key}label -text $title
        ttk::entry $w.size.$key -textvariable ::analog_lens::$key -width 12
        grid $w.size.${key}label -row 4 -column $col -sticky w -pady {8 0}
        grid $w.size.$key -row 5 -column $col -sticky ew -padx {0 12}
        incr col
    }
    button $w.size.preview {Preview schematic changes…} ::analog_lens::preview_size
    grid $w.size.preview -row 6 -column 0 -columnspan 4 -sticky w -pady {6 0}
    ttk::label $w.note -textvariable ::analog_lens::lut_note -style AL.Muted.TLabel -wraplength 750
    pack $w.note -side bottom -fill x -pady {6 0}; wrapping $w.note
    canvas $w.plot -background [dict get $colors field] -highlightthickness 1 \
        -highlightbackground [dict get $colors border] -height 240
    pack $w.plot -fill both -expand 1
    bind $w.plot <Configure> ::analog_lens::schedule_plot
    toggle_sizing
    ttk::frame $w.charttools
    ttk::label $w.compact -text {Sizing view · Hide Sizing estimate to return to the chart. View data remains available.} -style AL.Muted.TLabel -wraplength 700
    wrapping $w.compact
    pack $w.charttools -before $w.plot -fill x -pady {0 4}
    foreach {name title command} {in {Zoom +} {::analog_lens::zoom_plot 0.7} out {Zoom −} {::analog_lens::zoom_plot 1.43} reset {Reset view} ::analog_lens::reset_plot export {Export SVG…} ::analog_lens::export_plot_dialog} {
        pack [button $w.charttools.$name $title $command] -side left -padx {0 6}
    }
    ttk::label $w.point -textvariable ::analog_lens::plot_point_text -style AL.Muted.TLabel -wraplength 700
    pack $w.point -before $w.plot -fill x -pady {0 4}; wrapping $w.point
    $w.plot configure -takefocus 1
    bind $w.plot <Button-1> {::analog_lens::inspect_plot %x %y}
    bind $w.plot <Left> {::analog_lens::step_plot_point -1; break}
    bind $w.plot <Right> {::analog_lens::step_plot_point 1; break}
    bind $w.plot <plus> {::analog_lens::zoom_plot 0.7; break}
    bind $w.plot <minus> {::analog_lens::zoom_plot 1.43; break}
    bind $w.plot <Home> {::analog_lens::reset_plot; break}
    bind $w <Configure> ::analog_lens::fit_lookup_layout
    rebuild_lookup_filters
}

proc ::analog_lens::load_lut {} {
    variable lut_rows; variable lut_slices; variable slice_labels; variable slice_label; variable lut_file; variable window
    set path [tk_getOpenFile -parent $::analog_lens::window -title {Load measured gm/Id lookup data} -filetypes {{{CSV lookup table} .csv}}]
    if {$path eq {}} {return}
    load_lookup_file $path
}
proc ::analog_lens::schedule_plot {} {
    variable plot_after
    if {$plot_after ne {}} {after cancel $plot_after}
    set plot_after [after 80 ::analog_lens::draw_plot]
}
proc ::analog_lens::draw_plot {} {
    variable window; variable plot_after; variable lut_rows; variable lut_slice; variable lut_y; variable lut_note; variable colors
    variable plot_view; variable plot_bounds; variable plot_points; variable plot_point_index
    set plot_points {}
    set plot_after {}; set c $window.tabs.lut.canvas.content.plot
    if {![winfo exists $c]} {return}
    $c delete all; set width [winfo width $c]; set height [winfo height $c]
    if {$width < 180 || $height < 140} {
        $c create text [expr {$width/2}] [expr {$height/2}] -text {Enlarge the window or use View data to read the curves.} \
            -width [expr {max(100,$width-24)}] -fill [dict get $colors muted] -font ALBody -justify center
        return
    }
    set curves [visible_curves]
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
    if {[llength $plot_view] == 4} {lassign $plot_view xmin xmax ymin ymax}
    set plot_bounds [list $xmin $xmax $ymin $ymax]
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
        set color [lindex $series_colors [expr {$n%6}]]; set previous {}; set last_visible {}
        foreach p $points {
            lassign $p x y
            if {$previous ne {}} {
                lassign $previous ax ay
                set clipped [clip_segment $ax $ay $x $y $plot_bounds]
                if {[llength $clipped]} {
                    set coords {}
                    foreach {cx cy} $clipped {lappend coords [expr {$left+($cx-$xmin)/($xmax-$xmin)*($right-$left)}] [expr {$bottom-($cy-$ymin)/($ymax-$ymin)*($bottom-$top)}]}
                    $c create line {*}$coords -fill $color -width 2.5 -dash [lindex $dashes [expr {$n%6}]]
                }
            }
            set previous [list $x $y]
            if {$x >= $xmin && $x <= $xmax && $y >= $ymin && $y <= $ymax} {
                set px [expr {$left+($x-$xmin)/($xmax-$xmin)*($right-$left)}]
                set py [expr {$bottom-($y-$ymin)/($ymax-$ymin)*($bottom-$top)}]
                lappend plot_points [list $px $py $length $x $y]; set last_visible [list $px $py]
                $c create oval [expr {$px-2}] [expr {$py-2}] [expr {$px+2}] [expr {$py+2}] -fill $color -outline $color
            }
        }
        if {$last_visible ne {}} {
            lassign $last_visible px py
            $c create text $px [expr {max($top+8,$py-10-($n%2)*12)}] -anchor e -text "$length µm" -fill $color -font ALBody
        }
        incr n
    }
    set warning [lookup_provenance_warning]
    set lut_note "$n curve(s) · Fixed model, corner, bias, temperature and reference width."
    if {$warning ne {}} {append lut_note "\n$warning"}
    set r [chosen]
    if {$r ne {}} {
        set v [get $r values]; set x [number [get $v gmid]]; set y [number [get $v $lut_y]]
        set model [get $r model]; set lutmodel [lindex $lut_slice 1]
        regsub {^(sky130_fd_pr__|gf180mcu_fd_pr__)} $model {} model
        regsub {^(sky130_fd_pr__|gf180mcu_fd_pr__)} $lutmodel {} lutmodel
        if {![string match {Overlay hidden:*} $warning] && $model eq $lutmodel && $lut_y ne "density" && $x ne {} && $y ne {} && $x >= $xmin && $x <= $xmax && $y >= $ymin && $y <= $ymax} {
            set px [expr {$left+($x-$xmin)/($xmax-$xmin)*($right-$left)}]; set py [expr {$bottom-($y-$ymin)/($ymax-$ymin)*($bottom-$top)}]
            $c create oval [expr {$px-5}] [expr {$py-5}] [expr {$px+5}] [expr {$py+5}] -fill [dict get $colors fg] -outline [dict get $colors field] -width 2
            append lut_note "\nDot: [get $r name], current circuit result."
        }
    }
    show_plot_point
}
proc ::analog_lens::calculate_size {} {
    variable lut_rows; variable lut_slice; variable target_length; variable target_gmid; variable target_gm_u
    variable sizing_text; variable sizing_error; variable window
    set sizing_text {}; set sizing_error {}
    if {[catch {normalize_sizing_inputs} why]} {set sizing_error "Sizing inputs must be finite numbers greater than zero. $why"; return}
    foreach {name value title} [list gmid $target_gmid {gm/Id} gm $target_gm_u {Target gm}] {
        set w $window.tabs.lut.canvas.content.size.$name; $w state !invalid
        if {[number $value] eq {} || $value <= 0} {
            set sizing_error "$title must be a finite number greater than zero."
            $w state invalid; focus $w; return
        }
    }
    if {[catch {sizing $lut_rows $lut_slice $target_length $target_gmid $target_gm_u} result]} {
        set sizing_error $result
        $window.tabs.lut.canvas.content.size.gmid state invalid; focus $window.tabs.lut.canvas.content.size.gmid; return
    }
    set sizing_text "Estimated Id: [eng [get $result id] A]   ·   Total width: [format %.4g [get $result width]] µm\nPreview maps total width to the finger/copy counts below. Verify the estimate by simulation."
}

proc ::analog_lens::build_compare {w} {
    pack [label $w.title {Compare saved runs} AL.Heading.TLabel] -anchor w -pady {0 6}
    pack [label $w.info {Name a baseline, edit the circuit, then rerun at the same hierarchy level.} AL.Muted.TLabel] -fill x -pady {0 10}
    wrapping $w.info
    ttk::frame $w.actions; pack $w.actions -fill x -pady {0 8}
    ttk::entry $w.actions.name -textvariable ::analog_lens::baseline_name -width 20
    pack $w.actions.name -side left -fill x -expand 1 -padx {0 8}
    pack [button $w.keep {Keep baseline} ::analog_lens::keep_baseline] -in $w.actions -side left
    pack [button $w.copy {Copy comparison} [list ::analog_lens::copy_table $w.tree]] -in $w.actions -side right
    ttk::frame $w.saved; pack $w.saved -fill x -pady {0 8}
    pack [label $w.saved.label Baseline] -side left -padx {0 8}
    ttk::combobox $w.saved.choice -state readonly -textvariable ::analog_lens::baseline_choice -values [dict keys $::analog_lens::baselines]
    pack $w.saved.choice -side left -fill x -expand 1 -padx {0 8}
    bind $w.saved.choice <<ComboboxSelected>> ::analog_lens::select_baseline
    pack [button $w.saved.export {Export comparison…} ::analog_lens::export_comparison_dialog] -side right
    ttk::label $w.summary -textvariable ::analog_lens::compare_summary -style AL.Muted.TLabel -wraplength 780
    pack $w.summary -fill x -pady {0 8}; wrapping $w.summary
    pack [label $w.note {Project sessions autosave. Session → Save session exports a separate copy for sharing or moving work.} AL.Muted.TLabel] -side bottom -fill x -pady {8 0}
    wrapping $w.note
    ttk::frame $w.table; pack $w.table -fill both -expand 1
    set columns {name state old new delta oldgain newgain change_gain}
    foreach metric {id headroom ft} {lappend columns old_$metric new_$metric change_$metric}
    ttk::treeview $w.tree -columns $columns -show headings -style AL.Treeview -height 6
    set titles [dict create name Device state Status old {Baseline gm/Id} new {Current gm/Id} delta {gm/Id change (%)} oldgain {Baseline gain} newgain {Current gain} change_gain {Gain change}]
    foreach metric {id headroom ft} title {Id Headroom {Estimated fT}} {
        dict set titles old_$metric "Baseline $title"; dict set titles new_$metric "Current $title"; dict set titles change_$metric "$title change"
    }
    foreach key $columns {
        set title [dict get $titles $key]; $w.tree heading $key -text $title
        set width [expr {max(115,[font measure ALHeading $title]+24)}]
        $w.tree column $key -width $width -minwidth $width -anchor [expr {$key in {name state} ? "w" : "e"}]
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
    variable records; variable baselines; variable baseline_name; variable baseline_choice; variable active_context; variable result_metadata; variable status
    if {![llength $records]} {error "Load or run an operating point first."}
    set name [string trim $baseline_name]
    if {$name eq {}} {set name "Run [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]"}
    set unique $name; set i 1
    while {[dict exists $baselines $unique]} {set unique "$name ([incr i])"}
    dict set baselines $unique [dict create records $records context $active_context metadata $result_metadata]
    set baseline_choice $unique; set baseline_name {}; select_baseline
    catch {archive_baseline $unique [dict get $baselines $unique]}
    set status "Baseline '$unique' kept. Save the session to retain it after restarting xschem."
}
proc ::analog_lens::render_compare {} {
    variable window; variable snapshot; variable records; variable snapshot_context; variable active_context; variable compare_summary
    variable snapshot_metadata; variable result_metadata; variable comparison_rows
    set tree $window.tabs.compare.canvas.content.tree; if {![winfo exists $tree]} {return}
    $tree delete [$tree children {}]; set comparison_rows {}
    set_enabled $window.tabs.compare.canvas.content.copy 0; set_enabled $window.tabs.compare.canvas.content.saved.export 0
    if {![llength $snapshot]} {set compare_summary {No baseline yet. Load results, then keep a named baseline.}; return}
    if {[context_key $snapshot_context] ne [context_key $active_context]} {
        set compare_summary "Baseline belongs to [lindex $snapshot_context 1] ([lindex $snapshot_context 2]). Return to that hierarchy to compare."; return
    }
    if {![llength $records]} {set compare_summary {Load current results to compare with this baseline.}; return}
    set comparison_rows [comparison_data $snapshot $records]
    set counts [dict create Matched 0 Added 0 Removed 0]
    foreach r $comparison_rows {
        dict incr counts [get $r state]
        set delta [get $r percent_gmid]; if {$delta eq {}} {set delta —} else {set delta [format {%+.2f} $delta]}
        set values [list [get $r name] [get $r state] [eng [get $r old_gmid]] [eng [get $r new_gmid]] $delta [eng [get $r old_gain]] [eng [get $r new_gain]] [eng [get $r change_gain]]]
        foreach metric {id headroom ft} unit {A V Hz} {
            foreach prefix {old new change} {lappend values [eng [get $r ${prefix}_$metric] $unit]}
        }
        $tree insert {} end -values $values
    }
    set compare_summary "[dict get $counts Matched] matched · [dict get $counts Added] added · [dict get $counts Removed] removed"
    set differences [condition_differences $snapshot_metadata $result_metadata]
    if {[llength $differences]} {append compare_summary "\nConditions differ: [join $differences {; }]"}
    set unknown {}
    foreach key {pdk corner temp_c vds_v vsb_v} {
        if {[get $snapshot_metadata $key] eq {} || [get $result_metadata $key] eq {}} {lappend unknown [condition_label $key]}
    }
    if {[llength $unknown]} {append compare_summary "\nConditions unverified: [join $unknown {, }]. Record known values in Setup & help."}
    set_enabled $window.tabs.compare.canvas.content.copy 1; set_enabled $window.tabs.compare.canvas.content.saved.export 1
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
    pack [button $w.environment {Check IIC environment} ::analog_lens::check_environment] -anchor w -pady {0 8}
    ttk::labelframe $w.conditions -text {Result conditions (optional, user-declared)} -padding 8
    pack $w.conditions -fill x -pady {0 8}
    set col 0
    foreach key {corner temp_c vds_v vsb_v} title {Corner {Temperature (°C)} {Vds (V)} {Vsb (V)}} {
        set ::analog_lens::edit_conditions($key) [get $::analog_lens::declared $key]
        label $w.conditions.${key}label $title
        ttk::entry $w.conditions.$key -width 10 -textvariable ::analog_lens::edit_conditions($key)
        grid $w.conditions.${key}label -row 0 -column $col -sticky w -padx {0 8}
        grid $w.conditions.$key -row 1 -column $col -sticky ew -padx {0 8}
        grid columnconfigure $w.conditions $col -weight 1; incr col
    }
    button $w.conditions.apply Record ::analog_lens::apply_conditions
    grid $w.conditions.apply -row 1 -column 4 -sticky e
    ttk::label $w.conditions.message -textvariable ::analog_lens::conditions_message -style AL.Muted.TLabel -wraplength 700
    grid $w.conditions.message -row 2 -column 0 -columnspan 5 -sticky ew; wrapping $w.conditions.message
    ttk::separator $w.separator; pack $w.separator -fill x -pady {0 8}
    pack [label $w.help_title {Workflow & reference} AL.Heading.TLabel] -anchor w -pady {0 8}
    ttk::frame $w.reference; pack $w.reference -fill both -expand 1
    set help "INTEGRATED WORKFLOW\nThe sidebar follows the selected transistor. Run testbench uses xschem’s normal simulation and preserves its control commands. Project settings selects the result file/plot and enables cursor B tracking. Saved testbenches autosave targets, baselines and lookup choices.\n\nCharacterize runs real installed-PDK sweeps. Size selected opens the explorer; Preview schematic changes lists edits before Apply. Size & verify keeps targets, geometry preview and measured verification together. Blank finger/copy counts preserve the current geometry; explicit counts use the supported PDK limits. One xschem Undo restores the edit. Return to the top level to rerun after editing subcircuits.\n\nISOLATED OPERATING POINT\n1  Open your top-level testbench with the PDK and models configured as usual.\n2  Click Operating point. The extension generates a separate netlist and saves transistor parameters automatically.\n3  Descend into your circuit. The list follows the current hierarchy. Select a transistor to inspect it.\n4  Load measured lookup CSV data, or keep a named baseline to compare an edit.\n5  Save the session to retain baselines, targets, lookup choices and layout.\n\nCancel stops only the simulator started by Analog Lens. Closing the window lets it continue.\n\nChart: select a length, inspect samples with Left/Right, zoom with +/−, and reset with Home. Export SVG saves the current view.\n\nUse Set up this project for optional setup checks and result-path selection. Use this device’s conditions copies known values; unknown fields remain blank. Target gm accepts 800 µS or 0.8 mS. Installed corner sections are offered when available. Optional result conditions are user-declared; they do not change simulation settings.\n\nPDK adapters\n• SKY130A (SKY130B naming compatibility): BSIM, sky130_fd_pr wrappers.\n• GF180MCU-D (A/B/C naming compatibility): BSIM, internal m0 devices.\n• IHP SG13G2 and SG13CMOS5L: PSP/OSDI, internal n<model> devices.\n• IHP vertical NPN: Ic, Ib, gm, go, Vbe, Vbc capture; MOS-only metrics remain unavailable.\n\nNgspice must be on PATH. The IIC-OSIC-TOOLS environment supplies PDK setup and OSDI loading. This version runs ngspice; VACASK and Xyce are not supported.\n\nOperating point preserves your source schematic. Its disposable netlist removes top-level .control blocks and analyses, retains models, sources and parameters, then inserts an OP run. Changes made only inside your .control block (alter, alterparam, pre_osdi, etc.) must also be present in the deck/environment, or use Load results from your own simulation.\n\nFor loaded DC/transient data, Sample and Dataset select the exact saved point. Missing parameters show —. No time interpolation or guessed values.\n\nUse Export CSV to save results. The lookup template and optional MAT converter are included in the extension folder."
    set modifier Ctrl
    append help "\n\nKeyboard shortcuts\n$modifier+F  Find a device\n$modifier+O  Load results\n$modifier+R  Refresh results\n$modifier+Shift+R  Run operating point\n$modifier+Shift+S  Export CSV\n$modifier+1–5  Switch tabs\n$modifier+W  Close this window\nTab / Shift+Tab  Move between controls\nReturn  Locate the selected device, calculate sizing, or apply the focused form\nEscape in search  Clear filters\n\nThe Sort menu is a keyboard-accessible alternative to clicking table headers. View data opens a table of the plotted lookup values."
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
    foreach key [dict keys $labels] {$window.tabs.setup.canvas.content.targets.$key state !invalid}
    $window.tabs.setup.canvas.content.message configure -style AL.Error.TLabel
    foreach key [dict keys $labels] {
        set n [number $edit_limits($key)]
        if {$n eq {} || $n < 0} {
            set targets_message "[dict get $labels $key] must be a finite, nonnegative number."
            $window.tabs.setup.canvas.content.targets.$key state invalid; focus $window.tabs.setup.canvas.content.targets.$key; return
        }
        dict set next $key $n
    }
    if {[dict get $next gmid_min] >= [dict get $next gmid_max]} {
        set targets_message {Minimum gm/Id must be less than maximum gm/Id.}
        $window.tabs.setup.canvas.content.targets.gmid_min state invalid; focus $window.tabs.setup.canvas.content.targets.gmid_min; return
    }
    set limits $next
    if {[catch {refresh} message]} {set status $message; render}
    $window.tabs.setup.canvas.content.message configure -style AL.Muted.TLabel
    set targets_message {Targets applied to this session.}
}
