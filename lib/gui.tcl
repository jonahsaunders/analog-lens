namespace eval ::analog_lens {
    variable window .analog_lens
    variable detail_title {Select a transistor}; variable detail_subtitle {}; variable summary {}
    variable lut_file {}; variable slice_labels {}; variable slice_label {}; variable sizing_text {}
    variable plot_after {}; variable watch_key {}
}
proc ::analog_lens::safe {command} {
    variable status
    if {[catch {uplevel #0 $command} msg]} {
        set status $msg
        if {$command eq "::analog_lens::refresh"} {catch {render}}
        tk_messageBox -title {Analog Lens} -icon warning -type ok -message $msg
    }
}
proc ::analog_lens::install_menu {} {
    if {![llength [info commands winfo]] || ![llength [info commands xschem]]} {return}
    set bar [xschem get top_path].menubar
    if {![winfo exists $bar] || [winfo exists $bar.analog_lens]} {return}
    set m $bar.analog_lens; menu $m -tearoff 0
    $m add command -label {Open Analog Lens…} -command ::analog_lens::show
    $m add command -label {Inspect selected transistor} -command {::analog_lens::show; ::analog_lens::follow_selection}
    $m add separator
    $m add command -label {Run operating point} -command {::analog_lens::show; ::analog_lens::safe ::analog_lens::run_op}
    $m add command -label {Load results…} -command {::analog_lens::show; ::analog_lens::safe ::analog_lens::load_results}
    $bar add cascade -label {Analog Lens} -menu $m
}
proc ::analog_lens::active_pdk {} {
    if {[info exists ::env(PDK)]} {return $::env(PDK)}
    return {auto-detect from symbols}
}
proc ::analog_lens::button {path label command} {
    ttk::button $path -text $label -style AL.TButton -command [list ::analog_lens::safe $command]
    return $path
}
proc ::analog_lens::label {path text {style AL.TLabel}} {ttk::label $path -text $text -style $style; return $path}
proc ::analog_lens::show {} {
    variable window; variable status; variable timer; variable summary
    if {[winfo exists $window]} {raise $window; focus $window; return}
    ttk::style configure AL.TFrame -background #f3f5f8
    ttk::style configure AL.TLabel -background #f3f5f8 -foreground #27364b
    ttk::style configure AL.Title.TLabel -background #f3f5f8 -foreground #14233b -font {TkDefaultFont 19 bold}
    ttk::style configure AL.Heading.TLabel -background #f3f5f8 -foreground #14233b -font {TkDefaultFont 12 bold}
    ttk::style configure AL.Muted.TLabel -background #f3f5f8 -foreground #536579
    ttk::style configure AL.Treeview -rowheight 29 -font {TkDefaultFont 10}
    ttk::style configure AL.Treeview.Heading -font {TkDefaultFont 10 bold}
    ttk::style configure AL.TButton -padding {12 7}
    toplevel $window; wm title $window {Analog Lens · xschem}; wm geometry $window 1180x800; wm minsize $window 900 640
    wm protocol $window WM_DELETE_WINDOW ::analog_lens::close_window
    ttk::frame $window.root -style AL.TFrame -padding 18; pack $window.root -fill both -expand 1
    set root $window.root
    ttk::frame $root.head -style AL.TFrame; pack $root.head -fill x -pady {0 14}
    pack [label $root.head.title {Analog Lens} AL.Title.TLabel] -side left
    set summary "PDK: [active_pdk]  ·  ngspice"
    ttk::label $root.head.pdk -textvariable ::analog_lens::summary -style AL.Muted.TLabel; pack $root.head.pdk -side right
    ttk::frame $root.tools -style AL.TFrame; pack $root.tools -fill x -pady {0 14}
    foreach {n text cmd} {run {▶  Operating point} run_op load {Load results…} load_results refresh Refresh refresh export {Export CSV…} export_dialog log {Run log} log_dialog} {
        pack [button $root.tools.$n $text ::analog_lens::$cmd] -side left -padx {0 8}
    }
    ttk::notebook $window.tabs; pack $window.tabs -in $root -fill both -expand 1
    foreach {n title} {op {Operating point} lut {gm/Id explorer} compare {Compare runs} setup {Setup & help}} {
        ttk::frame $window.tabs.$n -style AL.TFrame -padding 14
        $window.tabs add $window.tabs.$n -text " $title "
        build_$n $window.tabs.$n
    }
    ttk::label $root.status -textvariable ::analog_lens::status -style AL.Muted.TLabel -wraplength 1080
    pack $root.status -fill x -pady {12 0}
    if {[catch {refresh} msg]} {set status $msg; render}
    update_run_controls
    set timer [after 800 ::analog_lens::tick]
}
proc ::analog_lens::close_window {} {
    variable window; variable timer; variable plot_after
    foreach id [list $timer $plot_after] {if {$id ne {}} {after cancel $id}}
    set timer {}; set plot_after {}; destroy $window
}
proc ::analog_lens::build_op {w} {
    ttk::frame $w.filters -style AL.TFrame; pack $w.filters -fill x -pady {0 12}
    label $w.filters.find {Find device}
    ttk::entry $w.filters.search -textvariable ::analog_lens::search -width 20
    bind $w.filters.search <KeyRelease> ::analog_lens::render
    ttk::checkbutton $w.filters.review -text {Needs review only} -variable ::analog_lens::only_review -command ::analog_lens::render
    ttk::checkbutton $w.filters.follow -text {Follow schematic selection} -variable ::analog_lens::live
    foreach n {find search review follow} {pack $w.filters.$n -side left -padx {0 10}}
    ttk::frame $w.point -style AL.TFrame; pack $w.point -fill x -pady {0 12}
    label $w.point.type_label {Load analysis}
    ttk::combobox $w.point.type -textvariable ::analog_lens::analysis_type -values {op dc tran} -state readonly -width 6
    foreach n {type_label type} {pack $w.point.$n -side left -padx {0 10}}
    foreach n {sample dataset} {
        pack [label $w.point.${n}_label [string totitle $n]] -side left -padx {0 8}
        ttk::spinbox $w.point.$n -from 0 -to 100000000 -width 8 -textvariable ::analog_lens::$n -command {::analog_lens::safe ::analog_lens::refresh}
        pack $w.point.$n -side left -padx {0 16}
        bind $w.point.$n <Return> {::analog_lens::safe ::analog_lens::refresh}
    }
    pack [button $w.point.color {Color by gm/Id} ::analog_lens::color_devices] -side right
    ttk::panedwindow $w.panes -orient horizontal; pack $w.panes -fill both -expand 1
    ttk::frame $w.panes.list -style AL.TFrame; ttk::frame $w.panes.detail -style AL.TFrame -padding {16 0 0 0}
    $w.panes add $w.panes.list -weight 3; $w.panes add $w.panes.detail -weight 2
    set l $w.panes.list
    ttk::treeview $l.tree -columns {name type id gmid gain margin status} -show headings -selectmode browse -style AL.Treeview
    foreach {key text width} {name Device 105 type Type 60 id {Id / Ic} 90 gmid {gm/Id · 1/V} 100 gain {gm/gds} 80 margin {Margin · V} 90 status Check 80} {
        $l.tree heading $key -text $text -command [list ::analog_lens::sort_table $key]
        $l.tree column $key -width $width -minwidth 55
    }
    $l.tree tag configure review -foreground #9b4b0b; $l.tree tag configure missing -foreground #718096
    ttk::scrollbar $l.scroll -command [list $l.tree yview]
    ttk::scrollbar $l.horizontal -orient horizontal -command [list $l.tree xview]
    $l.tree configure -yscrollcommand [list $l.scroll set] -xscrollcommand [list $l.horizontal set]
    grid $l.tree -row 0 -column 0 -sticky nsew; grid $l.scroll -row 0 -column 1 -sticky ns; grid $l.horizontal -row 1 -column 0 -sticky ew
    grid rowconfigure $l 0 -weight 1; grid columnconfigure $l 0 -weight 1
    bind $l.tree <<TreeviewSelect>> ::analog_lens::inspect_selection
    bind $l.tree <Double-1> {::analog_lens::safe ::analog_lens::locate}
    set d $w.panes.detail
    ttk::label $d.title -textvariable ::analog_lens::detail_title -style AL.Heading.TLabel
    ttk::label $d.subtitle -textvariable ::analog_lens::detail_subtitle -style AL.Muted.TLabel -wraplength 300
    pack $d.title $d.subtitle -anchor w -pady {0 8}
    text $d.text -wrap word -height 15 -width 32 -font {TkFixedFont 10} -relief flat -background #f3f5f8 -foreground #27364b -state disabled
    pack $d.text -fill both -expand 1
    pack [button $d.locate {Locate in schematic} ::analog_lens::locate] -fill x -pady {8 4}
    pack [button $d.annotate {Place annotation} ::analog_lens::place_annotation] -fill x
}
proc ::analog_lens::render {} {
    variable records; variable search; variable only_review; variable window; variable selected
    set tree $window.tabs.op.panes.list.tree
    if {![winfo exists $tree]} {return}
    set before $selected; $tree delete [$tree children {}]; set i -1
    foreach r $records {
        incr i; set v [get $r values]
        if {$only_review && [get $v status] ne "Review"} {continue}
        if {$search ne {} && [string first [string tolower $search] [string tolower "[get $r name] [get $r model]"]] < 0} {continue}
        set tag [expr {[get $v status] eq "Review" ? "review" : "normal"}]
        if {[get $v gm] eq {}} {set tag missing}
        $tree insert {} end -id d$i -tags $tag -values [list [get $r name] [get $r type] [eng [get $v id] A] [eng [get $v gmid]] [eng [get $v gain]] [eng [get $v headroom]] [get $v status]]
        if {[get $r name] eq $before} {$tree selection set d$i}
    }
    if {![llength [$tree children {}]]} {
        set ::analog_lens::detail_title {No devices to display}
        set ::analog_lens::detail_subtitle {Run Operating point, load results, or descend into your circuit.}
        set_detail {}
    } elseif {![llength [$tree selection]]} {$tree selection set [lindex [$tree children {}] 0]}
    inspect_selection; render_compare
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
    set_detail $text; schedule_plot
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
proc ::analog_lens::sort_table {key} {
    variable window; variable records
    set tree $window.tabs.op.panes.list.tree
    set map [dict create id id gmid gmid gain gain margin headroom]; set pairs {}
    foreach item [$tree children {}] {
        set r [lindex $records [string range $item 1 end]]
        if {[dict exists $map $key]} {
            set value [number [get [get $r values] [dict get $map $key]]]; if {$value eq {}} {set value -Inf}
        } elseif {$key eq "status"} {set value [get [get $r values] status]} else {set value [get $r $key]}
        lappend pairs [list $value $item]
    }
    set mode [expr {[dict exists $map $key] ? "-real" : "-dictionary"}]
    foreach p [lsort $mode -index 0 $pairs] {$tree move [lindex $p 1] {} end}
}
proc ::analog_lens::place_annotation {} {
    variable root
    set r [chosen]; if {$r eq {}} {error "Select a device first."}
    set name [get $r name]
    if {![regexp {^[A-Za-z0-9_:.]+$} $name]} {error "Use the inspector for array elements; annotation symbols currently require scalar names."}
    xschem place_symbol [file join $root symbols analog_lens.sym] "name=analoglens1 ref=$name"
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
    variable window; variable run_channel
    if {![winfo exists $window]} {return}
    set state [expr {$run_channel eq {} ? "normal" : "disabled"}]
    foreach n {run load refresh} {$window.root.tools.$n configure -state $state}
}
proc ::analog_lens::export_dialog {} {
    variable records
    if {![llength $records]} {error "Load or run an operating point first."}
    set path [tk_getSaveFile -title {Export transistor analysis} -defaultextension .csv -initialfile analog-lens-report.csv]
    if {$path ne {}} {export_report $path; set ::analog_lens::status "Saved: $path"}
}
proc ::analog_lens::log_dialog {} {
    variable run_log; variable window
    set w $window.log; if {[winfo exists $w]} {destroy $w}
    toplevel $w; wm title $w {Analog Lens · ngspice log}
    text $w.text -wrap word -width 100 -height 28 -font TkFixedFont
    ttk::scrollbar $w.scroll -command [list $w.text yview]; $w.text configure -yscrollcommand [list $w.scroll set]
    pack $w.scroll -side right -fill y; pack $w.text -fill both -expand 1
    $w.text insert end [expr {$run_log eq {} ? "No operating-point run yet." : $run_log}]; $w.text configure -state disabled
}
proc ::analog_lens::build_lut {w} {
    ttk::frame $w.tools -style AL.TFrame; pack $w.tools -fill x -pady {0 10}
    pack [button $w.tools.load {Load lookup CSV…} ::analog_lens::load_lut] -side left -padx {0 12}
    pack [label $w.tools.label Curve] -side left -padx {0 8}
    ttk::combobox $w.tools.metric -state readonly -values {gain ft density} -textvariable ::analog_lens::lut_y -width 10
    pack $w.tools.metric -side left -padx {0 12}; bind $w.tools.metric <<ComboboxSelected>> ::analog_lens::schedule_plot
    pack [label $w.tools.hint {gain = gm/gds · ft = estimated Hz · density = A/µm} AL.Muted.TLabel] -side left
    pack [label $w.slice_label {PDK / model / corner / temperature / Vds / Vsb / reference width}] -anchor w -pady {0 5}
    ttk::combobox $w.slice -state readonly -textvariable ::analog_lens::slice_label
    pack $w.slice -fill x -pady {0 10}; bind $w.slice <<ComboboxSelected>> ::analog_lens::select_slice
    canvas $w.plot -background white -highlightthickness 1 -highlightbackground #d5dce6 -height 260
    pack $w.plot -fill both -expand 1; bind $w.plot <Configure> ::analog_lens::schedule_plot
    ttk::label $w.note -textvariable ::analog_lens::lut_note -style AL.Muted.TLabel -wraplength 1030
    pack $w.note -fill x -pady {8 12}
    ttk::labelframe $w.size -text {Sizing estimate} -padding 10; pack $w.size -fill x
    foreach {name text} {length {Length (µm)} gmid {gm/Id (1/V)} gm {Target gm (µS)}} {
        ttk::label $w.size.${name}label -text $text; pack $w.size.${name}label -side left -padx {0 6}
        if {$name eq "length"} {ttk::combobox $w.size.$name -textvariable ::analog_lens::target_length -width 8 -state readonly
        } elseif {$name eq "gmid"} {ttk::entry $w.size.$name -textvariable ::analog_lens::target_gmid -width 8
        } else {ttk::entry $w.size.$name -textvariable ::analog_lens::target_gm_u -width 9}
        pack $w.size.$name -side left -padx {0 14}
    }
    pack [button $w.size.calc Calculate ::analog_lens::calculate_size] -side right
    ttk::label $w.result -textvariable ::analog_lens::sizing_text -style AL.TLabel -wraplength 1030
    pack $w.result -fill x -pady {10 0}
}
proc ::analog_lens::load_lut {} {
    variable lut_rows; variable lut_slices; variable slice_labels; variable slice_label; variable lut_file; variable window
    set path [tk_getOpenFile -title {Load measured gm/Id lookup data} -filetypes {{{CSV lookup table} .csv}}]
    if {$path eq {}} {return}
    set parsed [parse_lut [read_text $path]]
    set lut_rows $parsed; set lut_file $path; set lut_slices {}; set slice_labels {}
    foreach r $lut_rows {dict set lut_slices [dict get $r slice] 1}
    foreach s [dict keys $lut_slices] {
        lassign $s pdk model corner temp vds vsb width
        dict set slice_labels "$pdk · $model · $corner · $temp °C · Vds=$vds · Vsb=$vsb · W=$width µm" $s
    }
    set labels [dict keys $slice_labels]; $window.tabs.lut.slice configure -values $labels
    set slice_label [lindex $labels 0]; select_slice
}
proc ::analog_lens::select_slice {} {
    variable slice_labels; variable slice_label; variable lut_slice; variable lut_rows; variable window; variable target_length
    if {![dict exists $slice_labels $slice_label]} {return}
    set lut_slice [dict get $slice_labels $slice_label]
    set lengths [lsort -real [dict keys [lut_curves $lut_rows $lut_slice gain]]]
    $window.tabs.lut.size.length configure -values $lengths; set target_length [lindex $lengths 0]
    set ::analog_lens::sizing_text {}; schedule_plot
}
proc ::analog_lens::schedule_plot {} {
    variable plot_after
    if {$plot_after ne {}} {after cancel $plot_after}
    set plot_after [after 80 ::analog_lens::draw_plot]
}
proc ::analog_lens::draw_plot {} {
    variable window; variable plot_after; variable lut_rows; variable lut_slice; variable lut_y; variable lut_note
    set plot_after {}; set c $window.tabs.lut.plot
    if {![winfo exists $c]} {return}
    $c delete all; set width [winfo width $c]; set height [winfo height $c]
    if {$width < 100 || $height < 100} {return}
    set curves [lut_curves $lut_rows $lut_slice $lut_y]
    if {![dict size $curves]} {
        $c create text [expr {$width/2}] [expr {$height/2}] -text "Load a lookup CSV to see process curves.\nA CSV template is included in the examples folder." -fill #536579 -font {TkDefaultFont 12} -justify center
        return
    }
    set xs {}; set ys {}
    dict for {length points} $curves {foreach p $points {lappend xs [lindex $p 0]; lappend ys [lindex $p 1]}}
    set xmin [lindex [lsort -real $xs] 0]; set xmax [lindex [lsort -real $xs] end]
    set ymin [lindex [lsort -real $ys] 0]; set ymax [lindex [lsort -real $ys] end]
    if {$xmax <= $xmin} {set xmax [expr {$xmin+1}]}
    if {$ymax <= $ymin} {set ymax [expr {$ymin+1}]}
    set dy [expr {($ymax-$ymin)*0.1}]; set ymin [expr {max(0,$ymin-$dy)}]; set ymax [expr {$ymax+$dy}]
    set left 88; set right [expr {$width-28}]; set top 26; set bottom [expr {$height-65}]
    for {set i 0} {$i <= 4} {incr i} {
        set x [expr {$left+($right-$left)*$i/4.0}]; set y [expr {$bottom-($bottom-$top)*$i/4.0}]
        $c create line $left $y $right $y -fill #edf0f5
        $c create text [expr {$left-10}] $y -anchor e -text [eng [expr {$ymin+($ymax-$ymin)*$i/4.0}]] -fill #536579 -font {TkDefaultFont 10}
        $c create text $x [expr {$bottom+15}] -text [format %.3g [expr {$xmin+($xmax-$xmin)*$i/4.0}]] -fill #536579 -font {TkDefaultFont 10}
    }
    $c create line $left $top $left $bottom $right $bottom -fill #9caabd
    $c create text [expr {($left+$right)/2}] [expr {$bottom+39}] -text {gm/Id (1/V)} -fill #27364b -font {TkDefaultFont 11}
    set labels [dict create gain {Intrinsic gain (V/V)} ft {fT estimate (Hz)} density {Current density (A/µm)}]
    $c create text $left 12 -anchor w -text [dict get $labels $lut_y] -fill #27364b -font {TkDefaultFont 10 bold}
    set colors {#2563eb #0e897f #9b4bba #c16b17 #b33360 #34516b}; set n 0; set legend {}
    dict for {length points} $curves {
        set coords {}; set color [lindex $colors [expr {$n%6}]]
        foreach p $points {
            lassign $p x y
            lappend coords [expr {$left+($x-$xmin)/($xmax-$xmin)*($right-$left)}] [expr {$bottom-($y-$ymin)/($ymax-$ymin)*($bottom-$top)}]
        }
        if {[llength $coords] >= 4} {$c create line {*}$coords -fill $color -width 2.5 -dash [expr {$n < 6 ? "" : "6 3"}]}
        # Label each curve directly at its last point. Offsets spread nearby labels.
        if {[llength $coords]} {
            $c create text [lindex $coords end-1] [expr {[lindex $coords end]-10-($n%2)*12}] -anchor e -text "$length µm" -fill $color -font {TkDefaultFont 10}
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
            $c create oval [expr {$px-5}] [expr {$py-5}] [expr {$px+5}] [expr {$py+5}] -fill #172b4d -outline white -width 2
            append lut_note "\nDot: [get $r name], actual circuit result. Confirm its corner, temperature and bias match this curve."
        }
    }
}
proc ::analog_lens::calculate_size {} {
    variable lut_rows; variable lut_slice; variable target_length; variable target_gmid; variable target_gm_u; variable sizing_text
    set result [sizing $lut_rows $lut_slice $target_length $target_gmid $target_gm_u]
    set sizing_text "Estimated Id: [eng [get $result id] A]   ·   Total width: [format %.4g [get $result width]] µm\nLinear width-scaling estimate at the selected bias. Map total width to the PDK's W/finger/multiplier convention and verify with simulation."
}
proc ::analog_lens::build_compare {w} {
    ttk::label $w.info -text {Keep a baseline, adjust the circuit, then run Operating point again. Compare devices at the same hierarchy level.} -style AL.TLabel -wraplength 950
    pack $w.info -anchor w -pady {0 12}
    pack [button $w.keep {Keep current results as baseline} ::analog_lens::keep_baseline] -anchor w -pady {0 14}
    ttk::treeview $w.tree -columns {name old new delta oldgain newgain} -show headings -style AL.Treeview
    foreach {key text} {name Device old {Baseline gm/Id} new {Current gm/Id} delta {Change (%)} oldgain {Baseline gm/gds} newgain {Current gm/gds}} {
        $w.tree heading $key -text $text; $w.tree column $key -width 135 -minwidth 100
    }
    pack $w.tree -fill both -expand 1
    pack [label $w.note {Baselines stay in memory for this xschem session. Export CSV to keep a report.} AL.Muted.TLabel] -anchor w -pady {10 0}
}
proc ::analog_lens::keep_baseline {} {
    variable records; variable snapshot; variable active_context; variable snapshot_context
    if {![llength $records]} {error "Load or run an operating point first."}
    set snapshot $records; set snapshot_context $active_context; render_compare
}
proc ::analog_lens::render_compare {} {
    variable window; variable snapshot; variable records; variable snapshot_context; variable active_context
    set tree $window.tabs.compare.tree; if {![winfo exists $tree]} {return}
    $tree delete [$tree children {}]
    if {$snapshot_context ne $active_context} {return}
    set old {}; foreach r $snapshot {dict set old [list [get $r name] [get $r model]] [get $r values]}
    foreach r $records {
        set key [list [get $r name] [get $r model]]; if {![dict exists $old $key]} {continue}
        set a [dict get $old $key]; set b [get $r values]; set delta {}
        if {[get $a gmid] ne {} && [get $a gmid] > 0 && [get $b gmid] ne {}} {set delta [expr {100*([get $b gmid]/[get $a gmid]-1)}]}
        $tree insert {} end -values [list [get $r name] [eng [get $a gmid]] [eng [get $b gmid]] [eng $delta] [eng [get $a gain]] [eng [get $b gain]]]
    }
}
proc ::analog_lens::build_setup {w} {
    pack [label $w.title {Your existing xschem project, with analysis alongside it.} AL.Heading.TLabel] -anchor w -pady {0 12}
    set help "1  Open your top-level testbench with the PDK and models configured as usual.\n2  Click Operating point. The extension generates a separate netlist and saves transistor parameters automatically.\n3  Descend into your circuit. The list follows the current hierarchy. Select a transistor to inspect it.\n4  Load measured lookup CSV data in gm/Id explorer, or keep a baseline to compare an edit.\n\nPDK adapters\n• SKY130A (SKY130B naming compatibility): BSIM, sky130_fd_pr wrappers.\n• GF180MCU-D (A/B/C naming compatibility): BSIM, internal m0 devices.\n• IHP SG13G2 and SG13CMOS5L: PSP/OSDI, internal n<model> devices.\n• IHP vertical NPN: Ic, Ib, gm, go, Vbe, Vbc capture; MOS-only metrics remain unavailable.\n\nNgspice must be on PATH. The IIC-OSIC-TOOLS environment supplies PDK setup and OSDI loading. This version runs ngspice; VACASK and Xyce are not supported.\n\nOperating point preserves your source schematic. Its disposable netlist removes top-level .control blocks and analyses, retains models, sources and parameters, then inserts an OP run. Changes made only inside your .control block (alter, alterparam, pre_osdi, etc.) must also be present in the deck/environment, or use Load results from your own simulation.\n\nFor loaded DC/transient data, Sample and Dataset select the exact saved point. Missing parameters show —. No time interpolation or guessed values.\n\nUse Export CSV to save results. The lookup template and optional MAT converter are included in the extension folder."
    text $w.help -wrap word -height 14 -font {TkDefaultFont 10} -relief flat -background #f3f5f8 -foreground #27364b
    $w.help insert end $help; $w.help configure -state disabled; pack $w.help -fill both -expand 1
    ttk::labelframe $w.targets -text {Bias targets — configurable checks, not universal device limits} -padding 10
    pack $w.targets -fill x -pady {12 0}
    set col 0
    foreach {key text} {gmid_min {Min gm/Id} gmid_max {Max gm/Id} headroom_min {Min margin (V)} current_floor {Current floor (A)}} {
        set ::analog_lens::edit_limits($key) [dict get $::analog_lens::limits $key]
        ttk::label $w.targets.${key}label -text $text
        ttk::entry $w.targets.$key -width 10 -textvariable ::analog_lens::edit_limits($key)
        grid $w.targets.${key}label -row 0 -column $col -sticky w -padx {0 14}
        grid $w.targets.$key -row 1 -column $col -sticky ew -padx {0 14}; grid columnconfigure $w.targets $col -weight 1; incr col
    }
    pack [button $w.apply {Apply targets} ::analog_lens::apply_targets] -anchor e -pady {8 0}
}
proc ::analog_lens::apply_targets {} {
    variable limits; variable edit_limits
    set next {}
    foreach key {gmid_min gmid_max headroom_min current_floor} {
        set n [number $edit_limits($key)]; if {$n eq {} || $n < 0} {error "$key must be finite and nonnegative."}; dict set next $key $n
    }
    if {[dict get $next gmid_min] >= [dict get $next gmid_max]} {error "Minimum gm/Id must be below maximum."}
    set limits $next; refresh
}
