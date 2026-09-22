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
    variable flow_layouts {}; variable dialog_focus {}
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
    foreach {key background minimum} {fg bg 4.5 muted bg 4.5 error bg 4.5 warning field 4.5 border field 3} {
        dict set colors $key [readable_color [dict get $colors $key] [dict get $colors $background] $minimum]
    }
    set fg [dict get $colors fg]
    dict set colors field_fg [readable_color $fg $field 4.5]
    dict set colors field_error [readable_color [dict get $colors error] $field 4.5]
    dict set colors curves [lmap color [dict get $colors curves] {readable_color $color $field 3}]
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
    ttk::style configure AL.Treeview -font ALBody -foreground [dict get $colors field_fg] -rowheight [expr {[font metrics ALBody -linespace]+14}]
    ttk::style configure AL.Treeview.Heading -font ALHeading -padding {8 5}
    ttk::style configure AL.TButton -padding {12 6}
    ttk::style configure AL.Primary.TButton -padding {14 6} -font ALHeading
    foreach style {AL.TEntry AL.TCombobox AL.TSpinbox} {
        ttk::style configure $style -font ALBody -padding {5 4} -fieldbackground $field -foreground [dict get $colors field_fg]
        ttk::style map $style -foreground [list invalid [dict get $colors field_error]]
    }
    ttk::style configure AL.TNotebook -tabmargins {0 4 0 0}
    ttk::style configure AL.TNotebook.Tab -padding {14 8}
}
proc ::analog_lens::luminance {color} {
    set values {}
    foreach channel [winfo rgb . $color] {
        set v [expr {$channel/65535.}]
        lappend values [expr {$v <= .04045 ? $v/12.92 : pow(($v+.055)/1.055,2.4)}]
    }
    lassign $values r g b
    return [expr {.2126*$r+.7152*$g+.0722*$b}]
}
proc ::analog_lens::readable_color {preferred background minimum} {
    set a [luminance $preferred]; set b [luminance $background]
    if {(max($a,$b)+.05)/(min($a,$b)+.05) >= $minimum} {return $preferred}
    return [expr {($b+.05)/.05 >= 1.05/($b+.05) ? "#000000" : "#ffffff"}]
}
proc ::analog_lens::wrap_label {w width} {
    set width [expr {max(120,$width-4)}]
    if {[winfo exists $w] && [$w cget -wraplength] != $width} {$w configure -wraplength $width}
}
proc ::analog_lens::wrapping {w} {bind $w <Configure> {::analog_lens::wrap_label %W %w}}
proc ::analog_lens::text_style {w {mono 0}} {
    variable colors
    $w configure -background [dict get $colors field] -foreground [dict get $colors field_fg] \
        -font [expr {$mono ? "ALMono" : "ALBody"}] -relief flat -borderwidth 0 \
        -highlightthickness 1 -highlightbackground [dict get $colors border] \
        -highlightcolor [lindex [dict get $colors curves] 0] -padx 12 -pady 10 -takefocus 1
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
    copy_text [$window.tabs.op.canvas.content.panes.detail.text get 1.0 end-1c]
    set status {Device details copied.}
}
proc ::analog_lens::clear_search {} {
    variable search; variable only_review
    set search {}; set only_review 0; render
}
proc ::analog_lens::find_device {} {
    variable window
    $window.tabs select $window.tabs.op
    focus $window.tabs.op.canvas.content.filters.search
    $window.tabs.op.canvas.content.filters.search selection range 0 end
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
    set mod Control
    foreach {key action} {f find o load r refresh Shift-R run Shift-S export w close} {
        bind $window <$mod-$key> [list ::analog_lens::shortcut $action]
    }
    set i 0
    foreach tab {op lut compare setup design} {
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
    flow_controls $w {run cancel load refresh export log session} $width
    set filters $window.tabs.op.canvas.content.filters
    if {[winfo exists $filters]} {flow_controls $filters {find search clear review follow} [expr {max(300,$width-24)}]}
    $window.root.head.pdk configure -wraplength [expr {max(180,int($width*0.55))}]
    fit_lookup_layout
}
proc ::analog_lens::flow_controls {w names width} {
    # Independent rows avoid grid columns inheriting widths from other rows.
    set rows {}; set current {}; set used 0; set sizes {}
    foreach name $names {
        if {![winfo exists $w.$name]} {continue}
        set requested [expr {[winfo reqwidth $w.$name]+8}]
        lappend sizes $requested
        if {[llength $current] && $used+$requested > $width} {lappend rows $current; set current {}; set used 0}
        lappend current $name; incr used $requested
    }
    if {[llength $current]} {lappend rows $current}
    set key [list $rows $sizes]
    if {[get $::analog_lens::flow_layouts $w] eq $key && [winfo exists $w.flow0]} {return}
    dict set ::analog_lens::flow_layouts $w $key
    foreach name $names {if {[winfo exists $w.$name]} {pack forget $w.$name; grid forget $w.$name}}
    foreach row [winfo children $w] {if {[string match ${w}.flow* $row]} {pack forget $row}}
    set i 0
    foreach names $rows {
        set row $w.flow$i; incr i
        if {![winfo exists $row]} {ttk::frame $row -style AL.TFrame}
        pack $row -side top -fill x
        foreach name $names {pack $w.$name -in $row -side left -padx {0 8} -pady {0 4}; raise $w.$name $row}
    }
}

proc ::analog_lens::style_children {w} {
    foreach child [winfo children $w] {
        set class [winfo class $child]
        if {$class in {TButton TLabel TFrame TLabelframe TCheckbutton TEntry TCombobox TSpinbox Treeview}} {
            if {[$child cget -style] eq {}} {$child configure -style AL.$class}
        }
        style_children $child
    }
}
proc ::analog_lens::dialog_chrome {w initial {primary {}}} {
    set parent [winfo toplevel [winfo parent $w]]
    wm transient $w $parent
    dict set ::analog_lens::dialog_focus $w [focus]
    wm protocol $w WM_DELETE_WINDOW [list ::analog_lens::close_dialog $w]
    foreach key {Escape Control-w} {bind $w <$key> "[list ::analog_lens::close_dialog $w]; break"}
    style_children $w
    if {$primary ne {} && [winfo exists $primary]} {$primary configure -style AL.Primary.TButton}
    foreach button [list $w.actions.close $w.actions.cancel] {
        if {![winfo exists $button]} {continue}
        set command [$button cget -command]
        if {$command eq [list destroy $w] || $command eq [list ::analog_lens::safe [list destroy $w]]} {
            $button configure -command [list ::analog_lens::close_dialog $w]
        }
    }
    after idle [list ::analog_lens::dialog_initial_focus $w $initial]
}
proc ::analog_lens::dialog_initial_focus {w initial} {
    if {[winfo exists $w] && [winfo exists $initial]} {focus $initial}
}
proc ::analog_lens::close_dialog {w} {
    set target [get $::analog_lens::dialog_focus $w]
    dict unset ::analog_lens::dialog_focus $w
    destroy $w
    if {$target ne {} && [winfo exists $target]} {focus $target}
}
proc ::analog_lens::action_bar {w names} {
    flow_controls $w $names [expr {max(1,[winfo width $w]-24)}]
    bind $w <Configure> [format {::analog_lens::flow_controls %s %s [expr {%%w-24}]} [list $w] [list $names]]
}
proc ::analog_lens::tab_page {w} {
    set body [scroll_page $w]
    # Keep a usable table/chart height; short windows scroll the complete tab.
    bind $w.canvas <Configure> [list ::analog_lens::tab_region $w.canvas]
    bind $body <Configure> [list ::analog_lens::tab_region $w.canvas]
    set host [winfo toplevel $w]
    bind $host <FocusIn> +[list ::analog_lens::page_focus $w.canvas [list $body] %W]
    bind $host <Button-4> +[list ::analog_lens::page_wheel $w.canvas [list $body] %W -3]
    bind $host <Button-5> +[list ::analog_lens::page_wheel $w.canvas [list $body] %W 3]
    bind $host <MouseWheel> [format {+::analog_lens::page_wheel %s %s %%W [expr {-%%D/120}]} [list $w.canvas] [list $body]]
    return $body
}
proc ::analog_lens::tab_region {canvas} {
    if {![winfo exists $canvas]} {return}
    set height [expr {max([winfo height $canvas],[winfo reqheight $canvas.content])}]
    $canvas itemconfigure content -width [winfo width $canvas] -height $height
    page_region $canvas
}
proc ::analog_lens::tab_content_geometry {widget} {
    # Wrapped labels can change the requested height without resizing a body
    # whose canvas item has an explicit height. Recheck after child layout.
    foreach tab {op lut compare setup} {
        set canvas $::analog_lens::window.tabs.$tab.canvas
        if {[page_contains [list $canvas.content] $widget]} {
            set command [list ::analog_lens::tab_region $canvas]
            after cancel $command
            after idle $command
            return
        }
    }
}
proc ::analog_lens::dialog_page {w} {
    ttk::frame $w.page; pack $w.page -fill both -expand 1
    set body [scroll_page $w.page]
    bind $w <FocusIn> +[list ::analog_lens::page_focus $w.page.canvas [list $body] %W]
    bind $w <Button-4> +[list ::analog_lens::page_wheel $w.page.canvas [list $body] %W -3]
    bind $w <Button-5> +[list ::analog_lens::page_wheel $w.page.canvas [list $body] %W 3]
    bind $w <MouseWheel> [format {+::analog_lens::page_wheel %s %s %%W [expr {-%%D/120}]} [list $w.page.canvas] [list $body]]
    return $body
}
proc ::analog_lens::dialog_content {children} {
    foreach child $children {pack forget $child}
    foreach child $children {pack $child -fill x -pady {0 8}}
}
proc ::analog_lens::page_contains {roots widget} {
    foreach root $roots {if {$widget eq $root || [string match ${root}.* $widget]} {return 1}}
    return 0
}
proc ::analog_lens::page_focus {canvas roots widget} {
    # Tk also sends FocusIn to ancestors; only reveal the actual focus owner.
    if {[focus] ne $widget} {return}
    if {![winfo exists $canvas] || ![page_contains $roots $widget]} {return}
    if {[winfo height $canvas] < 80} {return}
    set total [lindex [$canvas cget -scrollregion] 3]
    if {$total <= 0} {return}
    set y [expr {[winfo rooty $widget]-[winfo rooty $canvas]+[$canvas canvasy 0]}]
    set target_height [winfo height $widget]
    if {[winfo class $widget] in {Text Treeview Canvas}} {set target_height [expr {min($target_height,60)}]}
    set bottom [expr {$y+$target_height}]; set height [winfo height $canvas]
    if {$y < [$canvas canvasy 0]} {$canvas yview moveto [expr {$y/double($total)}]}
    if {$bottom > [$canvas canvasy 0]+$height} {$canvas yview moveto [expr {($bottom-$height)/double($total)}]}
}
proc ::analog_lens::page_wheel {canvas roots widget delta} {
    if {![page_contains $roots $widget] || [winfo class $widget] in {Text Treeview TCombobox TSpinbox}} {return}
    $canvas yview scroll $delta units
}
proc ::analog_lens::log_area {w} {
    ttk::frame $w.logarea -padding {12 0}
    pack forget $w.log; $w.log configure -height 8
    ttk::scrollbar $w.logarea.scroll -command [list $w.log yview]
    $w.log configure -yscrollcommand [list $w.logarea.scroll set]
    pack $w.logarea.scroll -side right -fill y
    pack $w.log -in $w.logarea -fill both -expand 1; raise $w.log $w.logarea
}
proc ::analog_lens::invalidate_sizing {args} {
    variable sizing_text; variable sizing_error; variable window
    set sizing_text {}; set sizing_error {}
    foreach n {gmid gm length} {
        set w $window.tabs.lut.canvas.content.size.$n
        if {[winfo exists $w]} {$w state !invalid}
    }
}
proc ::analog_lens::constrain_panes {} {
    variable window
    set w $window.tabs.op.canvas.content.panes
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
    set w $window.tabs.lut.canvas.content
    if {$sizing_visible} {
        pack $w.size -before $w.note -side bottom -fill x -pady {10 0}
    } else {pack forget $w.size}
    fit_lookup_layout
    schedule_plot
}
proc ::analog_lens::select_metric {} {
    variable lut_metric_label; variable lut_y
    set lut_y [dict get [dict create {Intrinsic gain} gain {Estimated fT} ft {Current density} density] $lut_metric_label]
    reset_plot
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
    dict for {length points} [visible_curves] {
        foreach point $points {$t insert {} end -values [list $length [lindex $point 0] [lindex $point 1]]}
    }
    ttk::frame $w.root.actions -style AL.TFrame
    pack $w.root.actions -before $w.root.table -side bottom -fill x -pady {12 0}
    pack [button $w.root.actions.copy {Copy table} [list ::analog_lens::copy_table $t]] -side left
    pack [button $w.root.actions.close Close [list destroy $w]] -side right
    bind $w <Escape> [list destroy $w]
    set mod Control
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
