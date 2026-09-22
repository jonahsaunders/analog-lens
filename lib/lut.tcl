namespace eval ::analog_lens {
    variable lut_rows {}
    variable lut_slices {}
    variable lut_slice {}
    variable lut_y gain
    variable target_gmid 15
    variable target_gm_u 1000
    variable target_length {}
    variable lut_note {Load measured lookup data to explore sizing.}
}
proc ::analog_lens::parse_lut {text} {
    set csv [csv_parse $text]
    if {[llength $csv] < 3} {error "A lookup table needs a header and at least two data rows."}
    set header {}; foreach h [lindex $csv 0] {lappend header [string tolower [string trim $h]]}
    set required {pdk model corner temp_c vds_v vsb_v length_um total_width_um id_a gm_s gds_s}
    foreach field $required {
        if {[lsearch -exact $header $field] < 0} {error "Missing CSV column: $field. Use the included template."}
    }
    if {[llength [lsort -unique $header]] != [llength $header]} {error "Duplicate CSV column names."}
    set rows {}; set line 1
    foreach cells [lrange $csv 1 end] {
        incr line
        if {[llength $cells] != [llength $header]} {error "CSV row $line has the wrong number of columns."}
        set r {}; foreach key $header cell $cells {dict set r $key [string trim $cell]}
        foreach field {pdk model corner} {if {[dict get $r $field] eq {}} {error "Row $line: $field is required."}}
        foreach field {temp_c vds_v vsb_v length_um total_width_um id_a gm_s gds_s} {
            set n [number [dict get $r $field]]
            if {$n eq {}} {error "Row $line: $field must be a finite number in the header's units."}
            dict set r $field $n
        }
        foreach field {length_um total_width_um} {if {[dict get $r $field] <= 0} {error "Row $line: $field must be positive."}}
        if {[dict get $r gm_s] <= 0 || [dict get $r gds_s] <= 0 || abs([dict get $r id_a]) <= 1e-12} {continue}
        dict set r gmid [expr {abs([dict get $r gm_s]/[dict get $r id_a])}]
        dict set r gain [expr {[dict get $r gm_s]/[dict get $r gds_s]}]
        dict set r density [expr {abs([dict get $r id_a])/[dict get $r total_width_um]}]
        set cgg [number [get $r cgg_total_f]]
        dict set r ft {}
        if {$cgg ne {} && $cgg > 0} {dict set r ft [expr {[dict get $r gm_s]/(2*acos(-1)*$cgg)}]}
        # Width is part of the slice: do not silently combine narrow-width effects.
        dict set r slice [list [dict get $r pdk] [dict get $r model] [dict get $r corner] \
            [dict get $r temp_c] [dict get $r vds_v] [dict get $r vsb_v] [dict get $r total_width_um]]
        lappend rows $r
    }
    if {[llength $rows] < 2} {error "No usable gm/Id curves: need positive gm, gds and current above 1 pA."}
    return $rows
}
proc ::analog_lens::lut_curves {rows slice metric} {
    set curves {}
    foreach r $rows {
        if {[dict get $r slice] ne $slice || [number [get $r $metric]] eq {}} {continue}
        dict lappend curves [dict get $r length_um] [list [dict get $r gmid] [dict get $r $metric] $r]
    }
    dict for {length points} $curves {dict set curves $length [lsort -real -index 0 $points]}
    return $curves
}
proc ::analog_lens::interpolate_curve {points target metric} {
    set target [number $target]
    if {$target eq {} || $target <= 0} {error "Enter a positive gm/Id target."}
    if {[llength $points] < 2} {error "This length needs at least two samples."}
    set prev {}
    foreach p $points {
        set x [lindex $p 0]
        if {$prev ne {} && abs($x-$prev) < 1e-9} {error "Ambiguous lookup curve: duplicate gm/Id samples. Split the bias sweep into monotonic branches."}
        set prev $x
    }
    if {$target < [lindex $points 0 0] || $target > [lindex $points end 0]} {error "Target is outside this measured curve. Extrapolation is disabled."}
    for {set i 1} {$i < [llength $points]} {incr i} {
        set a [lindex $points [expr {$i-1}]]; set b [lindex $points $i]
        set ax [lindex $a 0]; set bx [lindex $b 0]
        if {$target >= $ax && $target <= $bx} {
            set av [number [get [lindex $a 2] $metric]]; set bv [number [get [lindex $b 2] $metric]]
            if {$av eq {} || $bv eq {}} {return {}}
            return [expr {$av + ($target-$ax)/($bx-$ax)*($bv-$av)}]
        }
    }
    error "No interpolation interval found."
}
proc ::analog_lens::sizing {rows slice length gmid gm_u} {
    set gm_u [number $gm_u]; set gmid [number $gmid]
    if {$gm_u eq {} || $gm_u <= 0 || $gmid eq {} || $gmid <= 0} {error "gm and gm/Id targets must be positive numbers."}
    set previous {}; set direction 0
    foreach row $rows {
        if {[dict get $row slice] ne $slice || [dict get $row length_um] != $length} {continue}
        set x [dict get $row gmid]
        if {$previous ne {}} {
            set sign [expr {$x > $previous ? 1 : $x < $previous ? -1 : 0}]
            if {$sign == 0 || ($direction != 0 && $sign != $direction)} {error "gm/Id samples must form one ordered monotonic branch. Split multi-branch sweeps before sizing."}
            set direction $sign
        }
        set previous $x
    }
    set curves [lut_curves $rows $slice density]
    if {![dict exists $curves $length] && [number $length] ne {}} {
        foreach key [dict keys $curves] {if {$key == $length} {set length $key; break}}
    }
    if {![dict exists $curves $length]} {error "Choose a characterized length."}
    set density [interpolate_curve [dict get $curves $length] $gmid density]
    if {$density eq {} || $density <= 0} {error "Current density is unavailable."}
    set id [expr {$gm_u*1e-6/$gmid}]
    return [dict create id $id width [expr {$id/$density}] density $density]
}
