# These conventions follow the PDKs' own xschem parameter-save integrations.
# Paths are lowercased only for ngspice lookup. Display names remain unchanged.
namespace eval ::analog_lens {
    variable supported_pdks {sky130A gf180mcuD ihp-sg13g2 ihp-sg13cmos5l}
    variable aliases [dict create id {id ids ic} gm {gm} gds {gds go} gmb {gmbs gmb} \
        vgs {vgs} vds {vds} vbs {vbs} vth {vth von} vdsat {vdsat vdss} \
        cgg {cgg} cgsol {cgsol} cgdol {cgdol} ib {ib} vbe {vbe} vbc {vbc}]
}
proc ::analog_lens::family {symbol model {pdk {}}} {
    set s [string tolower "$symbol $model"]
    if {[string first sky130 $s] >= 0} {return sky130}
    if {[string first gf180 $s] >= 0} {return gf180}
    if {[regexp {sg13|ihp} $s]} {return ihp}
    if {$pdk eq {} && [info exists ::env(PDK)]} {set pdk $::env(PDK)}
    if {[string match sky130* $pdk]} {return sky130}
    if {[string match gf180* $pdk]} {return gf180}
    if {[string match ihp-* $pdk]} {return ihp}
    return generic
}
proc ::analog_lens::device_paths {device} {
    set model [string tolower [get $device model]]
    set family [get $device family generic]
    set path [string trimleft [string tolower [get $device hierarchy]] .]
    if {$path ne {} && ![string match *. $path]} {append path .}
    set prefix [string tolower [get $device prefix]]
    set name [string tolower [dict get $device name]]
    set typ [get $device type nmos]
    set inst $prefix$name
    if {[regexp {npn|pnp} $typ] && $prefix eq "x"} {
        switch -- $family {
            sky130 {
                regsub {^sky130_fd_pr__} $model {} model
                return [list "@q.${path}${inst}.qsky130_fd_pr__$model"]
            }
            gf180 {return [list "@q.${path}${inst}.q0"]}
            ihp {
                if {![regexp {npn} $typ]} {return {}}
                regsub {_5t$} $model {} model
                return [list "@q.${path}${inst}.q$model"]
            }
        }
    }
    if {$family eq "sky130" && $prefix eq "x"} {
        regsub {^sky130_fd_pr__} $model {} model
        return [list "@m.${path}${inst}.msky130_fd_pr__$model" "@m.${path}${inst}.msky130_fd_pr__${model}__base"]
    }
    if {$family eq "gf180" && $prefix eq "x"} {return [list "@m.${path}${inst}.m0"]}
    if {$family eq "ihp" && $prefix eq "x"} {
        if {[regexp {npn|pnp} $typ]} {
            regsub {_5t$} $model {} model
            return [list "@q.${path}${inst}.q$model"]
        }
        return [list "@n.${path}${inst}.n$model"]
    }
    set kind [string index $inst 0]
    if {$kind ni {m n q}} {return {}}
    if {$path eq {}} {return [list "@$inst"]}
    return [list "@${kind}.${path}${inst}"]
}
proc ::analog_lens::save_parameters {device} {
    if {[regexp {npn|pnp} [get $device type]]} {return {ic ib gm go vbe vbc}}
    switch -- [get $device family] {
        ihp {return {ids gm gds vgs vds vth vdss cgg cgsol cgdol}}
        sky130 {return {id gm gds gmbs vgs vds vbs vth vdsat cgg}}
        gf180 {return {id gm gds gmbs vgs vds vbs vth vdsat cgg}}
        default {return {id gm gds vgs vds vdsat}}
    }
}
proc ::analog_lens::canonical_vector {v} {
    set v [string tolower [string trim $v]]
    if {[regexp {^[vi]\((@.*)\)$} $v -> inner]} {return $inner}
    return $v
}
proc ::analog_lens::vector_index {names} {
    set result {}
    foreach name $names {dict set result [canonical_vector $name] $name}
    return $result
}
proc ::analog_lens::resolve_vectors {device index} {
    variable aliases
    set paths [device_paths $device]
    # Discover an unambiguous deeper primitive inside the exact wrapper.
    # Component boundaries prevent M1 from matching M10 or X1 from matching X10.
    set hierarchy [string trimleft [string tolower [get $device hierarchy]] .]
    if {$hierarchy ne {} && ![string match *. $hierarchy]} {append hierarchy .}
    set instance "[string tolower [get $device prefix]][string tolower [get $device name]]"
    set stem "$hierarchy$instance."
    set found {}
    foreach key [dict keys $index] {
        if {![regexp {^@([mnq])\.(.+)\[gm\]$} $key -> kind rest]} {continue}
        if {[string first $stem $rest] == 0} {lappend found "@$kind.$rest"}
    }
    if {[llength [lsort -unique $found]] == 1} {lappend paths [lindex $found 0]}
    # Never mix parameters belonging to separate internal primitives.
    foreach path [lsort -unique $paths] {
        set gmkey "${path}\[gm\]"
        if {![dict exists $index $gmkey]} {continue}
        set resolved {}
        dict for {metric variants} $aliases {
            foreach param $variants {
                set key "${path}\[$param\]"
                if {[dict exists $index $key]} {dict set resolved $metric [dict get $index $key]; break}
            }
        }
        return [dict create path $path vectors $resolved]
    }
    return [dict create path [lindex $paths 0] vectors {}]
}
proc ::analog_lens::save_lines {devices} {
    set lines [list {.save all}]
    foreach d $devices {
        set path [lindex [device_paths $d] 0]
        if {$path eq {}} {error "Cannot resolve [get $d name]. Add a device adapter before running analysis."}
        foreach p [save_parameters $d] {lappend lines ".save ${path}\[$p\]"}
    }
    return "[join [lsort -unique $lines] \n]\n"
}
