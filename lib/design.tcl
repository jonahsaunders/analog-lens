# Geometry changes are previewed, checked again, and grouped into one xschem Undo.
namespace eval ::analog_lens {
    variable size_plan {}; variable sizing_result {}; variable sizing_preview_text {}
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
    set found {}
    foreach row $lut_rows {
        set slice [get $row slice]
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
    set ::analog_lens::sizing_visible 1; toggle_sizing; open_tab lut
    if {$::analog_lens::lut_slice ni [compatible_slices $r]} {set ::analog_lens::sizing_error $::analog_lens::lookup_match_message}
}
proc ::analog_lens::make_size_plan {} {
    set r [current_device]; if {$r eq {}} {error {Select exactly one MOS in the schematic.}}
    supported_model $r
    if {$::analog_lens::run_channel ne {}} {error {Finish or cancel the simulation before changing geometry.}}
    if {$::analog_lens::lut_slice ni [compatible_slices $r]} {error {Select a lookup slice matching this PDK, model and known conditions. Synthetic demo curves cannot be applied.}}
    set result [sizing $::analog_lens::lut_rows $::analog_lens::lut_slice $::analog_lens::target_length $::analog_lens::target_gmid $::analog_lens::target_gm_u]
    set family [get $r family]; set owner [get $r owner]
    dimension_um [get $r width] $family; dimension_um [get $r length] $family
    set width [get $result width]; set length $::analog_lens::target_length
    set w [format %.10g $width]; set l [format %.10g $length]
    if {$family ne "sky130"} {append w u; append l u}
    if {$family eq "ihp"} {set edits [dict create w $w l $l ng 1 m 1]} elseif {$family eq "sky130"} {
        set edits [dict create W $w L $l nf 1 mult 1]
    } else {set edits [dict create W $w L $l nf 1 m 1]}
    # Existing alternate dimension names would otherwise remain misleading.
    foreach {upper lower value} [list W w $w L l $l] {
        foreach key [list $upper $lower] {if {[property $owner [list $key]] ne {}} {dict set edits $key $value}}
    }
    foreach key {nf ng mult m} {if {[property $owner [list $key]] ne {}} {dict set edits $key 1}}
    set before [xschem getprop instance $owner]
    return [dict create context [context] owner $owner model [get $r model] before $before edits $edits \
        result $result length $length lookup [raw_signature $::analog_lens::lut_file] slice $::analog_lens::lut_slice \
        targets [list $::analog_lens::target_length $::analog_lens::target_gmid $::analog_lens::target_gm_u]]
}
proc ::analog_lens::preview_size {} {
    variable size_plan; variable sizing_preview_text; variable window
    set size_plan [make_size_plan]; set owner [get $size_plan owner]
    set sizing_preview_text "[get $size_plan model] · $owner\n\n"
    dict for {key value} [get $size_plan edits] {append sizing_preview_text "$key: [property $owner [list $key]] → $value\n"}
    append sizing_preview_text "\nLookup: [join [get $size_plan slice] { · }]\nThis estimate uses one finger and one parallel copy. Total width is [format %.5g [get [get $size_plan result] width]] µm.\n\nParasitic formulas remain unchanged; fixed parasitic values need your review. Width scaling is an estimate. Run the circuit to verify.\n\nApply changes only the open schematic. xschem Undo restores all these properties in one step; saving remains your choice."
    set w $window.sizepreview
    if {[winfo exists $w]} {destroy $w}
    toplevel $w; wm title $w {Preview geometry changes · Analog Lens}; wm transient $w $window
    wm geometry $w 560x480; wm minsize $w 440 360
    ttk::frame $w.actions -padding 12; pack $w.actions -side bottom -fill x
    pack [button $w.actions.apply Apply [list ::analog_lens::apply_size_plan 0]] -side left
    pack [button $w.actions.run {Apply & run OP} [list ::analog_lens::apply_size_plan 1]] -side left -padx 8
    set_enabled $w.actions.run [expr {[xschem get currsch] == 0}]
    pack [button $w.actions.cancel Cancel [list destroy $w]] -side right
    text $w.text -wrap word -state normal; text_style $w.text
    ttk::scrollbar $w.scroll -command [list $w.text yview]; $w.text configure -yscrollcommand [list $w.scroll set]
    pack $w.scroll -side right -fill y; pack $w.text -fill both -expand 1
    $w.text insert end $sizing_preview_text; $w.text configure -state disabled
    bind $w <Escape> [list destroy $w]
}
proc ::analog_lens::apply_size_plan {{rerun 0}} {
    variable size_plan
    if {$size_plan eq {}} {error {Preview the geometry changes first.}}
    if {$::analog_lens::run_channel ne {}} {error {Wait for the current simulation.}}
    if {[context] ne [get $size_plan context]} {error {The schematic changed. Preview again.}}
    set owner [get $size_plan owner]
    set selection [xschem selected_set]
    if {[llength $selection] != 1 || [lindex $selection 0] ne $owner || [xschem getprop instance $owner] ne [get $size_plan before]} {error {Selection or geometry changed. Preview again.}}
    if {[raw_signature $::analog_lens::lut_file] ne [get $size_plan lookup] || $::analog_lens::lut_slice ne [get $size_plan slice] ||
        [list $::analog_lens::target_length $::analog_lens::target_gmid $::analog_lens::target_gm_u] ne [get $size_plan targets]} {error {Lookup data or targets changed. Preview again.}}
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
    set size_plan {}; xschem redraw
    if {[winfo exists $::analog_lens::window.sizepreview]} {destroy $::analog_lens::window.sizepreview}
    set ::analog_lens::status {Geometry applied. xschem Undo restores it; rerun to verify and compare.}
    update_freshness; project_flush
    if {$rerun} {run_op}
}
