# Numerical operations never evaluate imported strings as Tcl scripts.
namespace eval ::analog_lens {
    variable limits [dict create current_floor 1e-12 gmid_min 5.0 gmid_max 25.0 headroom_min 0.05]
}
proc ::analog_lens::get {d key {fallback {}}} {
    if {[dict exists $d $key]} {return [dict get $d $key]}
    return $fallback
}
proc ::analog_lens::number {v} {
    if {![string is double -strict $v]} {return {}}
    if {[catch {expr {double($v)}} n] || [regexp -nocase {nan|inf} $n]} {return {}}
    return $n
}
proc ::analog_lens::spice_number {v} {
    set v [string trim $v]
    if {![regexp -nocase {^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:e[+-]?[0-9]+)?)(meg|[tgkmunpf]?)$} $v -> base suffix]} {return {}}
    set multipliers [dict create {} 1 t 1e12 g 1e9 meg 1e6 k 1e3 m 1e-3 u 1e-6 n 1e-9 p 1e-12 f 1e-15]
    return [number [expr {double($base) * [dict get $multipliers [string tolower $suffix]]}]]
}
proc ::analog_lens::eng {value {unit {}}} {
    set value [number $value]
    if {$value eq {}} {return "—"}
    if {$value == 0} {return "0 $unit"}
    foreach {scale prefix} {1e12 T 1e9 G 1e6 M 1e3 k 1 {} 1e-3 m 1e-6 µ 1e-9 n 1e-12 p 1e-15 f} {
        if {abs($value) >= $scale} {return [string trim "[format %.4g [expr {$value/$scale}]] $prefix$unit"]}
    }
    return [string trim "[format %.3e $value] $unit"]
}
proc ::analog_lens::ratio {a b {floor 0.0}} {
    set a [number $a]; set b [number $b]
    if {$a eq {} || $b eq {} || abs($b) <= $floor} {return {}}
    return [number [expr {abs($a/$b)}]]
}
proc ::analog_lens::metrics {values family {type nmos}} {
    variable limits
    set out $values
    set id [number [get $values id]]; set gm [number [get $values gm]]
    set gds [number [get $values gds]]
    set issues {}
    foreach field {id gm gds} {
        if {[number [get $values $field]] eq {}} {lappend issues "Missing $field: save the device parameters and rerun."}
    }
    set floor [dict get $limits current_floor]
    set is_bjt [regexp {npn|pnp} $type]
    if {$id ne {} && abs($id) <= $floor} {lappend issues "Current is below the analysis floor; gm/Id is unavailable."}
    dict set out gmid [ratio $gm $id $floor]
    dict set out beta {}; dict set out vce {}
    if {$is_bjt} {
        dict set out beta [ratio $id [get $values ib] $floor]
        set vbe [number [get $values vbe]]; set vbc [number [get $values vbc]]
        if {$vbe ne {} && $vbc ne {}} {dict set out vce [expr {$vbe-$vbc}]}
    }
    dict set out gain {}; dict set out ro {}
    if {$gds ne {} && $gds > 0} {
        dict set out gain [ratio $gm $gds]
        dict set out ro [expr {1.0/$gds}]
    } elseif {$gds ne {}} {lappend issues "Nonpositive output conductance; gain and ro are unavailable."}
    set cgg [number [get $values cgg]]
    if {$family eq "ihp"} {
        set cgs [number [get $values cgsol]]; set cgd [number [get $values cgdol]]
        if {$cgg ne {} && $cgs ne {} && $cgd ne {}} {set cgg [expr {$cgg+$cgs+$cgd}]} else {set cgg {}}
    }
    dict set out cgg_total $cgg
    dict set out ft {}
    if {$gm ne {} && $cgg ne {} && $cgg > 0} {
        dict set out ft [expr {abs($gm)/(2*acos(-1)*$cgg)}]
    }
    set vds [number [get $values vds]]; set vdsat [number [get $values vdsat]]
    dict set out headroom {}
    if {$vds ne {} && $vdsat ne {} && $type ni {npn pnp vertical_npn vertical_pnp}} {
        set h [expr {abs($vds)-abs($vdsat)}]
        dict set out headroom $h
        if {$h < [dict get $limits headroom_min]} {lappend issues "Model headroom is below your target; check the device bias."}
    }
    set gmid [get $out gmid]
    if {!$is_bjt && $gmid ne {} && ($gmid < [dict get $limits gmid_min] || $gmid > [dict get $limits gmid_max])} {
        lappend issues "gm/Id is outside your target range."
    }
    dict set out issues $issues
    dict set out status [expr {[llength $issues] ? "Review" : "In range"}]
    return $out
}
proc ::analog_lens::csv_cell {v} {
    # Stop spreadsheet software interpreting identifiers as formulas.
    if {[regexp {^[=+@]} $v] || ([string match -* $v] && [number $v] eq {})} {set v "'$v"}
    return "\"[string map [list \" \"\"] $v]\""
}
proc ::analog_lens::csv_row {cells} {
    set out {}; foreach c $cells {lappend out [csv_cell $c]}; return [join $out ,]
}
proc ::analog_lens::csv_parse {text} {
    # RFC 4180 quoting, including embedded newlines; no eval or subst.
    set rows {}; set row {}; set field {}; set quoted 0; set closed 0
    set text [string trimleft $text \ufeff]
    for {set i 0} {$i < [string length $text]} {incr i} {
        set c [string index $text $i]
        if {$quoted} {
            if {$c eq "\""} {
                if {[string index $text [expr {$i+1}]] eq "\""} {append field \"; incr i} else {set quoted 0; set closed 1}
            } else {append field $c}
        } elseif {$c eq "\"" && $field eq {} && !$closed} {set quoted 1
        } elseif {$c eq ","} {lappend row $field; set field {}; set closed 0
        } elseif {$c eq "\n" || $c eq "\r"} {
            if {$c eq "\r" && [string index $text [expr {$i+1}]] eq "\n"} {incr i}
            lappend row $field
            if {[llength $row] > 1 || [lindex $row 0] ne {}} {lappend rows $row}
            set row {}; set field {}; set closed 0
        } elseif {$closed} {
            if {![string is space $c]} {error "Unexpected text after a quoted CSV field."}
        } else {append field $c}
    }
    if {$quoted} {error "Unclosed quote in CSV file."}
    if {$field ne {} || [llength $row] || $closed} {lappend row $field; lappend rows $row}
    return $rows
}
proc ::analog_lens::read_text {path} {
    set f [open $path r]; fconfigure $f -encoding utf-8
    try {return [read $f]} finally {close $f}
}
proc ::analog_lens::write_text {path content} {
    set f [open $path w]; fconfigure $f -encoding utf-8 -translation lf
    try {puts -nonewline $f $content} finally {close $f}
}
