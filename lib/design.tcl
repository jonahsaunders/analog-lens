# Geometry changes are previewed, checked again, and grouped into one xschem Undo.
namespace eval ::analog_lens {
    variable size_plan {}; variable sizing_result {}; variable sizing_preview_text {}
    variable target_fingers {}; variable target_copies {}; variable verification_tolerance 10
    variable lookup_match_message {}; variable lookup_match_key {}
}
proc ::analog_lens::normalized_model {model} {
    return [regsub {^(sky130_fd_pr__|gf180mcu_fd_pr__)} $model {}]
}
proc ::analog_lens::supported_model {device} {
    set model [normalized_model [get $device model]]
    set choices [dict create sky130 {nfet_01v8 pfet_01v8} gf180 {nfet_03v3 pfet_03v3} ihp {sg13_lv_nmos sg13_lv_pmos}]
    set family [get $device family]
    if {![dict exists $choices $family] || $model ni [dict get $choices $family]} {
        error {This model has no verified geometry/characterization profile. Supported: SKY130 1.8 V, GF180 3.3 V, and IHP low-voltage MOS.}
    }
    if {[get $device type] ni {nmos pmos} || [get $device name] ne [get $device owner]} {error {Select a scalar MOS instance, not an array element.}}
    return $model
}
proc ::analog_lens::dimension_um {value family} {
    set number [spice_number $value]
    if {$number eq {} || $number <= 0} {error {Geometry must use positive literal dimensions. Edit parameterized geometry in xschem.}}
    # SKY130 symbols use micron-valued W/L; GF180 and IHP use SPICE meters.
    if {$family eq "sky130" && [string is double -strict $value]} {return $number}
    return [expr {$number*1e6}]
}
proc ::analog_lens::compatible_slices {device} {
    variable lut_rows; variable result_metadata; variable declared
    set model [normalized_model [get $device model]]; set pdk [active_pdk]
    set conditions $declared
    if {[get [get $result_metadata raw] path] ne {}} {set conditions $result_metadata}
    # Measured biases are checked with the transport tolerance below. Exclude
    # their project-wide declarations from the exact metadata comparison.
    foreach {key metric sign} {vds_v terminal_vds 1 vsb_v terminal_vbs -1} {
        set value [number [get [get $device values] $metric]]
        if {$value ne {}} {dict unset conditions $key}
    }
    set found {}
    foreach slice [dict keys [lookup_index]] {
        if {[dict exists $found $slice] || [lindex $slice 0] ne $pdk || [normalized_model [lindex $slice 1]] ne $model} {continue}
        lassign $slice lp lm corner temp vds vsb width
        if {[llength [condition_differences $conditions [dict create pdk $lp corner $corner temp_c $temp vds_v $vds vsb_v $vsb]]]} {continue}
        set mismatch 0
        foreach metric {terminal_vds terminal_vbs} bias [list $vds [expr {-$vsb}]] {
            set measured [number [get [get $device values] $metric]]
            # xschem's raw API has limited precision; allow 10 ppm or 1 µV.
            if {$measured ne {} && abs($measured-$bias) > max(1e-6,abs($bias)*1e-5)} {set mismatch 1}
        }
        if {$mismatch} {continue}
        dict set found $slice 1
    }
    return [dict keys $found]
}
proc ::analog_lens::auto_select_lookup {} {
    variable lookup_match_key; variable lookup_match_message; variable lut_slice; variable lut_file
    set device [current_device]; if {$device eq {}} {return}
    set key [list [context] [get $device name] [get $device model] $lut_file $::analog_lens::declared $::analog_lens::result_metadata]
    if {$key eq $lookup_match_key} {return}; set lookup_match_key $key
    set choices [compatible_slices $device]
    if {[llength $choices] == 1} {
        set next [lindex $choices 0]
        if {$next ne $lut_slice} {set lut_slice $next; rebuild_lookup_filters}
        set lookup_match_message {Compatible model and conditions selected.}
    } elseif {[llength $choices] > 1} {
        set lookup_match_message {Several compatible curves exist; select corner, bias and reference width in the explorer.}
    } else {set lookup_match_message {No compatible curve loaded. Characterize this model or load its lookup CSV.}}
}
proc ::analog_lens::size_selected {} {
    set r [current_device]; if {$r eq {}} {error {Select one transistor in the schematic.}}
    supported_model $r
    show; follow_selection; auto_select_lookup
    open_tab design; refresh_workspace
}
proc ::analog_lens::make_size_plan {} {
    normalize_sizing_inputs
    set trust [require_lookup_current]
    set r [current_device]; if {$r eq {}} {error {Select exactly one MOS in the schematic.}}
    supported_model $r
    if {$::analog_lens::run_channel ne {}} {error {Finish or cancel the simulation before changing geometry.}}
    if {$::analog_lens::lut_slice ni [compatible_slices $r]} {error {Select a lookup slice matching this PDK, model and known conditions. Synthetic demo curves cannot be applied.}}
    set result [sizing $::analog_lens::lut_rows $::analog_lens::lut_slice $::analog_lens::target_length $::analog_lens::target_gmid $::analog_lens::target_gm_u]
    set family [get $r family]; set owner [get $r owner]
    dimension_um [get $r width] $family; dimension_um [get $r length] $family
    set geometry [geometry_plan $r [get $result width] $::analog_lens::target_length $::analog_lens::target_fingers $::analog_lens::target_copies]
    set width [get $geometry width]; set length $::analog_lens::target_length
    set w [format %.10g $width]; set l [format %.10g $length]
    if {$family ne "sky130"} {append w u; append l u}
    set fingers [get $geometry fingers]; set copies [get $geometry copies]
    if {$family eq "ihp"} {set edits [dict create w $w l $l ng $fingers m $copies]} elseif {$family eq "sky130"} {
        set edits [dict create W $w L $l nf $fingers mult $copies]
    } else {set edits [dict create W $w L $l nf $fingers m $copies]}
    foreach {upper lower value} [list W w $w L l $l] {
        foreach key [list $upper $lower] {if {[property $owner [list $key]] ne {}} {dict set edits $key $value}}
    }
    foreach key {nf ng} {if {[property $owner [list $key]] ne {}} {dict set edits $key $fingers}}
    # The installed SKY130 symbol emits mult=@mult and m=@mult. The
    # standalone instance m alias is not a second intended copy count.
    if {$family eq "sky130" && [property $owner {m}] ne {}} {dict set edits m 1}
    if {$family ne "sky130" && [property $owner {mult}] ni {{} 1}} {error {Unexpected extra mult property; resolve its simulator meaning before sizing.}}
    set tolerance [number $::analog_lens::verification_tolerance]
    if {$tolerance eq {} || $tolerance <= 0 || $tolerance > 100} {error {Verification tolerance must be above 0 and at most 100 percent.}}
    set before [xschem getprop instance $owner]
    set previous {}; dict for {key value} $edits {dict set previous $key [property $owner [list $key]]}
    return [dict create context [context] owner $owner model [get $r model] before $before edits $edits \
        result $result geometry $geometry tolerance $tolerance length $length lookup [raw_signature $::analog_lens::lut_file] slice $::analog_lens::lut_slice \
        trust $trust previous_edits $previous targets [sizing_targets]]
}
proc ::analog_lens::preview_size {{inline 0}} {
    variable size_plan; variable sizing_preview_text; variable window
    set size_plan [make_size_plan]; set owner [get $size_plan owner]
    set sizing_preview_text "[get $size_plan model] · $owner\n\n"
    append sizing_preview_text [geometry_preview $size_plan]
    append sizing_preview_text "\n[bias_preview $size_plan [current_device]]\nLookup trust: [get [get $size_plan trust] reason]\n"
    append sizing_preview_text "\nLookup: [join [get $size_plan slice] { · }]\nGeometry: [get [get $size_plan geometry] fingers] fingers × [get [get $size_plan geometry] copies] parallel copies.\nPer-finger width: [format %.5g [get [get $size_plan geometry] finger_width]] µm. Total realized width: [format %.5g [get [get $size_plan geometry] total_width]] µm.\nVerification tolerance: ±[get $size_plan tolerance]% for gm and gm/Id.\n[condition_confidence [current_device]]\n\nParasitic formulas remain unchanged; fixed parasitic values need your review. Width scaling is an estimate. Run the circuit to verify.\n\nApply changes only the open schematic. xschem Undo restores all these properties in one step; saving remains your choice."
    if {$inline} {return $size_plan}
    set w $window.sizepreview
    if {[winfo exists $w]} {destroy $w}
    toplevel $w; wm title $w {Preview geometry changes · Analog Lens}; wm transient $w $window
    wm geometry $w 720x540; wm minsize $w 440 360
    ttk::frame $w.actions -padding 12; pack $w.actions -side bottom -fill x
    pack [button $w.actions.apply Apply [list ::analog_lens::apply_size_plan 0]] -side left
    pack [button $w.actions.run {Apply & run OP} [list ::analog_lens::apply_size_plan 1]] -side left -padx 8
    pack [button $w.actions.native {Apply & run testbench} [list ::analog_lens::apply_size_plan 2]] -side left
    set_enabled $w.actions.native [expr {[xschem get currsch] == 0}]
    set_enabled $w.actions.run [expr {[xschem get currsch] == 0}]
    pack [button $w.actions.cancel Cancel [list destroy $w]] -side right
    text $w.text -wrap word -state normal; text_style $w.text
    ttk::scrollbar $w.scroll -command [list $w.text yview]; $w.text configure -yscrollcommand [list $w.scroll set]
    pack $w.scroll -side right -fill y; pack $w.text -fill both -expand 1
    $w.text insert end $sizing_preview_text; $w.text configure -state disabled
    dialog_chrome $w $w.actions.cancel $w.actions.native
    action_bar $w.actions {apply run native cancel}
}
proc ::analog_lens::apply_size_plan {{rerun 0}} {
    variable size_plan
    if {$size_plan eq {}} {error {Preview the geometry changes first.}}
    require_lookup_current
    if {$::analog_lens::run_channel ne {}} {error {Wait for the current simulation.}}
    if {[context] ne [get $size_plan context]} {error {The schematic changed. Preview again.}}
    set owner [get $size_plan owner]
    set selection [xschem selected_set]
    if {[llength $selection] != 1 || [lindex $selection 0] ne $owner || [xschem getprop instance $owner] ne [get $size_plan before]} {error {Selection or geometry changed. Preview again.}}
    if {[raw_signature $::analog_lens::lut_file] ne [get $size_plan lookup] || $::analog_lens::lut_slice ne [get $size_plan slice] ||
        [sizing_targets] ne [get $size_plan targets]} {error {Lookup data or targets changed. Preview again.}}
    if {$rerun && [xschem get currsch] != 0} {error {Apply here, save the subcircuit, and return to the top-level testbench to rerun.}}
    set r [current_device]
    if {[get $r values] ne {}} {
        set ::analog_lens::baseline_name "Before sizing $owner [clock format [clock seconds] -format %H:%M:%S]"
        keep_baseline
    }
    xschem push_undo
    try {
        dict for {key value} [get $size_plan edits] {xschem setprop -fast instance $owner $key $value}
    } on error {why options} {
        catch {xschem setprop -fast instance $owner allprops [get $size_plan before]; xschem redraw}
        return -options $options $why
    }
    # Also invalidate tests/hosts without the edit notification trace.
    set key [lindex [project_identity] 0]; if {$key ne {}} {dict incr ::analog_lens::edit_revisions $key}
    set applied_plan $size_plan
    set size_plan {}; xschem redraw
    if {[winfo exists $::analog_lens::window.sizepreview]} {destroy $::analog_lens::window.sizepreview}
    set ::analog_lens::status {Geometry applied. xschem Undo restores it; rerun to verify and compare.}
    begin_verification $applied_plan $r
    update_freshness; project_flush
    if {$rerun == 1} {run_op} elseif {$rerun == 2} {run_testbench}
}

