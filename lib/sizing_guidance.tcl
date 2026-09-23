# Advisory bias estimates never alter circuit sources or claim circuit-level pass.
namespace eval ::analog_lens {
    variable preview_all 0; variable verification_advice {}
    variable target_display; variable target_display_lock 0
}
proc ::analog_lens::target_to_display {key args} {
    if {$::analog_lens::target_display_lock} {return}
    set ::analog_lens::target_display_lock 1
    try {
        set value [set ::analog_lens::$key]
        set ::analog_lens::target_display($key) [expr {[number $value] eq {} ? $value : [format %.6g $value]}]
    } finally {set ::analog_lens::target_display_lock 0}
}
proc ::analog_lens::display_to_target {name key args} {
    if {$::analog_lens::target_display_lock} {return}
    set ::analog_lens::target_display_lock 1
    try {set ::analog_lens::$key $::analog_lens::target_display($key)} finally {set ::analog_lens::target_display_lock 0}
}
foreach key {target_length target_gmid target_gm_u} {
    trace add variable ::analog_lens::$key write [list ::analog_lens::target_to_display $key]
    ::analog_lens::target_to_display $key
}
trace add variable ::analog_lens::target_display write ::analog_lens::display_to_target
proc ::analog_lens::geometry_preview {plan} {
    set changed {}; set same {}
    dict for {key value} [get $plan edits] {
        set old [get [get $plan previous_edits] $key]
        set line "$key: $old → $value\n"
        if {$old eq $value || ([number $old] ne {} && [number $value] ne {} && $old == $value)} {
            append same $line
        } else {append changed $line}
    }
    if {$changed eq {}} {set changed "No geometry changes.\n"}
    if {$::analog_lens::preview_all && $same ne {}} {append changed "\nUnchanged properties:\n$same"}
    return $changed
}
proc ::analog_lens::toggle_preview_details {} {
    if {$::analog_lens::size_plan ne {}} {preview_size 1}
    refresh_workspace
}
proc ::analog_lens::measured_vgs {values} {
    return [get $values terminal_vgs [get $values vgs]]
}
proc ::analog_lens::workflow_toolbar {} {
    set w $::analog_lens::window
    if {![winfo exists $w.tabs] || ![winfo exists $w.root.tools.run]} {return}
    $w.root.tools.run configure -style [expr {[$w.tabs select] eq "$w.tabs.design" ? "AL.TButton" : "AL.Primary.TButton"}]
}
proc ::analog_lens::workflow_next {device trust} {
    if {$::analog_lens::run_channel ne {} || [dict size $::analog_lens::native_jobs]} {return [dict create label {Simulation running…} enabled 0 command {}]}
    if {$device eq {}} {return [dict create label {Select a transistor} command {::analog_lens::open_tab op}]}
    if {[catch {supported_model $device}]} {return [dict create label {View supported models} command {::analog_lens::open_tab setup}]}
    if {[auto_execok ngspice] eq {} || ![info exists ::netlist_dir] || ![file isdirectory $::netlist_dir]} {
        return [dict create label {Set up simulation…} command ::analog_lens::setup_dialog]
    }
    if {$::analog_lens::native_result_state eq "attachment_failed"} {return [dict create label {Choose result file…} command ::analog_lens::setup_dialog]}
    if {$::analog_lens::freshness_state ne "current"} {
        if {[xschem get currsch] != 0} {return [dict create label {Return to testbench} command ::analog_lens::workspace_parent]}
        return [dict create label {Obtain current measurements} command ::analog_lens::run_testbench]
    }
    if {[get $trust state] eq "outdated"} {return [dict create label {Regenerate outdated lookup…} command ::analog_lens::characterize_dialog]}
    if {![llength [compatible_slices $device]]} {return [dict create label {Choose or generate lookup…} command ::analog_lens::workspace_lookup_next]}
    set plan $::analog_lens::size_plan
    if {$plan eq {} || [get $plan targets] ne [sizing_targets] || [get $plan owner] ne [get $device owner] || [get $plan context] ne [context]} {
        return [dict create label {Preview sizing changes} command ::analog_lens::workspace_preview]
    }
    if {[xschem get currsch] != 0} {return [dict create label {Apply geometry here} command {::analog_lens::apply_size_plan 0}]}
    return [dict create label {Apply & verify in testbench} command {::analog_lens::apply_size_plan 2}]
}
proc ::analog_lens::workspace_lookup_next {} {
    use_device_conditions
    if {![dict size $::analog_lens::workspace_choices]} {
        characterize_dialog
    } elseif {[dict size $::analog_lens::workspace_choices] > 1} {
        focus $::analog_lens::window.tabs.design.body.canvas.content.conditions.choice
    }
}
proc ::analog_lens::bias_preview {plan device} {
    set result [get $plan result]; set vgs [get $result required_vgs]
    set measured [measured_vgs [get $device values]]
    set text "Estimated |Id|: [eng [get $result id] A]\nEstimated required Vgs: [eng $vgs V]\nLoaded Vgs: [eng $measured V]"
    if {$vgs eq {}} {
        append text "\nThis lookup has no Vgs samples. Generate a lookup to estimate the required gate bias."
    } elseif {$measured ne {} && abs($vgs-$measured) > max(0.001,abs($vgs)*0.02)} {
        append text "\nBias adjustment may be needed: estimated ΔVgs [eng [expr {$vgs-$measured}] V]. Review the bias source/network, then simulate."
    }
    set rounding [expr {100*([get [get $plan geometry] total_width]/[get $result width]-1)}]
    append text "\nWidth grid rounding: [format %+.3g $rounding]%. Vgs and current are lookup estimates; sources are unchanged."
    return $text
}
proc ::analog_lens::sizing_diagnosis {plan values state} {
    if {$state eq "Incomplete"} {return {Save the missing device parameters and rerun before evaluating the targets.}}
    if {$state eq "Pass"} {return {Device targets met. Check circuit gain, headroom, noise and other specifications separately.}}
    set notes {}; set required [get [get $plan result] required_vgs]
    set actual [number [measured_vgs $values]]
    if {$required ne {} && $actual ne {} && abs($actual-$required) > max(0.001,abs($required)*0.02)} {
        lappend notes "Gate bias differs from the lookup estimate: measured [eng $actual V], estimated required [eng $required V]. Review the bias network and rerun."
    }
    foreach metric {terminal_vds terminal_vbs} expected [list [lindex [get $plan slice] 4] [expr {-[lindex [get $plan slice] 5]}]] label {Vds Vbs} {
        set measured [number [get $values $metric]]
        if {$measured ne {} && abs($measured-$expected) > max(0.001,abs($expected)*0.02)} {
            lappend notes "$label shifted from the characterized condition. Reuse the new device conditions and regenerate the lookup."
        }
    }
    set width [number [get [get $plan result] width]]
    set realized [number [get [get $plan geometry] total_width]]
    if {$width ne {} && $realized ne {} && $width > 0 && abs($realized/$width-1) > 0.001} {
        lappend notes "Width grid rounding changed the estimated width by [format %+.3g [expr {100*($realized/$width-1)}]]%. Review the realized geometry."
    }
    if {![llength $notes]} {
        lappend notes {Width scaling did not reproduce the requested targets. Check finger geometry, width effects, parasitics and bias; characterize closer to the realized geometry.}
        if {$required eq {}} {lappend notes {Vgs samples are missing, so a gate-bias cause cannot be assessed.}}
    }
    return [join $notes "\n"]
}
