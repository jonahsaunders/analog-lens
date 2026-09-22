# Faceted lookup selection and inspectable, exportable plots.
namespace eval ::analog_lens {
    variable lut_filter; array set lut_filter {pdk {} model {} corner {} temp {} vds {} vsb {} width {}}
    variable lut_length All; variable plot_view {}; variable plot_bounds {}; variable plot_points {}
    variable plot_point_index -1; variable plot_point_text {Click a curve sample, or focus the chart and use Left/Right.}
}
proc ::analog_lens::build_lookup_filters {w} {
    ttk::frame $w.filters -style AL.TFrame; pack $w.filters -fill x -pady {0 8}
    set i 0
    foreach key {pdk model corner temp vds vsb width length} title {PDK Model Corner {Temp °C} {Vds V} {Vsb V} {Ref W µm} {L µm}} {
        set cell $w.filters.$key; ttk::frame $cell
        grid $cell -row 0 -column $i -sticky ew -padx {0 6} -pady {0 4}
        grid columnconfigure $w.filters $i -weight [expr {$i < 2 ? 2 : 1}]
        pack [label $cell.label $title AL.Muted.TLabel] -anchor w
        set var [expr {$key eq "length" ? "::analog_lens::lut_length" : "::analog_lens::lut_filter($key)"}]
        ttk::combobox $cell.value -state readonly -width 5 -textvariable $var
        pack $cell.value -fill x
        if {$key eq "length"} {bind $cell.value <<ComboboxSelected>> ::analog_lens::reset_plot} else {
            bind $cell.value <<ComboboxSelected>> [list ::analog_lens::choose_lookup_filter $key]
        }
        incr i
    }
    rebuild_lookup_filters
}
proc ::analog_lens::rebuild_lookup_filters {} {
    variable lut_rows; variable lut_slice; variable lut_filter; variable lut_slices; variable slice_labels
    variable lut_file; variable lut_source
    set lut_slices {}; set slice_labels {}
    foreach r $lut_rows {dict set lut_slices [dict get $r slice] 1}
    foreach s [dict keys $lut_slices] {dict set slice_labels [join $s { · }] $s}
    if {![dict exists $lut_slices $lut_slice]} {set lut_slice [lindex [dict keys $lut_slices] 0]}
    foreach key {pdk model corner temp vds vsb width} value $lut_slice {set lut_filter($key) $value}
    set lut_source [expr {$lut_file eq {} ? "No lookup file loaded" : [file tail $lut_file]}]
    if {[lsearch -glob [dict keys $lut_slices] DEMO_ONLY*] >= 0} {append lut_source { · DEMO ONLY — synthetic data}}
    choose_lookup_filter pdk
}
proc ::analog_lens::choose_lookup_filter {changed} {
    variable lut_slices; variable lut_filter; variable lut_slice; variable slice_label; variable window
    variable target_length; variable lut_rows; variable lut_length
    set candidates [dict keys $lut_slices]; set index 0
    foreach key {pdk model corner temp vds vsb width} {
        set options {}; foreach s $candidates {lappend options [lindex $s $index]}
        if {$index < 3} {set options [lsort -unique $options]} else {set options [lsort -real -unique $options]}
        if {$lut_filter($key) ni $options} {set lut_filter($key) [lindex $options 0]}
        set w $window.tabs.lut.filters.$key.value
        if {[winfo exists $w]} {$w configure -values $options}
        set next {}; foreach s $candidates {if {[lindex $s $index] eq $lut_filter($key)} {lappend next $s}}
        set candidates $next; incr index
    }
    set lut_slice [lindex $candidates 0]; set slice_label [join $lut_slice { · }]
    set lengths [lsort -real [dict keys [lut_curves $lut_rows $lut_slice gain]]]
    if {$target_length ni $lengths} {set target_length [lindex $lengths 0]}
    if {$lut_length ni $lengths} {set lut_length All}
    foreach {path values} [list $window.tabs.lut.filters.length.value [linsert $lengths 0 All] $window.tabs.lut.size.length $lengths] {
        if {[winfo exists $path]} {$path configure -values $values}
    }
    invalidate_sizing; reset_plot
    if {[winfo exists $window.tabs.lut.size.calc]} {update_run_controls}
}
proc ::analog_lens::visible_curves {} {
    variable lut_rows; variable lut_slice; variable lut_y; variable lut_length
    set curves [lut_curves $lut_rows $lut_slice $lut_y]
    if {$lut_length ne "All"} {
        if {[dict exists $curves $lut_length]} {return [dict create $lut_length [dict get $curves $lut_length]]}
        return {}
    }
    return $curves
}
proc ::analog_lens::reset_plot {} {
    set ::analog_lens::plot_view {}; set ::analog_lens::plot_point_index -1
    set ::analog_lens::plot_point_text {Click a curve sample, or focus the chart and use Left/Right.}
    schedule_plot
}
proc ::analog_lens::fit_lookup_layout {} {
    variable window; variable sizing_visible
    set w $window.tabs.lut
    if {![winfo exists $w.charttools]} {return}
    foreach name {load characterize metric sizing data} {pack forget $w.tools.$name}
    flow_controls $w.tools {load characterize metric sizing data} [expr {max(360,[winfo width $w]-24)}]
    set needed 170
    foreach part {tools source filters charttools point note} {incr needed [winfo reqheight $w.$part]}
    if {$sizing_visible} {incr needed [winfo reqheight $w.size]}
    if {$sizing_visible && [winfo height $w] > 1 && [winfo height $w] < $needed} {
        foreach part {charttools point plot} {pack forget $w.$part}
        pack $w.compact -after $w.filters -fill x -pady 8
    } else {
        pack forget $w.compact
        pack $w.charttools -after $w.filters -fill x -pady {0 4}
        pack $w.point -after $w.charttools -fill x -pady {0 4}
        pack $w.plot -after $w.point -fill both -expand 1
    }
}
proc ::analog_lens::zoom_plot {factor} {
    variable plot_bounds; variable plot_view
    if {[llength $plot_bounds] != 4} {return}
    lassign $plot_bounds xmin xmax ymin ymax
    set cx [expr {($xmin+$xmax)/2}]; set cy [expr {($ymin+$ymax)/2}]
    set dx [expr {($xmax-$xmin)*$factor/2}]; set dy [expr {($ymax-$ymin)*$factor/2}]
    if {$dx < 1e-8 || $dy < 1e-30} {return}
    set plot_view [list [expr {$cx-$dx}] [expr {$cx+$dx}] [expr {$cy-$dy}] [expr {$cy+$dy}]]
    schedule_plot
}
proc ::analog_lens::clip_segment {x0 y0 x1 y1 bounds} {
    lassign $bounds xmin xmax ymin ymax
    set dx [expr {$x1-$x0}]; set dy [expr {$y1-$y0}]; set lo 0.; set hi 1.
    foreach p [list [expr {-$dx}] $dx [expr {-$dy}] $dy] q [list [expr {$x0-$xmin}] [expr {$xmax-$x0}] [expr {$y0-$ymin}] [expr {$ymax-$y0}]] {
        if {$p == 0} {if {$q < 0} {return {}}; continue}
        set ratio [expr {double($q)/$p}]
        if {$p < 0} {set lo [expr {max($lo,$ratio)}]} else {set hi [expr {min($hi,$ratio)}]}
        if {$lo > $hi} {return {}}
    }
    return [list [expr {$x0+$lo*$dx}] [expr {$y0+$lo*$dy}] [expr {$x0+$hi*$dx}] [expr {$y0+$hi*$dy}]]
}
proc ::analog_lens::inspect_plot {x y} {
    variable plot_points; variable plot_point_index; variable window
    focus $window.tabs.lut.plot
    set nearest -1; set distance 400; set i 0
    foreach p $plot_points {
        lassign $p px py
        set d [expr {($px-$x)**2+($py-$y)**2}]
        if {$d < $distance} {set nearest $i; set distance $d}; incr i
    }
    if {$nearest >= 0} {set plot_point_index $nearest; show_plot_point}
}
proc ::analog_lens::step_plot_point {step} {
    variable plot_points; variable plot_point_index
    if {![llength $plot_points]} {return}
    set plot_point_index [expr {($plot_point_index+$step+[llength $plot_points])%[llength $plot_points]}]
    show_plot_point
}
proc ::analog_lens::show_plot_point {} {
    variable plot_point_index; variable plot_points; variable plot_point_text; variable window; variable lut_y; variable colors
    set c $window.tabs.lut.plot; $c delete inspected
    if {$plot_point_index < 0 || $plot_point_index >= [llength $plot_points]} {return}
    lassign [lindex $plot_points $plot_point_index] x y length gmid value
    set unit [dict get {gain V/V ft Hz density A/µm} $lut_y]
    set plot_point_text "L = $length µm · gm/Id = [format %.5g $gmid] 1/V · [eng $value $unit]"
    $c create oval [expr {$x-6}] [expr {$y-6}] [expr {$x+6}] [expr {$y+6}] -outline [dict get $colors fg] -width 2 -tags inspected
}
proc ::analog_lens::lookup_provenance_warning {} {
    variable lut_slice; variable result_metadata
    if {[llength $lut_slice] != 7} {return {}}
    lassign $lut_slice pdk model corner temp vds vsb width
    set lookup [dict create pdk $pdk corner $corner temp_c $temp vds_v $vds vsb_v $vsb]
    set different [condition_differences $result_metadata $lookup]
    if {[llength $different]} {return "Overlay hidden: [join $different {; }]"}
    set missing {}
    foreach key {pdk corner temp_c vds_v vsb_v} {if {[get $result_metadata $key] eq {}} {lappend missing [condition_label $key]}}
    if {[llength $missing]} {return "Overlay conditions unverified: [join $missing {, }]."}
    return {}
}
proc ::analog_lens::xml_escape {value} {return [string map {& &amp; < &lt; > &gt; \" &quot;} $value]}
proc ::analog_lens::export_plot_svg {path} {
    variable window; variable lut_source; variable slice_label; variable lut_y; variable lut_length
    draw_plot
    set c $window.tabs.lut.plot; set width [winfo width $c]; set height [winfo height $c]
    set out "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$width\" height=\"$height\" viewBox=\"0 0 $width $height\">\n"
    append out "<title>Analog Lens lookup chart</title>\n<desc>[xml_escape "$lut_source; $slice_label; metric $lut_y; length $lut_length; [lookup_provenance_warning]"]</desc>\n"
    append out "<rect width=\"100%\" height=\"100%\" fill=\"[$c cget -background]\"/>\n"
    foreach item [$c find all] {
        set type [$c type $item]; set coords [$c coords $item]
        switch -- $type {
            line {
                set points {}; foreach {x y} $coords {lappend points "$x,$y"}
                set dash [$c itemcget $item -dash]; set attrs {}
                if {$dash ne {}} {set attrs " stroke-dasharray=\"[join $dash ,]\""}
                append out "<polyline points=\"[join $points { }]\" fill=\"none\" stroke=\"[$c itemcget $item -fill]\" stroke-width=\"[$c itemcget $item -width]\"$attrs/>\n"
            }
            text {
                lassign $coords x y; set anchor [$c itemcget $item -anchor]
                set align [expr {[string match *w $anchor] ? "start" : [string match *e $anchor] ? "end" : "middle"}]
                set font [$c itemcget $item -font]; set size [expr {abs([font actual $font -size])*[tk scaling]}]
                set text [xml_escape [$c itemcget $item -text]]
                append out "<text x=\"$x\" y=\"$y\" text-anchor=\"$align\" dominant-baseline=\"central\" font-family=\"sans-serif\" font-size=\"$size\" fill=\"[$c itemcget $item -fill]\">$text</text>\n"
            }
            oval {
                lassign $coords x0 y0 x1 y1
                set fill [$c itemcget $item -fill]; if {$fill eq {}} {set fill none}
                set outline [$c itemcget $item -outline]; if {$outline eq {}} {set outline none}
                append out "<ellipse cx=\"[expr {($x0+$x1)/2}]\" cy=\"[expr {($y0+$y1)/2}]\" rx=\"[expr {($x1-$x0)/2}]\" ry=\"[expr {($y1-$y0)/2}]\" fill=\"$fill\" stroke=\"$outline\"/>\n"
            }
        }
    }
    append out </svg>\n; atomic_write $path $out
}
proc ::analog_lens::export_plot_dialog {} {
    set path [tk_getSaveFile -parent $::analog_lens::window -title {Export chart} -defaultextension .svg -initialfile lookup-chart.svg]
    if {$path ne {}} {export_plot_svg $path; set ::analog_lens::status "Chart saved: $path"}
}