proc ::analog_lens::sizing_targets {} {
    return [list $::analog_lens::target_length $::analog_lens::target_gmid $::analog_lens::target_gm_u $::analog_lens::target_fingers $::analog_lens::target_copies $::analog_lens::verification_tolerance]
}
proc ::analog_lens::geometry_plan {device total length fingers copies} {
    supported_model $device
    set family [get $device family]
    if {$fingers eq {}} {set fingers [get $device fingers 1]; if {$fingers eq {}} {set fingers 1}}
    if {$copies eq {}} {
        set copies [get $device multiplier 1]; if {$copies eq {}} {set copies 1}

    }
    foreach value [list $fingers $copies] {
        if {![string is integer -strict $value] || $value < 1 || $value > 1024} {error {Fingers and parallel copies must be integers from 1 to 1024. Blank preserves the existing count.}}
    }
    # Conservative supported profile limits, not a replacement for PDK DRC.
    lassign [dict get {sky130 {0.15 0.42} gf180 {0.28 0.22} ihp {0.13 0.15}} $family] min_l min_w
    if {$length < $min_l || $length > 1000} {error "Length is outside this profile's supported range ($min_l–1000 µm)."}
    set finger [expr {$total/($fingers*$copies)}]
    if {$finger < $min_w || $finger > 1000} {error "Per-finger width must be $min_w–1000 µm. Change the finger/copy counts or target gm."}
    # Round width up on a conservative 5 nm grid; never silently change L,
    # because that would select a different characterized curve.
    set finger [expr {ceil($finger/0.005-1e-9)*0.005}]
    if {abs($length/0.005-round($length/0.005)) > 1e-6} {error {Choose a characterized length on the supported 5 nm grid.}}
    return [dict create fingers $fingers copies $copies finger_width $finger width [expr {$finger*$fingers}] total_width [expr {$finger*$fingers*$copies}]]
}
