# Dependency manifests are generated from the deck actually simulated.
namespace eval ::analog_lens {
    variable dependency_cache {}; variable dependency_message {Dependencies unverified}
    variable conditions_confidence {Operating conditions incomplete}
    variable helper_jobs {}; variable lookup_trust_cache {}; variable lookup_trust {}
}
proc ::analog_lens::helper_async {script arguments callback} {
    set python [auto_execok python3]
    if {$python eq {}} {error {Python 3 is required for provenance checks.}}
    set channel [open [list | {*}$python [file join $::analog_lens::root tools $script] {*}$arguments 2>@1] r]
    fconfigure $channel -blocking 0 -translation binary
    dict set ::analog_lens::helper_jobs $channel [dict create callback $callback output {}]
    fileevent $channel readable [list ::analog_lens::helper_readable $channel]
    return $channel
}
proc ::analog_lens::helper_readable {channel} {
    if {![dict exists $::analog_lens::helper_jobs $channel]} {return}
    set job [dict get $::analog_lens::helper_jobs $channel]
    dict append job output [read $channel]
    dict set ::analog_lens::helper_jobs $channel $job
    if {![eof $channel]} {return}
    fileevent $channel readable {}; fconfigure $channel -blocking 1
    set failed [catch {close $channel} why]
    dict unset ::analog_lens::helper_jobs $channel
    set data [string trim [encoding convertfrom utf-8 [get $job output]]]
    if {$failed || [catch {dict size $data}]} {set data [dict create state unverified reason {Provenance check failed.} warnings [list $why]]}
    {*}[get $job callback] $data
}
proc ::analog_lens::dependency_checked {path token result} {
    if {[get $::analog_lens::dependency_cache token] ne $token} {return}
    set ::analog_lens::dependency_cache [dict create path $path token $token time [clock milliseconds] result $result]
}
proc ::analog_lens::lookup_checked {path token result} {
    if {[get [get $::analog_lens::lookup_trust_cache $path] token] ne $token} {return}
    dict set ::analog_lens::lookup_trust_cache $path [dict create token $token time [clock milliseconds] result $result]
}
proc ::analog_lens::lookup_status {{force 0} {path {}}} {
    if {$path eq {}} {set path $::analog_lens::lut_file}
    if {$path eq {}} {return [dict create state unverified reason {No lookup file is available.}]}
    if {![file isfile $path]} {return [dict create state outdated reason {The loaded lookup file is missing.}]}
    set path [file normalize $path]
    set cached [get $::analog_lens::lookup_trust_cache $path]
    if {!$force && ([get $cached pending 0] || [clock milliseconds]-[get $cached time 0] < 2000)} {return [get $cached result]}
    set token [clock clicks]
    if {$force} {
        if {[catch {exec {*}[auto_execok python3] [file join $::analog_lens::root tools lookup_provenance.py] $path} result] || [catch {dict size $result}]} {
            set result [dict create state unverified reason {Could not validate lookup provenance.}]
        }
        dict set ::analog_lens::lookup_trust_cache $path [dict create token $token time [clock milliseconds] result $result]
    } else {
        set result [get $cached result [dict create state unverified reason {Checking lookup provenance…}]]
        dict set ::analog_lens::lookup_trust_cache $path [dict create token $token pending 1 result $result]
        if {[catch {helper_async lookup_provenance.py [list $path] [list ::analog_lens::lookup_checked $path $token]}]} {
            lookup_checked $path $token [dict create state unverified reason {Could not start lookup provenance check.}]
        }
    }
    return $result
}
proc ::analog_lens::require_lookup_current {} {
    set trust [lookup_status 1]
    if {[get $trust state] eq "outdated"} {error "Outdated lookup: [get $trust reason] Generate a new lookup before applying geometry."}
    if {$::analog_lens::lut_file ne {} && [file isfile $::analog_lens::lut_file] && [parse_lut [read_text $::analog_lens::lut_file]] ne $::analog_lens::lut_rows} {
        error {Lookup content changed since loading. Reload the lookup and preview again.}
    }
    return $trust
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
    if {!$force && [get $dependency_cache path] eq $path && ([get $dependency_cache pending 0] || $now-[get $dependency_cache time 0] < 2000)} {
        return [get $dependency_cache result]
    }
    set token [clock clicks]
    if {$force} {
        if {[catch {project_helper check $path --full} result]} {set result [dict create state unverified warnings [list $result]]}
        set dependency_cache [dict create path $path token $token time $now result $result]
    } else {
        set result [dict create state unverified]
        if {[get $dependency_cache path] eq $path} {set result [get $dependency_cache result $result]}
        set dependency_cache [dict create path $path token $token pending 1 result $result]
        if {[catch {helper_async project_data.py [list check $path] [list ::analog_lens::dependency_checked $path $token]}]} {
            dependency_checked $path $token [dict create state unverified]
        }
    }
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
    if {[dict size [get $metadata observed_conditions]]} {
        dict set metadata conditions_source {Observed deck values where available; remaining values are user-declared or unknown}
    }
    return [dict merge $metadata [get $metadata observed_conditions]]
}
