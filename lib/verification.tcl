# A sizing result is verified only by a new run of the exact applied design.
namespace eval ::analog_lens {
    variable pending_verifications {}; variable verification_result {}
    variable verification_summary {}; variable verification_text {}
}
proc ::analog_lens::begin_verification {plan before} {
    set key [lindex [project_identity] 0]
    dict set plan before_values [get $before values]
    dict set plan before_raw [get $::analog_lens::result_metadata raw]
    dict set plan applied_stamp [design_stamp]
    dict set plan applied_at [clock milliseconds]
    dict set plan target_gm [expr {$::analog_lens::target_gm_u*1e-6}]
    dict set plan target_gmid $::analog_lens::target_gmid
    dict set plan baseline $::analog_lens::baseline_choice
    dict set ::analog_lens::pending_verifications $key $plan
    set ::analog_lens::verification_result {}
    set ::analog_lens::verification_advice {Run the updated circuit to compare the estimated bias with measured values.}
    set ::analog_lens::verification_summary {Awaiting verification · Run the updated circuit.}
}
proc ::analog_lens::verification_failed {state} {
    set key [lindex [project_identity] 0]
    if {[dict exists $::analog_lens::pending_verifications $key]} {
        set ::analog_lens::verification_summary "Verification $state · Previous measurements retained; rerun to verify."
    }
}
proc ::analog_lens::evaluate_targets {plan values} {
    set rows {}; set passed 1; set complete 1
    foreach metric {gm gmid} {
        set target [get $plan target_$metric]; set actual [number [get $values $metric]]
        set previous [number [get [get $plan before_values] $metric]]
        set error {}; set change {}; set state Missing
        if {$actual ne {}} {
            set error [expr {100*($actual-$target)/abs($target)}]
            set state [expr {abs($error) <= [get $plan tolerance] ? "Pass" : "Miss"}]
            if {$previous ne {}} {set change [expr {$actual-$previous}]}
        } else {set complete 0}
        if {$state ne "Pass"} {set passed 0}
        lappend rows [dict create metric $metric target $target before $previous measured $actual error_percent $error change $change state $state]
    }
    return [dict create state [expr {!$complete ? "Incomplete" : $passed ? "Pass" : "Miss"}] rows $rows tolerance [get $plan tolerance]]
}
proc ::analog_lens::verify_sizing_result {} {
    set key [lindex [project_identity] 0]
    if {![dict exists $::analog_lens::pending_verifications $key]} {return}
    set plan [dict get $::analog_lens::pending_verifications $key]
    if {[context_key [context]] ne [context_key [get $plan context]]} {return}
    set metadata $::analog_lens::result_metadata
    if {[get $metadata raw] eq [get $plan before_raw] || [get $metadata design_stamp] ne [get $plan applied_stamp]} {
        set ::analog_lens::verification_summary {Not verified · This run does not match the applied sizing revision.}; return
    }
    if {[get $metadata design_stamp] ne [design_stamp] || [get [dependency_status 1] state] eq "changed"} {
        set ::analog_lens::verification_summary {Not verified · Circuit or model dependencies changed during the run.}; return
    }
    if {[get $metadata analysis] ne "op"} {
        set ::analog_lens::verification_summary {Not verified · Choose an operating-point result for the sizing target.}; return
    }
    set match {}
    foreach record $::analog_lens::records {
        if {[get $record owner] eq [get $plan owner] && [get $record model] eq [get $plan model]} {set match $record; break}
    }
    if {$match eq {}} {set ::analog_lens::verification_summary {Not verified · Sized device is absent from the new results.}; return}
    set result [evaluate_targets $plan [get $match values]]
    dict set result advice [sizing_diagnosis $plan [get $match values] [get $result state]]
    dict set result owner [get $plan owner]
    dict set result metadata $metadata
    dict set result plan $plan
    dict set result conditions [condition_confidence $match]
    dict set result current 1
    set ::analog_lens::verification_result $result
    dict set ::analog_lens::result_metadata verification $result
    set ::analog_lens::verification_summary "[get $result state] · [get $plan owner] sizing targets within ±[get $plan tolerance]%: [expr {[get $result state] eq "Pass" ? "yes" : "no"}]."
    set ::analog_lens::baseline_choice [get $plan baseline]
    select_baseline
    dict unset ::analog_lens::pending_verifications $key
    update_verification_text
}
proc ::analog_lens::update_verification_text {} {
    set r $::analog_lens::verification_result
    set text $::analog_lens::verification_summary
    set ::analog_lens::verification_advice [get $r advice]
    if {$r ne {}} {
        append text "\n\n[ get $r conditions]\n\n[get $r advice]\n\n"
        foreach row [get $r rows] {
            set unit [expr {[get $row metric] eq "gm" ? "S" : "1/V"}]
            append text "[get $row metric]: [get $row state]\nTarget: [eng [get $row target] $unit]\nBefore: [eng [get $row before] $unit]\nMeasured: [eng [get $row measured] $unit]\nChange: [eng [get $row change] $unit]\n"
            if {[get $row error_percent] ne {}} {append text "Target error: [format %+.3f [get $row error_percent]]%\n"}
            append text \n
        }
        append text "Source: [get [get [get $r metadata] raw] path]\n\nA target pass covers gm and gm/Id at this operating point. Review headroom, parasitics and circuit-level requirements separately."
    }
    set ::analog_lens::verification_text $text
    set w $::analog_lens::window.verification.text
    if {[llength [info commands winfo]] && [winfo exists $w]} {
        $w configure -state normal; $w delete 1.0 end; $w insert end $text; $w configure -state disabled
    }
    if {[llength [info commands winfo]] && [winfo exists $::analog_lens::window.verification.page.canvas.content.view.table]} {render_verification_view $::analog_lens::window.verification.page.canvas.content.view}
}
proc ::analog_lens::verification_dialog {} {
    show
    set w $::analog_lens::window.verification
    if {[winfo exists $w]} {raise $w; update_verification_text; return}
    toplevel $w; wm title $w {Sizing verification · Analog Lens}; wm geometry $w 760x590; wm minsize $w 620 440
    ttk::frame $w.actions -padding 12; pack $w.actions -side bottom -fill x
    pack [button $w.actions.compare {Compare runs} {::analog_lens::open_tab compare}] -side left
    pack [button $w.actions.close Close [list destroy $w]] -side right
    set b [dialog_page $w]
    ttk::frame $b.view -padding 12; pack $b.view -fill both -expand 1
    build_verification_view $b.view
    dialog_chrome $w $b.view.table
    update_verification_text
    render_verification_view $b.view
}
proc ::analog_lens::finish_result_run {} {
    verify_sizing_result
    update_freshness
    if {[llength [info commands winfo]]} {render_compare}
    if {[catch {archive_run} why]} {set ::analog_lens::project_message "Run loaded; history could not be saved: $why"}
    catch {project_flush}
    set path [get [get $::analog_lens::result_metadata raw] path]
    if {$path ne {}} {catch {atomic_write [file rootname $path].metadata $::analog_lens::result_metadata}}
}
