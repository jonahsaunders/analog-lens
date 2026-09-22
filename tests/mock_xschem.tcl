# Contract fixture, not measured PDK data.
namespace eval ::mock {
    variable selection M2; variable level 0; variable hierarchy_test 0
    variable raw_file example.raw
    variable vectors [dict create {i(@m.xm1.m0[id])} 5e-5 {@m.xm1.m0[gm]} 8e-4 {@m.xm1.m0[gds]} 2.5e-5 \
        {v(@m.xm1.m0[vds])} 0.9 {v(@m.xm1.m0[vdsat])} 0.2 \
        {i(@m.xm2.m0[id])} 1e-5 {@m.xm2.m0[gm]} 2e-5 {@m.xm2.m0[gds]} 1e-5]
}
proc xschem {command args} {
    switch -- $command {
        get {
            switch -- [lindex $args 0] {
                instances {if {$::mock::level} {error {fixture failure inside child}}; return 2}
                current_win_path {return .drw}
                current_name {return example.sch}
                top_path {return {}}
                sch_path {return [expr {$::mock::level ? ".x1." : "."}]}
                sim_sch_path {return {}}
                currsch {return $::mock::level}
                netlist_type {return spice}
            }
        }
        getprop {
            lassign $args kind inst attr
            set n [expr {$inst in {1 M2} ? "M2" : "M1"}]
            switch -- $attr {
                name {return $n}
                cell::name {return gf180mcu_fd_pr/nfet_03v3.sym}
                cell::type {if {$::mock::hierarchy_test} {return subcircuit}; return nmos}
                model {return nfet_03v3}
                spiceprefix {return X}
                W {return 10u}
                L {return 0.28u}
                nf - m {return 1}
                default {return {}}
            }
        }
        translate {return nfet_03v3}
        netlist {
            if {$::mock::hierarchy_test} {error {fixture netlisting error}}
            set f [open [lindex $args 0] w]
            puts $f "Fixture circuit\nv1 vdd 0 1.8\nXM1 d g 0 0 nfet_03v3 w=10u l=.5u\nXM2 d g 0 0 nfet_03v3 w=10u l=.5u\n.control\ntran 1n 1u\n.endc\n.end"
            close $f
        }
        expandlabel {return [list [lindex $args 0] 1]}
        selected_set {return $::mock::selection}
        unselect_all {set ::mock::selection {}}
        select {set ::mock::selection [lindex $args 1]}
        descend {incr ::mock::level; return 1}
        go_back {incr ::mock::level -1}
        redraw - zoom_full - set - place_symbol {return {}}
        raw {
            switch -- [lindex $args 0] {
                loaded {return 0}
                sim_type {return op}
                rawfile {return $::mock::raw_file}
                clear {set ::mock::raw_file {}}
                read {set ::mock::raw_file [lindex $args 1]}
                points - datasets {return 1}
                list {return [dict keys $::mock::vectors]}
                value {return [dict get $::mock::vectors [lindex $args 1]]}
                default {error {unsupported raw fixture operation}}
            }
        }
        default {error "unsupported fixture command: $command"}
    }
}
