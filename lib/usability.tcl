# Guided, optional workflows. Reuse the same guarded sizing and run operations.
namespace eval ::analog_lens {
    variable workspace_message {}; variable workspace_device {}; variable workspace_metrics {}
    variable workspace_bias {}
    variable workspace_conditions {Use this device's conditions to copy known values. Unknown fields stay blank.}
    variable workspace_lookup {}; variable workspace_choices {}; variable workspace_choice {}
    variable workspace_advanced 0; variable workspace_details 0; variable workspace_key {}
    variable field_help {Enter a target, preview the changes, then apply and run to measure the result.}
    variable setup_report {}; variable setup_detail {}; variable setup_rows {}; variable setup_result {}; variable setup_analysis auto
    variable corner_note {}; variable workspace_render_key {}; variable workspace_view_key {}
}
proc ::analog_lens::quantity {value kind} {
    set value [string trim [string map {µ u μ u − -} $value]]
    if {![regexp {^([+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)\s*([^[:space:]]*)$} $value -> n suffix] || [number $n] eq {}} {
        error {Enter a finite number with an optional unit, for example 800 µS, 0.8 mS or 700 mV.}
    }
    switch -- $kind {
        gm {set factors {{} 1 S 1000000 mS 1000 uS 1 nS 0.001 pS 0.000001 m 1000 u 1 n 0.001}}
        length {set factors {{} 1 m 1000000 mm 1000 um 1 nm 0.001 u 1 n 0.001}}
        voltage {set factors {{} 1 V 1 mV 0.001 uV 0.000001 m 0.001 u 0.000001}}
        temperature {set factors {{} 1 C 1 °C 1}}
        gmid {set factors {{} 1 1/V 1 V^-1 1}}
        percent {set factors {{} 1 % 1}}
        default {error "Unknown quantity type: $kind"}
    }
    if {![dict exists $factors $suffix]} {error "Unit '$suffix' does not match $kind."}
    set result [expr {$n*[dict get $factors $suffix]}]
    if {[number $result] eq {}} {error {The converted value is outside the finite numeric range.}}
    # Tcl's canonical numeric representation keeps full double precision and
    # avoids turning 0.3 into a different string key such as 0.29999999999999999.
    return $result
}
proc ::analog_lens::quantity_list {text kind} {
    # Join unit words to their preceding number before separating a list.
    regsub -all {([0-9])\s+(µm|μm|um|nm|mm|mV|uV|µV|μV|V|°C|C)(?=\s|,|$)} [string trim $text] {\1\2} text
    set result {}
    foreach value [regexp -all -inline {[^,[:space:]]+} $text] {lappend result [quantity $value $kind]}
    if {![llength $result]} {error {Enter at least one value.}}
    return $result
}
proc ::analog_lens::normalize_sizing_inputs {} {
    set next {}
    foreach {key kind} {target_length length target_gmid gmid target_gm_u gm verification_tolerance percent} {
        set root $::analog_lens::window.tabs.design.body.canvas.content.inputs
        set widget $root.$key
        if {$key eq "verification_tolerance"} {set widget $root.advanced.$key}
        if {[catch {quantity [set ::analog_lens::$key] $kind} value]} {
            if {$key eq "verification_tolerance" && [llength [info commands winfo]] && [winfo exists $widget]} {
                set ::analog_lens::workspace_advanced 1; workspace_advanced
            }
            field_error $widget "[dict get {target_length Length target_gmid gm/Id target_gm_u gm verification_tolerance Tolerance} $key]: $value"
        }
        if {[llength [info commands winfo]] && [winfo exists $widget]} {$widget state !invalid}
        dict set next $key $value
    }
    dict for {key value} $next {if {[set ::analog_lens::$key] ne $value} {set ::analog_lens::$key $value}}
}
proc ::analog_lens::field_error {widget message} {
    if {[llength [info commands winfo]] && [winfo exists $widget]} {
        $widget state invalid; focus $widget
        set clear [list $widget state !invalid]
        if {[string first $clear [bind $widget <KeyRelease>]] < 0} {bind $widget <KeyRelease> +$clear}
    }
    return -code error $message
}
proc ::analog_lens::hint {widget text {variable ::analog_lens::field_help}} {
    bind $widget <FocusIn> +[list set $variable $text]
    bind $widget <Enter> +[list set $variable $text]
}
proc ::analog_lens::scroll_page {w} {
    canvas $w.canvas -highlightthickness 0 -borderwidth 0 -background [dict get $::analog_lens::colors bg]
    ttk::scrollbar $w.scroll -orient vertical -command [list $w.canvas yview]
    $w.canvas configure -yscrollcommand [list $w.scroll set]
    pack $w.scroll -side right -fill y; pack $w.canvas -fill both -expand 1
    ttk::frame $w.canvas.content -padding 4
    $w.canvas create window 0 0 -anchor nw -window $w.canvas.content -tags content
    bind $w.canvas <Configure> [list ::analog_lens::page_width $w.canvas %w]
    bind $w.canvas.content <Configure> [list ::analog_lens::page_region $w.canvas]
    bind $w.canvas <Button-4> [list $w.canvas yview scroll -3 units]
    bind $w.canvas <Button-5> [list $w.canvas yview scroll 3 units]
    return $w.canvas.content
}
proc ::analog_lens::page_width {canvas width} {
    if {[winfo exists $canvas]} {$canvas itemconfigure content -width $width}
}
proc ::analog_lens::page_region {canvas} {
    if {[winfo exists $canvas]} {$canvas configure -scrollregion [$canvas bbox all]}
}
proc ::analog_lens::workspace_focus {widget} {
    set c $::analog_lens::window.tabs.design.body.canvas
    if {![winfo exists $c] || ![string match ${c}.content.* $widget]} {return}
    set y [expr {[winfo rooty $widget]-[winfo rooty $c]+[$c canvasy 0]}]
    set height [winfo height $widget]; set viewport [winfo height $c]
    set total [lindex [$c cget -scrollregion] 3]
    if {$total <= 0} {return}
    if {$y < [$c canvasy 0]} {$c yview moveto [expr {$y/double($total)}]}
    if {$y+$height > [$c canvasy 0]+$viewport} {$c yview moveto [expr {($y+$height-$viewport)/double($total)}]}
}
proc ::analog_lens::workspace_action {command} {
    set ::analog_lens::workspace_message {}
    set label $::analog_lens::window.tabs.design.message
    if {[winfo exists $label]} {$label configure -style AL.TLabel}
    if {[catch {uplevel #0 $command} why]} {
        set ::analog_lens::workspace_message $why
        set ::analog_lens::status $why
        if {[winfo exists $label]} {$label configure -style AL.Error.TLabel}
    }
    refresh_workspace
}
proc ::analog_lens::workspace_preview {} {
    preview_size 1
    set ::analog_lens::workspace_message {Preview ready. Review the changes below, then Apply & run testbench.}
}
proc ::analog_lens::workspace_advanced {} {
    set w $::analog_lens::window.tabs.design.body.canvas.content.inputs
    if {$::analog_lens::workspace_advanced} {grid $w.advanced -row 4 -column 0 -columnspan 2 -sticky ew -pady 8} else {grid remove $w.advanced}
}
proc ::analog_lens::build_design {w} {
    set ::analog_lens::workspace_view_key {}
    ttk::label $w.title -textvariable ::analog_lens::workspace_device -style AL.Heading.TLabel
    pack $w.title -fill x; wrapping $w.title
    ttk::label $w.metrics -textvariable ::analog_lens::workspace_metrics -wraplength 800
    pack $w.metrics -fill x -pady {4 8}; wrapping $w.metrics
    ttk::label $w.bias -textvariable ::analog_lens::workspace_bias -wraplength 800
    pack $w.bias -fill x -pady {0 6}; wrapping $w.bias
    ttk::button $w.next -text {Select a transistor} -style AL.Primary.TButton
    pack $w.next -anchor w -pady {0 8}
    ttk::frame $w.recovery; pack $w.recovery -fill x
    ttk::label $w.recovery.reason -wraplength 700 -style AL.Muted.TLabel
    pack $w.recovery.reason -fill x; wrapping $w.recovery.reason
    ttk::frame $w.recovery.actions; pack $w.recovery.actions -fill x
    for {set i 0} {$i < 3} {incr i} {ttk::button $w.recovery.actions.b$i; pack $w.recovery.actions.b$i -side left -padx {0 8} -pady 4}
    ttk::label $w.message -textvariable ::analog_lens::workspace_message -style AL.TLabel
    pack $w.message -fill x -pady {0 6}; wrapping $w.message
    ttk::frame $w.body; pack $w.body -fill both -expand 1
    set b [scroll_page $w.body]
    ttk::labelframe $b.conditions -text {1  Device conditions and lookup} -padding 10
    grid $b.conditions -row 0 -column 0 -columnspan 2 -sticky ew -pady {0 10}
    ttk::frame $b.conditions.actions; pack $b.conditions.actions -fill x
    foreach {name title command} {
        use {Use this device's conditions} ::analog_lens::use_device_conditions
        load {Load lookup…} ::analog_lens::load_lut
        generate {Generate lookup…} ::analog_lens::characterize_dialog
    } {ttk::button $b.conditions.actions.$name -text $title -command [list ::analog_lens::workspace_action $command]}
    flow_controls $b.conditions.actions {use load generate} 800
    bind $b.conditions.actions <Configure> [list ::analog_lens::flow_controls $b.conditions.actions {use load generate} %w]
    ttk::label $b.conditions.note -textvariable ::analog_lens::workspace_conditions; pack $b.conditions.note -fill x -pady 5; wrapping $b.conditions.note
    ttk::label $b.conditions.choicelabel -text {Matching saved lookups}
    ttk::combobox $b.conditions.choice -textvariable ::analog_lens::workspace_choice -state readonly
    bind $b.conditions.choice <<ComboboxSelected>> {::analog_lens::workspace_action ::analog_lens::choose_workspace_lookup}
    ttk::label $b.conditions.lookup -textvariable ::analog_lens::workspace_lookup -style AL.Muted.TLabel
    pack $b.conditions.lookup -fill x -pady {4 0}; wrapping $b.conditions.lookup
    ttk::labelframe $b.inputs -text {2  Targets and geometry} -padding 10
    grid $b.inputs -row 1 -column 0 -sticky new -padx {0 12}
    grid columnconfigure $b.inputs 1 -weight 1
    set row 0
    foreach {key title help} {
        target_length {Length (µm)} {Choose a length present in the lookup. You can enter 500 nm or 0.5 µm.}
        target_gmid {gm/Id (1/V)} {Use a value within the characterized curve. Width scaling alone does not set the gate bias.}
        target_gm_u {Target gm (µS)} {Bare values mean µS. Examples: 800, 800 µS, 0.8 mS.}
    } {
        ttk::label $b.inputs.l$key -text $title; grid $b.inputs.l$key -row $row -column 0 -sticky w -padx {0 12} -pady 5
        if {$key eq "target_length"} {ttk::combobox $b.inputs.$key -textvariable ::analog_lens::target_display($key) -width 16} else {ttk::entry $b.inputs.$key -textvariable ::analog_lens::target_display($key) -width 16}
        grid $b.inputs.$key -row $row -column 1 -sticky ew -pady 5
        hint $b.inputs.$key $help
        bind $b.inputs.$key <Return> {::analog_lens::workspace_action ::analog_lens::workspace_preview; break}
        incr row
    }
    ttk::checkbutton $b.inputs.disclosure -text {Advanced geometry and tolerance} -variable ::analog_lens::workspace_advanced -command ::analog_lens::workspace_advanced
    grid $b.inputs.disclosure -row 3 -column 0 -columnspan 2 -sticky w -pady 6
    ttk::frame $b.inputs.advanced; grid columnconfigure $b.inputs.advanced 1 -weight 1
    set row 0
    foreach {key title help} {
        target_fingers Fingers {Blank keeps the current finger count. An explicit count must satisfy the PDK's per-finger width limits.}
        target_copies {Parallel copies} {Blank keeps the current multiplier. Total width includes all copies.}
        verification_tolerance {Tolerance (%)} {gm and gm/Id must each lie within this percentage of the target to pass. Default: 10%.}
    } {
        ttk::label $b.inputs.advanced.l$key -text $title; grid $b.inputs.advanced.l$key -row $row -column 0 -sticky w -padx {0 12}
        ttk::entry $b.inputs.advanced.$key -textvariable ::analog_lens::$key -width 12
        grid $b.inputs.advanced.$key -row $row -column 1 -sticky ew -pady 4; hint $b.inputs.advanced.$key $help; incr row
    }
    ttk::label $b.inputs.help -textvariable ::analog_lens::field_help -style AL.Muted.TLabel -wraplength 360
    grid $b.inputs.help -row 5 -column 0 -columnspan 2 -sticky ew -pady 6; wrapping $b.inputs.help
    ttk::frame $b.inputs.actions; grid $b.inputs.actions -row 6 -column 0 -columnspan 2 -sticky ew
    foreach {name title command} {
        preview {Preview changes} ::analog_lens::workspace_preview
        apply {Apply & run testbench} {::analog_lens::apply_size_plan 2}
        only {Apply only} {::analog_lens::apply_size_plan 0}
    } {ttk::button $b.inputs.actions.$name -text $title -command [list ::analog_lens::workspace_action $command]}
    flow_controls $b.inputs.actions {preview apply only} 380
    bind $b.inputs.actions <Configure> [list ::analog_lens::flow_controls $b.inputs.actions {preview apply only} %w]
    text $b.inputs.preview -height 11 -wrap word -state disabled; text_style $b.inputs.preview
    ttk::scrollbar $b.inputs.previewscroll -command [list $b.inputs.preview yview]
    $b.inputs.preview configure -yscrollcommand [list $b.inputs.previewscroll set]
    grid $b.inputs.preview -row 7 -column 0 -columnspan 2 -sticky ew -pady {8 0}
    grid $b.inputs.previewscroll -row 7 -column 2 -sticky ns -pady {8 0}
    ttk::checkbutton $b.inputs.allprops -text {Show unchanged properties} -variable ::analog_lens::preview_all -command ::analog_lens::toggle_preview_details
    grid $b.inputs.allprops -row 8 -column 0 -columnspan 2 -sticky w
    ttk::labelframe $b.verify -text {3  Measured verification} -padding 10
    grid $b.verify -row 1 -column 1 -sticky new
    build_verification_view $b.verify
    grid columnconfigure $b 0 -weight 1 -uniform workspace
    grid columnconfigure $b 1 -weight 1 -uniform workspace
    bind $b <Configure> +[list ::analog_lens::workspace_layout $b %w]
    bind $::analog_lens::window <FocusIn> {+if {[focus] eq {%W}} {::analog_lens::workspace_focus %W}}
    bind $::analog_lens::window <Button-4> {+::analog_lens::workspace_wheel %W -3}
    bind $::analog_lens::window <Button-5> {+::analog_lens::workspace_wheel %W 3}
    bind $::analog_lens::window <MouseWheel> {+::analog_lens::workspace_wheel %W [expr {-%D/120}]}
    $b.inputs.actions.apply configure -style AL.TButton
    refresh_workspace
}
proc ::analog_lens::workspace_wheel {widget delta} {
    set c $::analog_lens::window.tabs.design.body.canvas
    if {![winfo exists $c] || ![string match ${c}.content* $widget]} {return}
    if {[winfo class $widget] in {Text Treeview TCombobox}} {return}
    $c yview scroll $delta units
}
proc ::analog_lens::workspace_layout {b width} {
    if {$width < 1000} {
        grid $b.inputs -row 1 -column 0 -columnspan 2 -padx 0
        grid $b.verify -row 2 -column 0 -columnspan 2 -pady 10
    } else {
        grid $b.inputs -row 1 -column 0 -columnspan 1 -padx {0 12}
        grid $b.verify -row 1 -column 1 -columnspan 1 -pady 0
    }
}
proc ::analog_lens::workflow_issues {} {
    set r [current_device]; set issues {}
    if {$::analog_lens::run_channel ne {} || [dict size $::analog_lens::native_jobs]} {
        return [list [list {Simulation is running. Measurements will update when it completes.} {Show run log} ::analog_lens::log_dialog]]
    }
    if {[xschem get currsch] != 0} {
        lappend issues [list {Apply edits here, save in xschem, then return to the parent testbench to rerun.} {Go to parent} ::analog_lens::workspace_parent]
    }
    if {$r eq {}} {lappend issues [list {Select one transistor in the schematic to set targets.} {Inspect devices} {::analog_lens::open_tab op}]} elseif {[catch {supported_model $r} why]} {
        lappend issues [list $why {Supported models} {::analog_lens::open_tab setup}]
    }
    if {[auto_execok ngspice] eq {} || ![info exists ::netlist_dir] || ![file isdirectory $::netlist_dir]} {
        lappend issues [list {The simulator or output directory needs setup.} {Set up project} ::analog_lens::setup_dialog]
    } elseif {![dict size $::analog_lens::result_metadata] || $::analog_lens::freshness_state ne "current"} {
        if {[xschem get currsch] == 0} {lappend issues [list {Run this testbench to obtain current device measurements.} {Rerun testbench} ::analog_lens::run_testbench]}
    }
    if {$r ne {} && ![catch {supported_model $r}] && ![llength [compatible_slices $r]]} {
        lappend issues [list {No compatible curve is loaded for the selected device.} {Generate lookup} ::analog_lens::characterize_dialog]
    }
    if {$::analog_lens::native_result_state eq "attachment_failed"} {
        lappend issues [list $::analog_lens::native_message {Choose result file} ::analog_lens::setup_dialog]
    }
    return $issues
}
proc ::analog_lens::workspace_parent {} {
    # Let xschem present its normal unsaved-change prompt; never save silently.
    xschem go_back
    refresh; update_freshness
}
proc ::analog_lens::refresh_workspace {} {
    set w $::analog_lens::window.tabs.design
    if {![llength [info commands winfo]] || ![winfo exists $w]} {return}
    set r [current_device]
    set trust [lookup_status]
    set viewkey [list [context] $r $::analog_lens::result_metadata $::analog_lens::lut_generation $::analog_lens::lut_slice $::analog_lens::lut_file $trust \
        [sizing_targets] $::analog_lens::size_plan $::analog_lens::sizing_preview_text $::analog_lens::verification_result $::analog_lens::verification_summary \
        $::analog_lens::workspace_details $::analog_lens::run_log $::analog_lens::run_channel $::analog_lens::native_jobs \
        $::analog_lens::freshness_state $::analog_lens::native_result_state $::analog_lens::native_message $::analog_lens::declared \
        $::analog_lens::workspace_choices $::analog_lens::workspace_conditions $::analog_lens::workspace_message]
    if {$viewkey eq $::analog_lens::workspace_view_key} {return}
    set ::analog_lens::workspace_view_key $viewkey
    set next [workflow_next $r $trust]
    $w.next configure -text [get $next label] -command [list ::analog_lens::workspace_action [get $next command]]
    set_enabled $w.next [get $next enabled 1]
    set key [list [context] [get $r owner] [get $r model]]
    if {$key ne $::analog_lens::workspace_key} {
        set ::analog_lens::workspace_key $key
        set ::analog_lens::workspace_choices {}; set ::analog_lens::workspace_choice {}
        set ::analog_lens::workspace_conditions {Use this device's conditions to copy known values. Unknown fields stay blank.}
        set ::analog_lens::workspace_message {}
        # A preview may have been opened before the next selection poll. Keep
        # that valid plan; only a genuinely different device/context clears it.
        set plan $::analog_lens::size_plan
        if {[get $plan context] ne [context] || [get $plan owner] ne [get $r owner] || [get $plan model] ne [get $r model]} {
            set ::analog_lens::size_plan {}; set ::analog_lens::sizing_preview_text {}
        }
    }
    set ::analog_lens::workspace_device [expr {$r eq {} ? "Size & verify · Select a transistor" : "[get $r owner] · [get $r model] · [active_pdk]"}]
    set v [get $r values]
    set ::analog_lens::workspace_metrics "Loaded measurements:  gm [eng [get $v gm] S]   ·   gm/Id [eng [get $v gmid] 1/V]   ·   Id [eng [get $v id] A]"
    set issues [workflow_issues]; set descriptions {}
    for {set i 0} {$i < 3} {incr i} {
        set button $w.recovery.actions.b$i
        if {$i < [llength $issues]} {
            lassign [lindex $issues $i] reason title command; lappend descriptions $reason
            $button configure -text $title -command [list ::analog_lens::workspace_action $command]; pack $button -side left -padx {0 8} -pady 4
        } else {pack forget $button}
    }
    $w.recovery.reason configure -text [join $descriptions \n]
    set b $w.body.canvas.content
    set lengths [get [lookup_index] $::analog_lens::lut_slice]
    $b.inputs.target_length configure -values [lsort -real -unique $lengths]
    $b.conditions.choice configure -values [dict keys $::analog_lens::workspace_choices]
    if {[dict size $::analog_lens::workspace_choices] > 1} {
        pack $b.conditions.choicelabel -before $b.conditions.lookup -anchor w -pady {8 3}
        pack $b.conditions.choice -before $b.conditions.lookup -fill x
    } else {pack forget $b.conditions.choicelabel $b.conditions.choice}
    set ::analog_lens::workspace_lookup [expr {$::analog_lens::lut_file eq {} ? "No lookup loaded." : "Loaded: [file tail $::analog_lens::lut_file] · [join $::analog_lens::lut_slice { · }]"}]
    append ::analog_lens::workspace_lookup " · [get $trust reason]"
    set plan $::analog_lens::size_plan
    set ready [expr {$plan ne {} && [get $plan context] eq [context] && [get $plan targets] eq [sizing_targets] && [get $trust state] ne "outdated"}]
    set ::analog_lens::workspace_bias {}
    if {$ready} {
        set estimate [get $plan result]
        set ::analog_lens::workspace_bias "Preview estimate: required Vgs [eng [get $estimate required_vgs] V] · loaded Vgs [eng [measured_vgs $v] V] · |Id| [eng [get $estimate id] A] · total width [format %.4g [get [get $plan geometry] total_width]] µm"
    }
    set idle [expr {$::analog_lens::run_channel eq {} && ![dict size $::analog_lens::native_jobs]}]
    set_enabled $b.inputs.actions.only [expr {$ready && $idle}]
    set_enabled $b.inputs.actions.apply [expr {$ready && $idle && [xschem get currsch] == 0}]
    set_enabled $b.inputs.actions.preview [expr {$r ne {} && $idle}]
    set preview [expr {$ready ? $::analog_lens::sizing_preview_text : "Preview the current targets before applying changes. One xschem Undo restores the complete edit."}]
    if {[$b.inputs.preview get 1.0 end-1c] ne $preview} {$b.inputs.preview configure -state normal; $b.inputs.preview delete 1.0 end; $b.inputs.preview insert end $preview; $b.inputs.preview configure -state disabled}
    render_verification_view $b.verify
}
proc ::analog_lens::device_conditions {device} {
    set metadata $::analog_lens::result_metadata
    if {[get $metadata design_stamp] eq {} || [get $metadata design_stamp] ne [design_stamp] || [get [dependency_status 1] state] eq "changed"} {
        error {Run the current testbench before reusing device conditions. These measurements are unverified or out of date.}
    }
    set result {}; set sources {}
    foreach key {corner temp_c} {
        set value [get [get $metadata observed_conditions] $key]
        set source observed
        if {$value eq {}} {set value [get $metadata $key]; set source declared}
        dict set result $key $value; dict set sources $key [expr {$value eq {} ? "unknown" : $source}]
    }
    foreach {key metric sign} {vds_v terminal_vds 1 vsb_v terminal_vbs -1} {
        set value [number [get [get $device values] $metric]]
        dict set result $key [expr {$value eq {} ? "" : [format %.12g [expr {$sign*$value}]]}]
        dict set sources $key [expr {$value eq {} ? "unknown" : "measured"}]
    }
    dict set result sources $sources
    return $result
}
proc ::analog_lens::use_device_conditions {} {
    if {$::analog_lens::char_channel ne {}} {error {Wait for characterization to finish before changing its inputs.}}
    refresh_workspace
    set device [current_device]; supported_model $device
    set conditions [device_conditions $device]
    prepare_characterization $device
    set labels {}
    foreach {field key title unit} {corner corner Corner {} temp temp_c Temperature °C vds vds_v Vds V vsb vsb_v Vsb V} {
        set value [get $conditions $key]; set ::analog_lens::char_edit($field) $value
        lappend labels "$title: [expr {$value eq {} ? "Unknown — enter it before generating" : "$value $unit ([get [get $conditions sources] $key])"}]"
    }
    set ::analog_lens::workspace_conditions [join $labels { · }]
    set ::analog_lens::workspace_choices {}; set ::analog_lens::workspace_choice {}
    if {{unknown} in [dict values [get $conditions sources]]} {
        set ::analog_lens::workspace_message {Known conditions copied. Fill the unknown fields in Generate lookup; no saved curve was selected automatically.}
        return
    }
    set matches [find_saved_lookups $device $conditions]
    set index 0
    foreach match $matches {
        lassign $match path slice
        set label "[incr index]. [file tail [file dirname $path]] · [lindex $slice 2] · [lindex $slice 3] °C · Wref [lindex $slice 6] µm"
        dict set ::analog_lens::workspace_choices $label $match
    }
    if {[llength $matches] == 1} {
        set ::analog_lens::workspace_choice [lindex [dict keys $::analog_lens::workspace_choices] 0]
        choose_workspace_lookup
        set ::analog_lens::workspace_message {Conditions copied and the unique compatible saved lookup loaded.}
    } elseif {[llength $matches] > 1} {
        set ::analog_lens::workspace_message {Conditions copied. Several saved lookups match; choose one from the list.}
    } else {set ::analog_lens::workspace_message {Conditions copied. Generate a lookup for these conditions, or load an existing CSV.}}
    refresh_workspace
}
proc ::analog_lens::find_saved_lookups {device conditions} {
    set matches {}; set directory [lindex [project_identity] 1]
    set paths [glob -nocomplain -directory [file join $directory .analog-lens lookups] */*.csv]
    if {$::analog_lens::lut_file ne {} && [file isfile $::analog_lens::lut_file]} {lappend paths $::analog_lens::lut_file}
    foreach path [lsort -unique $paths] {
        if {[file size $path] > 50000000 || [catch {parse_lut [read_text $path]} rows]} {continue}
        if {[get [lookup_status 1 $path] state] eq "outdated"} {continue}
        set slices {}; foreach row $rows {dict set slices [get $row slice] 1}
        foreach slice [dict keys $slices] {
            lassign $slice pdk model corner temp vds vsb width
            if {$pdk ne [active_pdk] || [normalized_model $model] ne [normalized_model [get $device model]] || $corner ne [get $conditions corner]} {continue}
            set same 1
            foreach key {temp_c vds_v vsb_v} value [list $temp $vds $vsb] {
                set expected [number [get $conditions $key]]
                if {$expected eq {} || abs($expected-$value) > max(1e-6,abs($expected)*1e-5)} {set same 0}
            }
            if {$same} {lappend matches [list $path $slice]}
        }
    }
    return $matches
}
proc ::analog_lens::choose_workspace_lookup {} {
    if {![dict exists $::analog_lens::workspace_choices $::analog_lens::workspace_choice]} {error {Choose a compatible saved lookup first.}}
    lassign [dict get $::analog_lens::workspace_choices $::analog_lens::workspace_choice] path slice
    set device [current_device]; set conditions [device_conditions $device]
    if {[list $path $slice] ni [find_saved_lookups $device $conditions]} {error {The selected lookup or device conditions changed. Use this device's conditions again.}}
    load_lookup_file $path
    set ::analog_lens::lut_slice $slice
    rebuild_lookup_filters; set ::analog_lens::lookup_match_key {}
}
proc ::analog_lens::verification_value {value metric} {
    if {[number $value] eq {}} {return —}
    if {$metric eq "gm"} {return [eng $value S]}
    return "[format %.4g $value] 1/V"
}
proc ::analog_lens::build_verification_view {w} {
    dict unset ::analog_lens::workspace_render_key $w
    ttk::label $w.summary -textvariable ::analog_lens::verification_summary -style AL.Heading.TLabel -wraplength 400
    pack $w.summary -fill x -pady {0 8}; wrapping $w.summary
    ttk::label $w.advice -textvariable ::analog_lens::verification_advice -wraplength 400
    pack $w.advice -fill x -pady {0 8}; wrapping $w.advice
    ttk::treeview $w.table -columns {metric target before after error} -show headings -height 2 -selectmode none -style AL.Treeview
    foreach {key title} {metric Metric target Target before Before after After error {Error (%)}} {
        $w.table heading $key -text $title
        set width [expr {max([font measure ALHeading $title],[font measure ALBody {−999.99 mS}])+24}]
        $w.table column $key -width $width -minwidth $width -stretch 1 -anchor e
    }
    $w.table column metric -anchor w
    ttk::frame $w.tablearea; pack $w.tablearea -fill x
    ttk::scrollbar $w.tablearea.scroll -orient horizontal -command [list $w.table xview]
    $w.table configure -xscrollcommand [list $w.tablearea.scroll set]
    pack $w.table -in $w.tablearea -fill x; raise $w.table $w.tablearea
    pack $w.tablearea.scroll -fill x
    canvas $w.chart -height 165 -highlightthickness 0 -background [dict get $::analog_lens::colors field]
    pack $w.chart -fill x -pady 8
    bind $w.chart <Configure> [list ::analog_lens::draw_verification $w.chart]
    ttk::label $w.note -text {Band: allowed range · Circle: before · Diamond: after. Width changes alone may not meet gm/Id at a fixed gate bias.} -wraplength 400 -style AL.Muted.TLabel
    pack $w.note -fill x; wrapping $w.note
    ttk::checkbutton $w.more -text {Show measurement details and run log} -variable ::analog_lens::workspace_details -command [list ::analog_lens::verification_details $w]
    pack $w.more -anchor w -pady 8
    ttk::frame $w.details
    text $w.details.text -height 12 -wrap word -state disabled; text_style $w.details.text
    ttk::scrollbar $w.details.scroll -command [list $w.details.text yview]; $w.details.text configure -yscrollcommand [list $w.details.scroll set]
    pack $w.details.scroll -side right -fill y; pack $w.details.text -fill both -expand 1
}
proc ::analog_lens::verification_details {w} {
    foreach view [list $::analog_lens::window.verification.page.canvas.content.view $::analog_lens::window.tabs.design.body.canvas.content.verify] {
        if {[winfo exists $view.details]} {render_verification_view $view}
    }
}
proc ::analog_lens::render_verification_view {w} {
    if {![winfo exists $w]} {return}
    set key [list $::analog_lens::verification_result $::analog_lens::verification_summary $::analog_lens::workspace_details $::analog_lens::run_log $::analog_lens::native_message]
    if {[get $::analog_lens::workspace_render_key $w] eq $key} {return}
    dict set ::analog_lens::workspace_render_key $w $key
    if {$::analog_lens::workspace_details} {pack $w.details -fill both -expand 1} else {pack forget $w.details}
    $w.table delete [$w.table children {}]
    foreach row [get $::analog_lens::verification_result rows] {
        set metric [get $row metric]; set values [list [expr {$metric eq "gm" ? "gm" : "gm/Id"}]]
        foreach key {target before measured} {lappend values [verification_value [get $row $key] $metric]}
        lappend values [expr {[get $row error_percent] eq {} ? "Missing" : [format %+.2f [get $row error_percent]]}]
        $w.table insert {} end -values $values
    }
    if {$::analog_lens::workspace_details} {
        set text "$::analog_lens::verification_text\n\nNative run: $::analog_lens::native_message\nNative simulator output is available in xschem's simulation console.\n\nIsolated OP log:\n$::analog_lens::run_log"
        $w.details.text configure -state normal; $w.details.text delete 1.0 end; $w.details.text insert end $text; $w.details.text configure -state disabled
    }
    draw_verification $w.chart
}
proc ::analog_lens::draw_verification {c} {
    if {![winfo exists $c]} {return}
    $c delete all
    set fg [dict get $::analog_lens::colors field_fg]; set border [dict get $::analog_lens::colors border]
    set accent [lindex [dict get $::analog_lens::colors curves] 0]
    set rows [get $::analog_lens::verification_result rows]
    if {![llength $rows]} {$c create text 16 40 -anchor nw -fill $fg -font ALBody -text {Apply and run to see measured targets here.} -width [expr {max(180,[winfo width $c]-32)}]; return}
    set line [font metrics ALBody -linespace]
    set gap [expr {max(77,3*$line+22)}]
    $c configure -height [expr {2*$gap+12}]
    set left [expr {[font measure ALBody gm/Id]+18}]; set right [expr {max(200,[winfo width $c]-22)}]; set y 30
    foreach row $rows {
        set target [get $row target]; set tolerance [get $::analog_lens::verification_result tolerance]
        set extent [expr {max(20.,$tolerance*1.5)}]
        set points {}
        foreach key {before measured} {
            set v [number [get $row $key]]
            if {$v ne {}} {set error [expr {100*($v-$target)/abs($target)}]; set extent [expr {max($extent,abs($error)*1.1)}]; dict set points $key $error}
        }
        set scale [expr {($right-$left)/(2.*$extent)}]; set center [expr {($left+$right)/2.}]
        $c create rectangle [expr {$center-$tolerance*$scale}] [expr {$y-12}] [expr {$center+$tolerance*$scale}] [expr {$y+12}] -fill [dict get $::analog_lens::colors grid] -outline $border -tags tolerance
        $c create line $left $y $right $y -fill $border
        $c create line $center [expr {$y-17}] $center [expr {$y+17}] -fill $fg
        $c create text 5 $y -anchor w -fill $fg -text [expr {[get $row metric] eq "gm" ? "gm" : "gm/Id"}]
        dict for {key error} $points {
            set x [expr {$center+$error*$scale}]
            if {$key eq "before"} {$c create oval [expr {$x-4}] [expr {$y-4}] [expr {$x+4}] [expr {$y+4}] -outline $fg -width 2 -tags before} else {
                $c create polygon $x [expr {$y-6}] [expr {$x+6}] $y $x [expr {$y+6}] [expr {$x-6}] $y -fill $accent -tags after
            }
        }
        $c create text $left [expr {$y+23}] -anchor w -fill $fg -text "−[format %.0f $extent]%"
        $c create text $center [expr {$y+23}] -fill $fg -text {Target 0%}
        $c create text $right [expr {$y+23}] -anchor e -fill $fg -text "+[format %.0f $extent]%"
        incr y $gap
    }
    foreach item [$c find all] {if {[$c type $item] eq "text"} {$c itemconfigure $item -font ALBody}}
}
proc ::analog_lens::setup_checks {} {
    set rows {}
    foreach check [environment_checks] {
        lassign $check name state detail
        set action {}; set title {Read guidance}
        switch -- $name {
            {Simulation directory} {set title {Choose directory…}; set action ::analog_lens::setup_choose_directory}
            Testbench {if {[xschem get currsch] != 0} {set title {Go to parent}; set action ::analog_lens::workspace_parent}}
        }
        lappend rows [dict create name $name state $state detail $detail action $action title $title]
    }
    set path $::analog_lens::setup_result
    set state Ready; set detail {Automatic detection accepts one new raw file and prefers the testbench name. The testbench must write its result file.}
    if {$path ne {}} {
        if {[file pathtype $path] eq "relative" && [info exists ::netlist_dir]} {set path [file join $::netlist_dir $path]}
        set parent [file dirname $path]
        if {![file isdirectory $parent] || ![file writable $parent]} {set state Check; set detail {The result file's parent directory is missing or not writable. Choose a path written by this testbench.}} else {set detail "Expected result: $path. The testbench's write command must use this path."}
    }
    lappend rows [dict create name {Result path} state $state detail $detail title {Choose result…} action ::analog_lens::setup_choose_result]
    return $rows
}
proc ::analog_lens::setup_dialog {} {
    show
    set w $::analog_lens::window.onboarding
    if {[winfo exists $w]} {raise $w; setup_refresh; return}
    set ::analog_lens::setup_result [get $::analog_lens::integration_options result_path]
    set ::analog_lens::setup_analysis [get $::analog_lens::integration_options result_analysis]
    toplevel $w; wm title $w {Set up this project · Analog Lens}; wm geometry $w 780x630; wm minsize $w 620 520
    set b [dialog_page $w]
    ttk::frame $b.body -padding 16; pack $b.body -fill both -expand 1
    pack [label $b.body.title {Check setup, then run your testbench} AL.Heading.TLabel] -fill x
    wrapping $b.body.title
    ttk::label $b.body.note -text {Optional setup · Select a check for guidance. No simulation or schematic edits happen until you choose an action.} -wraplength 700
    pack $b.body.note -fill x -pady 8; wrapping $b.body.note
    ttk::treeview $b.body.checks -columns {name state} -show headings -height 7
    $b.body.checks heading name -text Check; $b.body.checks heading state -text Status
    $b.body.checks column name -width 320; $b.body.checks column state -width 100
    pack $b.body.checks -fill x; bind $b.body.checks <<TreeviewSelect>> ::analog_lens::setup_select
    ttk::label $b.body.detail -textvariable ::analog_lens::setup_detail -wraplength 700
    pack $b.body.detail -fill x -pady 10; wrapping $b.body.detail
    ttk::button $b.body.fix -text {Select a check}; pack $b.body.fix -anchor w
    ttk::label $b.body.pathlabel -text {Result file (blank: detect automatically)}; pack $b.body.pathlabel -anchor w -pady {12 4}
    ttk::entry $b.body.path -textvariable ::analog_lens::setup_result; pack $b.body.path -fill x
    pack [label $b.body.analysislabel {Analysis to load}] -anchor w -pady {8 0}
    ttk::combobox $b.body.analysis -textvariable ::analog_lens::setup_analysis -values {auto op dc tran} -state readonly -width 10
    pack $b.body.analysis -anchor w -pady 8
    ttk::label $b.body.status -textvariable ::analog_lens::setup_report -wraplength 700; pack $b.body.status -fill x; wrapping $b.body.status
    ttk::frame $w.actions -padding 12; pack $w.actions -before $w.page -side bottom -fill x
    foreach {name title command} {recheck Recheck ::analog_lens::setup_refresh save {Save settings} ::analog_lens::setup_save run {Save & run testbench} ::analog_lens::setup_run} {
        ttk::button $w.actions.$name -text $title -command [list ::analog_lens::setup_action $command]; pack $w.actions.$name -side left -padx 4
    }
    ttk::button $w.actions.close -text Close -command [list destroy $w]; pack $w.actions.close -side right
    dialog_chrome $w $b.body.checks $w.actions.run
    action_bar $w.actions {recheck save run close}
    setup_refresh
}
proc ::analog_lens::setup_action {command} {
    if {[catch {uplevel #0 $command} why]} {set ::analog_lens::setup_report $why}
}
proc ::analog_lens::setup_refresh {} {
    set w $::analog_lens::window.onboarding.page.canvas.content.body.checks
    set selected [$w selection]; $w delete [$w children {}]
    set ::analog_lens::setup_rows {}; set i 0; set needs 0
    foreach row [setup_checks] {
        set id c[incr i]; dict set ::analog_lens::setup_rows $id $row
        $w insert {} end -id $id -values [list [get $row name] [get $row state]]
        if {[get $row state] ni {Ready Found}} {incr needs}
    }
    set ::analog_lens::setup_report [expr {$needs ? "$needs checks need attention. Select each for the next step." : "Paths and APIs are ready. Run the testbench to validate the actual simulation."}]
    set_enabled $::analog_lens::window.onboarding.actions.run [expr {!$needs}]
    if {[llength $selected] && [$w exists [lindex $selected 0]]} {$w selection set $selected} else {$w selection set c1}
    setup_select
}
proc ::analog_lens::setup_select {} {
    set w $::analog_lens::window.onboarding.page.canvas.content.body
    set id [lindex [$w.checks selection] 0]; if {![dict exists $::analog_lens::setup_rows $id]} {return}
    set row [dict get $::analog_lens::setup_rows $id]; set ::analog_lens::setup_detail [get $row detail]
    set action [get $row action]
    $w.fix configure -text [get $row title] -command [list ::analog_lens::setup_action $action]
    set_enabled $w.fix [expr {$action ne {}}]
}
proc ::analog_lens::setup_choose_directory {} {
    if {$::analog_lens::run_channel ne {} || [dict size $::analog_lens::native_jobs]} {error {Wait for the current simulation before changing its directory.}}
    set path [tk_chooseDirectory -parent $::analog_lens::window.onboarding -title {Choose simulation output directory}]
    if {$path ne {}} {set ::netlist_dir $path; setup_refresh}
}
proc ::analog_lens::setup_choose_result {} {
    set path [tk_getOpenFile -parent $::analog_lens::window.onboarding -filetypes {{{Simulator results} .raw} {{All files} *}}]
    if {$path ne {}} {set ::analog_lens::setup_result $path; setup_refresh}
}
proc ::analog_lens::setup_save {} {
    if {$::analog_lens::setup_analysis ni {auto op dc tran}} {error {Choose OP, DC, transient or automatic analysis.}}
    if {$::analog_lens::run_channel ne {} || [dict size $::analog_lens::native_jobs]} {error {Wait for the current simulation before changing result settings.}}
    dict set ::analog_lens::integration_options result_path [string trim $::analog_lens::setup_result]
    dict set ::analog_lens::integration_options result_analysis $::analog_lens::setup_analysis
    project_flush; setup_refresh
}
proc ::analog_lens::setup_run {} {
    setup_save
    foreach row [setup_checks] {if {[get $row state] ni {Ready Found}} {error {Resolve the setup checks before running.}}}
    run_testbench; set ::analog_lens::setup_report {Simulation started. The inspector will attach the new results when it completes.}
}
namespace eval ::analog_lens {variable char_context {}}
proc ::analog_lens::prepare_characterization {device} {
    set pdk [active_pdk]; set model [supported_model $device]
    set key [list [context] [get $device owner] $pdk $model]
    if {$key eq $::analog_lens::char_context} {return}
    if {$::analog_lens::char_channel ne {}} {error {Wait for the current characterization before changing models.}}
    set ::analog_lens::char_context $key; set ::analog_lens::char_device $device; set ::analog_lens::char_pdk $pdk
    set length [dimension_um [get $device length] [get $device family]]
    set voltage [dict get {sky130A 1.8 gf180mcuD 3.3 ihp-sg13g2 1.2 ihp-sg13cmos5l 1.2} $pdk]
    array set ::analog_lens::char_edit [list lengths [list $length [expr {2*$length}]] width 10 start 0.1 stop $voltage step 0.025 temp 27 vsb 0 \
        vds [expr {[get $device type] eq "pmos" ? -$voltage/2 : $voltage/2}] \
        corner [dict get {sky130A tt gf180mcuD typical ihp-sg13g2 mos_tt ihp-sg13cmos5l mos_tt} $pdk]]
}
proc ::analog_lens::characterization_corners {} {
    set base {}
    if {[info exists ::env(PDK_ROOT)]} {set base [file join $::env(PDK_ROOT) $::analog_lens::char_pdk]} elseif {[info exists ::env(PDKPATH)]} {set base $::env(PDKPATH)}
    if {$base eq {} || [catch {project_helper corners $base --pdk $::analog_lens::char_pdk} choices] || ![llength $choices]} {
        set ::analog_lens::corner_note {Installed sections unavailable. Enter the section name from this PDK's model library.}
        return {}
    }
    set ::analog_lens::corner_note {Corner choices come from the installed MOS model library. You can type additional sections for a custom setup.}
    return $choices
}
proc ::analog_lens::characterization_hint {key} {
    return [dict get {
        lengths {Enter lengths in µm, for example 0.5 1 or 500nm 1um.}
        width {Total reference width in µm. The lookup uses one finger and one copy.}
        corner {Choose an installed section or type one. This changes the characterization model corner.}
        temp {Characterization temperature in °C, for example 27 or 85°C.}
        vds {Signed drain-to-source voltage: positive for NMOS, negative for PMOS. Accepts 700mV.}
        vsb {Source minus body voltage. Use device conditions to copy the measured sign correctly.}
        start {Starting gate-voltage magnitude. PMOS polarity is applied automatically.}
        stop {Ending gate-voltage magnitude within the device's nominal voltage.}
        step {Positive gate-voltage step, for example 25mV.}
    } $key]
}
proc ::analog_lens::normalized_characterization {} {
    set root $::analog_lens::window.characterize.page.canvas.content.form.fields
    if {[catch {quantity_list $::analog_lens::char_edit(lengths) length} lengths]} {field_error $root.lengths "Lengths: $lengths"}
    set result [dict create lengths $lengths]
    foreach {key kind} {width length temp temperature vds voltage vsb voltage start voltage stop voltage step voltage} {
        if {[catch {quantity $::analog_lens::char_edit($key) $kind} value]} {field_error $root.$key "$key: $value"}
        dict set result $key $value
    }
    return $result
}
proc ::analog_lens::characterization_action {command} {
    set ::analog_lens::char_error 0
    if {[catch {uplevel #0 $command} why]} {set ::analog_lens::char_status $why; set ::analog_lens::char_error 1} elseif {[lindex $command 0] eq "::analog_lens::use_device_conditions"} {set ::analog_lens::char_status $::analog_lens::workspace_conditions}
    update_characterization_ui
}
