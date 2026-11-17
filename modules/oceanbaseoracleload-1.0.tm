# Used only by generated schema loaders. Benchmark prepared statements never
# share this batch state or change the native Oracle transaction boundaries.
if {[catch {package require oceanbaseoracledriver}]} {
    source [file join [file dirname [info script]] oceanbaseoracledriver-1.0.tm]
}
namespace eval oceanbaseoracleload {
    namespace path ::oceanbaseoracledriver
    variable cursors {}
    variable max_rows 1000
    variable max_bytes 1048576

    proc open {lda} {
        variable cursors
        set cursor [oraopen $lda]
        dict set cursors $cursor [dict create lda $lda sql {} rows {} bytes 0]
        return $cursor
    }

    proc parse {cursor sql} {
        variable cursors
        if {[dict get $cursors $cursor sql] eq $sql} {return}
        if {![regexp -nocase {^(INSERT\s+INTO\s+.+?\mVALUES\M\s*)\((.*)\)\s*$} $sql -> head expressions]} {
            error "OceanBase loader expected an INSERT with one VALUES tuple"
        }
        flush $cursor
        # Quoted SQL literals (including date masks) are never placeholders.
        set chunks {}
        set last 0
        foreach position [regexp -all -inline -indices {'(?:[^']|'')*'|:[A-Za-z_][A-Za-z0-9_]*} $expressions] {
            lassign $position first end
            set token [string range $expressions $first $end]
            if {[string index $token 0] ne {:}} {continue}
            lappend chunks [list text [string range $expressions $last [expr {$first-1}]]] [list bind [string toupper $token]]
            set last [expr {$end+1}]
        }
        lappend chunks [list text [string range $expressions $last end]]
        dict set cursors $cursor sql $sql
        dict set cursors $cursor head $head
        dict set cursors $cursor chunks $chunks
        dict set cursors $cursor bytes [string length [encoding convertto utf-8 $head]]
    }

    proc bind {cursor args} {
        variable cursors
        set array [expr {[lindex $args 0] eq {-arraydml}}]
        if {$array} {set args [lrange $args 1 end]}
        if {![llength $args] || [llength $args] % 2} {error "Invalid OceanBase loader bindings"}
        set values {}
        set count -1
        foreach {name value} $args {
            if {!$array} {set value [list $value]}
            set size [llength $value]
            if {$count < 0} {set count $size}
            if {$size != $count} {error "OceanBase loader array columns have different lengths"}
            dict set values [string toupper $name] $value
        }
        if {$count == 0} {error "OceanBase loader received an empty batch"}
        foreach chunk [dict get $cursors $cursor chunks] {
            lassign $chunk kind token
            if {$kind eq {bind} && ![dict exists $values $token]} {error "Missing OceanBase loader binding $token"}
        }
        dict set cursors $cursor values $values
        dict set cursors $cursor count $count
        dict set cursors $cursor array $array
    }

    proc exec {cursor} {
        variable cursors
        variable max_rows
        variable max_bytes
        set state [dict get $cursors $cursor]
        set head_bytes [string length [encoding convertto utf-8 [dict get $state head]]]
        for {set row 0} {$row < [dict get $state count]} {incr row} {
            set tuple {(}
            foreach chunk [dict get $state chunks] {
                lassign $chunk kind value
                if {$kind eq {bind}} {
                    set value [lindex [dict get $state values $value] $row]
                    if {[string first \x00 $value] >= 0} {error "NUL is not supported in OceanBase loader text values"}
                    set value "'[string map [list ' ''] $value]'"
                }
                append tuple $value
            }
            append tuple )
            set tuple_bytes [string length [encoding convertto utf-8 $tuple]]
            if {$head_bytes + $tuple_bytes > $max_bytes} {error "OceanBase loader row exceeds SQL batch size"}
            if {[dict get $cursors $cursor bytes] + $tuple_bytes + 1 > $max_bytes} {flush $cursor}
            dict with cursors $cursor {
                lappend rows $tuple
                incr bytes [expr {$tuple_bytes+1}]
            }
            if {[llength [dict get $cursors $cursor rows]] >= $max_rows} {flush $cursor}
        }
        # Array batches execute immediately; scalar loaders accumulate rows
        # until a batch is full or the native loader commits/closes its cursor.
        if {[dict get $state array]} {flush $cursor}
        return [dict get $state count]
    }

    proc flush {cursor} {
        variable cursors
        set rows [dict get $cursors $cursor rows]
        if {![llength $rows]} {return}
        set head [dict get $cursors $cursor head]
        orasql $cursor "$head[join $rows ,]"
        set affected [oramsg $cursor rows]
        if {$affected != [llength $rows]} {
            error "OceanBase loader inserted $affected rows; expected [llength $rows]"
        }
        dict set cursors $cursor rows {}
        dict set cursors $cursor bytes [string length [encoding convertto utf-8 $head]]
    }

    proc commit {lda} {
        variable cursors
        foreach cursor [dict keys $cursors] {
            if {[dict get $cursors $cursor lda] eq $lda} {flush $cursor}
        }
        return [oracommit $lda]
    }

    proc close {cursor} {
        variable cursors
        try {flush $cursor} finally {
            dict unset cursors $cursor
            oraclose $cursor
        }
    }
}
package provide oceanbaseoracleload 1.0
