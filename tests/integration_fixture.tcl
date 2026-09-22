# Stateful host contract for integration tests. Not simulator measurements.
namespace eval ::hostfixture {
    variable top {}; variable props [dict create name M1 model nfet_03v3 W 10u L 0.5u nf 2 m 3]
    variable undo {}; variable pushes 0; variable modified 0; variable rawtype op
    variable cursor 0; variable axis {0 0.25 1}; variable gm {0.0004 0.0008 0.0016}
}
rename xschem fixture_xschem
dict set ::mock::vectors v(vd) 0.9
proc xschem {command args} {
    # The real C API braces instance names even when Tcl's canonical list
    # representation would omit braces. Consumers must compare list elements.
    if {$command eq "selected_set" && [llength $::mock::selection] == 1} {return "\{[lindex $::mock::selection 0]\}"}
    if {$command eq "instance_net"} {return [dict get {d vd s 0 b 0} [string tolower [lindex $args 1]]]}
    if {$command eq "resolved_net"} {return [lindex $args 0]}
    if {$command eq "translate" && [lindex $args 0] eq "M1"} {return [dict get $::hostfixture::props model]}
    if {$command eq "get"} {
        switch -- [lindex $args 0] {
            schname - current_name {return $::hostfixture::top}
            modified {return $::hostfixture::modified}
            netlist_name {return {}}
            cursor2_x {return $::hostfixture::cursor}
            graph_lastsel {return -1}
        }
    }
    if {$command eq "getprop" && [lindex $args 0] eq "instance" && [lindex $args 1] in {0 M1}} {
        if {[llength $args] == 2} {return $::hostfixture::props}
        set key [lindex $args 2]
        if {[dict exists $::hostfixture::props $key]} {return [dict get $::hostfixture::props $key]}
    }
    if {$command eq "setprop"} {
        lassign $args fast instance owner key value
        if {$fast ne "-fast" || $owner ne "M1"} {error {Unexpected geometry edit}}
        if {$key eq "allprops"} {set ::hostfixture::props $value} else {dict set ::hostfixture::props $key $value}
        set ::hostfixture::modified 1; return
    }
    if {$command eq "push_undo"} {lappend ::hostfixture::undo $::hostfixture::props; incr ::hostfixture::pushes; return}
    if {$command eq "undo"} {set ::hostfixture::props [lindex $::hostfixture::undo end]; set ::hostfixture::undo [lrange $::hostfixture::undo 0 end-1]; return}
    if {$command eq "netlist" && ![llength $args]} {set args [list [file join $::netlist_dir [file rootname [file tail $::hostfixture::top]].spice]]}
    if {$command eq "raw" && $::hostfixture::rawtype eq "tran"} {
        switch -- [lindex $args 0] {
            sim_type {return tran}
            points {return [llength $::hostfixture::axis]}
            list {return [linsert [dict keys $::mock::vectors] 0 time]}
            value {
                if {[lindex $args 1] eq "time"} {return [lindex $::hostfixture::axis [lindex $args 2]]}
                if {[lindex $args 1] eq {@m.xm1.m0[gm]}} {return [lindex $::hostfixture::gm [lindex $args 2]]}
            }
        }
    }
    return [fixture_xschem $command {*}$args]
}
