# Headless widget-command contract harness. This does NOT render or validate Tk.
namespace eval ::mocktk {variable widgets [dict create . root]; variable rows {}; variable selections {}; variable next 0}
namespace eval ::ttk {}
proc ::mocktk::make {kind path args} {
    dict set ::mocktk::widgets $path $kind
    interp alias {} $path {} ::mocktk::dispatch $kind $path
    return $path
}
foreach kind {frame label button entry checkbutton combobox spinbox panedwindow notebook treeview scrollbar labelframe menubutton progressbar separator} {
    interp alias {} ::ttk::$kind {} ::mocktk::make $kind
}
foreach kind {toplevel text canvas menu} {interp alias {} ::$kind {} ::mocktk::make $kind}
proc ::mocktk::dispatch {kind path command args} {
    if {$kind ne "treeview"} {return {}}
    if {![dict exists $::mocktk::rows $path]} {dict set ::mocktk::rows $path {}}
    if {![dict exists $::mocktk::selections $path]} {dict set ::mocktk::selections $path {}}
    switch -- $command {
        children {return [dict keys [dict get $::mocktk::rows $path]]}
        insert {
            set opts [lrange $args 2 end];set at [lsearch -exact $opts -id]
            set id [expr {$at < 0 ? "item[incr ::mocktk::next]" : [lindex $opts [expr {$at+1}]]}]
            dict set ::mocktk::rows $path $id $opts;return $id
        }
        delete {
            foreach id [lindex $args 0] {dict unset ::mocktk::rows $path $id}
            dict set ::mocktk::selections $path {}
        }
        selection {
            if {[lindex $args 0] eq "set"} {dict set ::mocktk::selections $path [lindex $args 1]}
            return [dict get $::mocktk::selections $path]
        }
        exists {return [dict exists $::mocktk::rows $path [lindex $args 0]]}
    }
    return {}
}
proc winfo {command path args} {
    switch -- $command {
        exists {return [dict exists $::mocktk::widgets $path]}
        width {return 900}
        height {return 350}
        reqwidth {return 100}
        rgb {return {65535 65535 65535}}
    }
}
proc destroy {path} {
    foreach name [dict keys $::mocktk::widgets] {
        if {$name eq $path || [string first "$path." $name] == 0} {dict unset ::mocktk::widgets $name;catch {rename $name {}}}
    }
}
foreach cmd {pack grid place bind wm focus raise update} {proc ::$cmd {args} {return {}}}
proc ::ttk::style {args} {return {}}
namespace eval ::ttk::notebook {}
proc ::ttk::notebook::enableTraversal {args} {}
proc tk {command args} {return x11}
proc font {command args} {
    switch -- $command {
        names {return {}}
        actual {
            if {[lindex $args 1] eq "-size"} {return 10}
            return {-family Sans -size 10 -weight normal}
        }
        metrics {return 14}
        measure {return 60}
    }
    return {}
}
proc exit {args} {set ::mocktk::exit_requested $args}
