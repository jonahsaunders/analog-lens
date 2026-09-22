# Dependency manifests are generated from the deck actually simulated.
namespace eval ::analog_lens {
    variable dependency_cache {}; variable dependency_message {Dependencies unverified}
    variable conditions_confidence {Operating conditions incomplete}
}
proc ::analog_lens::project_helper {args} {
    set python [auto_execok python3]
    if {$python eq {}} {error {Python 3 is required for project analysis in IIC-OSIC-TOOLS.}}
    return [exec {*}$python [file join $::analog_lens::root tools project_data.py] {*}$args]
}
proc ::analog_lens::dependency_snapshot {deck} {
    set output "[file rootname $deck]-[clock clicks].dependencies.json"
    set data [project_helper snapshot $deck --output $output]
    dict size $data
    return $data
}
proc ::analog_lens::dependency_status {{force 0}} {
    variable dependency_cache
    set path [get $::analog_lens::result_metadata dependencies]
    if {$path eq {} || ![file isfile $path]} {return [dict create state unverified]}
    set now [clock milliseconds]
    if {!$force && [get $dependency_cache path] eq $path && $now-[get $dependency_cache time 0] < 2000} {
        return [get $dependency_cache result]
    }
    set options {}; if {$force} {set options --full}
    if {[catch {project_helper check $path {*}$options} result]} {set result [dict create state unverified warnings [list $result]]}
    set dependency_cache [dict create path $path time $now result $result]
    return $result
}
proc ::analog_lens::condition_confidence {{device {}}} {
    set observed [get $::analog_lens::result_metadata observed_conditions]
    set missing {}
    foreach key {corner temp_c} {if {[get $observed $key] eq {}} {lappend missing [condition_label $key]}}
    foreach key {terminal_vds terminal_vbs} label {Vds Vsb} {
        if {[get [get $device values] $key] eq {}} {lappend missing $label}
    }
    if {[llength $missing]} {return "Partially verified · Unknown or declared only: [join $missing {, }]"}
    return {Verified conditions · Deck corner and temperature; measured terminal biases.}
}
proc ::analog_lens::recorded_conditions {metadata} {
    # Observed deck values override conflicting user declarations. Unknown
    # values remain explicitly declared, never silently promoted to verified.
    return [dict merge $metadata [get $metadata observed_conditions]]
}
