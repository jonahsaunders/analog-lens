# Presentation helpers. Keep styles and bindings local to Analog Lens: xschem
# shares this Tcl interpreter and owns the active ttk theme and system fonts.
namespace eval ::analog_lens {
    variable colors {}
    variable layout_after {}
    variable sort_key name; variable sort_desc 0; variable sort_label {}
    variable device_summary {}; variable empty_text {}; variable compare_summary {}
    variable sizing_error {}; variable targets_message {}
    variable lut_metric_label {Intrinsic gain}; variable lut_source {No lookup file loaded}
    variable log_follow 1; variable data_rows {}
    variable sizing_visible 0
}
proc ::analog_lens::configure_styles {} {
    variable colors
    set bg [ttk::style lookup TFrame -background]
    set fg [ttk::style lookup TLabel -foreground]
    set field [ttk::style lookup Treeview -background]
    if {$bg eq {}} {set bg #f5f5f7}
    if {$fg eq {}} {set fg #1d1d1f}
    if {$field eq {}} {set field white}
    lassign [winfo rgb . $bg] r g b
    set dark [expr {($r+$g+$b)/3 < 32768}]
    set colors [dict create bg $bg fg $fg field $field \
        muted [expr {$dark ? "#c2c2c8" : "#51515b"}] \
        warning [expr {$dark ? "#ffd08a" : "#854600"}] \
        error [expr {$dark ? "#ffb4ad" : "#b42318"}] \
        border [expr {$dark ? "#686870" : "#b8b8c0"}] \
        grid [expr {$dark ? "#45454d" : "#e4e4ea"}] \
        curves [expr {$dark ? {#80b5ff #73d5be #d7a6ff #ffd08a #ffafcd #bec7d5} : {#075cc9 #006d5b #8046a5 #945000 #a02f60 #42566f}}]]
    foreach {name source scale weight} {ALTitle TkDefaultFont 1.6 bold ALHeading TkDefaultFont 1.1 bold ALBody TkDefaultFont 1 normal ALMono TkFixedFont 1 normal} {
        if {$name ni [font names]} {font create $name}
        font configure $name {*}[font actual $source]
        set size [font actual $source -size]
        font configure $name -size [expr {int(round($size*$scale))}] -weight $weight
    }
    foreach style {AL.TFrame AL.TLabelframe} {ttk::style configure $style -background $bg}
    foreach style {AL.TLabel AL.TLabelframe.Label AL.TCheckbutton} {
        ttk::style configure $style -background $bg -foreground $fg -font ALBody
    }
    ttk::style configure AL.Title.TLabel -background $bg -foreground $fg -font ALTitle
    ttk::style configure AL.Heading.TLabel -background $bg -foreground $fg -font ALHeading
    ttk::style configure AL.Muted.TLabel -background $bg -foreground [dict get $colors muted] -font ALBody
    ttk::style configure AL.Error.TLabel -background $bg -foreground [dict get $colors error] -font ALBody
    ttk::style configure AL.Treeview -font ALBody -rowheight [expr {[font metrics ALBody -linespace]+14}]
    ttk::style configure AL.Treeview.Heading -font ALHeading -padding {8 5}
    ttk::style configure AL.TButton -padding {12 6}
    ttk::style configure AL.Primary.TButton -padding {14 6} -font ALHeading
    ttk::style configure AL.TNotebook -tabmargins {0 4 0 0}
    ttk::style configure AL.TNotebook.Tab -padding {14 8}
}
proc ::analog_lens::wrap_label {w width} {
    set width [expr {max(120,$width-4)}]
    if {[winfo exists $w] && [$w cget -wraplength] != $width} {$w configure -wraplength $width}
}
proc ::analog_lens::wrapping {w} {bind $w <Configure> {::analog_lens::wrap_label %W %w}}
proc ::analog_lens::text_style {w {mono 0}} {
    variable colors
    $w configure -background [dict get $colors field] -foreground [dict get $colors fg] \
        -font [expr {$mono ? "ALMono" : "ALBody"}] -relief flat -borderwidth 0 \
        -highlightthickness 1 -highlightbackground [dict get $colors border] -padx 12 -pady 10 -takefocus 1
}
proc ::analog_lens::set_enabled {w enabled} {
    if {[winfo exists $w]} {$w state [expr {$enabled ? "!disabled" : "disabled"}]}
}
proc ::analog_lens::integer_input {value} {
    return [expr {$value eq {} || [string is digit -strict $value]}]
}
proc ::analog_lens::copy_text {text} {
    variable window
    clipboard clear -displayof $window
    clipboard append -displayof $window -- $text
}
proc ::analog_lens::copy_detail {} {
    variable window; variable status
    if {[chosen] eq {}} {return}
    copy_text [$window.tabs.op.panes.detail.text get 1.0 end-1c]
    set status {Device details copied.}
}
proc ::analog_lens::clear_search {} {
    variable search; variable only_review
    set search {}; set only_review 0; render
}
proc ::analog_lens::find_device {} {
    variable window
    $window.tabs select $window.tabs.op
    focus $window.tabs.op.filters.search
    $window.tabs.op.filters.search selection range 0 end
}
proc ::analog_lens::open_tab {tab} {
    variable window
    show; $window.tabs select $window.tabs.$tab
}
proc ::analog_lens::menu_action {action} {
    variable window; variable run_channel; variable status
    show
    set button $window.root.tools.$action
    if {[$button instate disabled]} {
        set status [expr {$run_channel ne {} ? "Wait for the current run to finish. Run log shows progress." : "Load results or run operating point before exporting."}]
        return
    }
    $button invoke
}
proc ::analog_lens::shortcut {action} {
    variable window
    switch -- $action {
        find {find_device}
        close {close_window}
        default {
            set w $window.root.tools.$action
            if {[winfo exists $w] && ![$w instate disabled]} {$w invoke}
        }
    }
    return -code break
}
proc ::analog_lens::install_shortcuts {} {
    variable window
    set mod [expr {[tk windowingsystem] eq "aqua" ? "Command" : "Control"}]
    foreach {key action} {f find o load r refresh Shift-R run Shift-S export w close} {
        bind $window <$mod-$key> [list ::analog_lens::shortcut $action]
    }
    set i 0
    foreach tab {op lut compare setup} {
        incr i
        bind $window <$mod-Key-$i> [list $window.tabs select $window.tabs.$tab]
    }
    ttk::notebook::enableTraversal $window.tabs
}
proc ::analog_lens::schedule_layout {w} {
    variable window; variable layout_after
    if {$w ne $window || $layout_after ne {}} {return}
    set layout_after [after idle ::analog_lens::layout_toolbar]
}
proc ::analog_lens::layout_toolbar {} {
    variable window; variable layout_after
    set layout_after {}
    set w $window.root.tools
    if {![winfo exists $w]} {return}
    set width [expr {[winfo width $window.root]-40}]
    flow_controls $w {run load refresh export log} $width
    set filters $window.tabs.op.filters
    if {[winfo exists $filters]} {flow_controls $filters {find search clear review follow} [expr {max(300,$width-24)}]}
    $window.root.head.pdk configure -wraplength [expr {max(180,int($width*0.55))}]
}
proc ::analog_lens::flow_controls {w names width} {
    set used 0; set row 0; set col 0
    foreach name $names {
        set requested [expr {[winfo reqwidth $w.$name]+8}]
        if {$col && $used+$requested > $width} {incr row; set col 0; set used 0}
        grid $w.$name -row $row -column $col -sticky w -padx {0 8} -pady {0 4}
        incr col; incr used $requested
    }
}
proc ::analog_lens::invalidate_sizing {args} {
    variable sizing_text; variable sizing_error; variable window
    set sizing_text {}; set sizing_error {}
    foreach n {gmid gm length} {
        set w $window.tabs.lut.size.$n
        if {[winfo exists $w]} {$w state !invalid}
    }
}
proc ::analog_lens::constrain_panes {} {
    variable window
    set w $window.tabs.op.panes
    if {![winfo exists $w]} {return}
    set width [winfo width $w]
    if {$width < 500} {return}
    set minimum [expr {max([winfo reqwidth $w.detail.actions]+24,[font measure ALMono {Intrinsic gain    40 V/V}]+40)}]
    set upper [expr {max(240,$width-$minimum)}]
    set pos [$w sashpos 0]
    $w sashpos 0 [expr {max(240,min($pos,$upper))}]
}
proc ::analog_lens::toggle_sizing {} {
    variable window; variable sizing_visible
    set w $window.tabs.lut
    if {$sizing_visible} {
        pack $w.size -before $w.note -side bottom -fill x -pady {10 0}
    } else {pack forget $w.size}
    schedule_plot
}
proc ::analog_lens::select_metric {} {
    variable lut_metric_label; variable lut_y
    set lut_y [dict get [dict create {Intrinsic gain} gain {Estimated fT} ft {Current density} density] $lut_metric_label]
    schedule_plot
}
proc ::analog_lens::data_dialog {} {
    variable window; variable lut_rows; variable lut_slice; variable lut_y; variable lut_source; variable slice_label
    set w $window.data
    if {[winfo exists $w]} {destroy $w}
    toplevel $w; wm title $w {Lookup data · Analog Lens}; wm transient $w $window
    wm geometry $w 760x440; wm minsize $w 500 300
    ttk::frame $w.root -padding 16 -style AL.TFrame; pack $w.root -fill both -expand 1
    pack [label $w.root.title {Lookup data snapshot} AL.Heading.TLabel] -anchor w -pady {0 6}
    ttk::label $w.root.source -text "$lut_source\n$slice_label" -style AL.Muted.TLabel -wraplength 680
    pack $w.root.source -fill x -pady {0 12}; wrapping $w.root.source
    ttk::frame $w.root.table; pack $w.root.table -fill both -expand 1
    set t $w.root.table.tree
    ttk::treeview $t -columns {length gmid value} -show headings -style AL.Treeview
    set label [dict get [dict create gain {Intrinsic gain (V/V)} ft {Estimated fT (Hz)} density {Current density (A/µm)}] $lut_y]
    foreach {key title} [list length {Length (µm)} gmid {gm/Id (1/V)} value $label] {
        $t heading $key -text $title; $t column $key -width 190 -minwidth 120 -anchor e
    }
    ttk::scrollbar $w.root.table.y -command [list $t yview]
    ttk::scrollbar $w.root.table.x -orient horizontal -command [list $t xview]
    $t configure -yscrollcommand [list $w.root.table.y set] -xscrollcommand [list $w.root.table.x set]
    grid $t -row 0 -column 0 -sticky nsew; grid $w.root.table.y -row 0 -column 1 -sticky ns
    grid $w.root.table.x -row 1 -column 0 -sticky ew
    grid columnconfigure $w.root.table 0 -weight 1; grid rowconfigure $w.root.table 0 -weight 1
    dict for {length points} [lut_curves $lut_rows $lut_slice $lut_y] {
        foreach point $points {$t insert {} end -values [list $length {*}$point]}
    }
    ttk::frame $w.root.actions -style AL.TFrame
    pack $w.root.actions -before $w.root.table -side bottom -fill x -pady {12 0}
    pack [button $w.root.actions.copy {Copy table} [list ::analog_lens::copy_table $t]] -side left
    pack [button $w.root.actions.close Close [list destroy $w]] -side right
    bind $w <Escape> [list destroy $w]
    set mod [expr {[tk windowingsystem] eq "aqua" ? "Command" : "Control"}]
    bind $w <$mod-w> [list destroy $w]
    focus $t
}
proc ::analog_lens::copy_table {tree} {
    set headers {}; foreach col [$tree cget -columns] {lappend headers [$tree heading $col -text]}
    set lines [list [join $headers \t]]
    foreach row [$tree children {}] {lappend lines [join [$tree item $row -values] \t]}
    copy_text [join $lines \n]
    set ::analog_lens::status {Table copied.}
}
