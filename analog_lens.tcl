# Analog Lens -- native xschem Tcl/Tk extension. SPDX-License-Identifier: MIT
# Source this file from xschemrc (after the PDK configuration), or the console.
if {[info exists ::analog_lens::loaded]} {return}
namespace eval ::analog_lens {
    variable version 0.1.0
    variable root [file dirname [file normalize [info script]]]
}
foreach module {core adapters lut xschem gui} {
    source [file join $::analog_lens::root lib ${module}.tcl]
}
if {[llength [info commands xschem]]} {
    if {[llength [info commands winfo]] && [winfo exists .menubar]} {
        ::analog_lens::install_menu
    } elseif {![info exists ::analog_lens::postinit_added]} {
        append ::postinit_commands "\n::analog_lens::install_menu\n"
        set ::analog_lens::postinit_added 1
    }
}
package provide analog_lens $::analog_lens::version
set ::analog_lens::loaded 1
