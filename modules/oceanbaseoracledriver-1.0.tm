# Oracle generator compatibility at the database API boundary. These commands
# are namespaced: loading OB must never replace native Oracle's Oratcl commands.
namespace eval oceanbaseoracledriver {
    variable cursors {}

    proc bind_sql {sql} {
        set converted {}
        set names {}
        set length [string length $sql]
        for {set i 0} {$i < $length} {incr i} {
            set char [string index $sql $i]
            set next [string index $sql [expr {$i+1}]]
            set end $i
            if {$char in {q Q} && $next eq "'"} {
                set delimiter [string index $sql [expr {$i+2}]]
                set pairs [dict create \[ \] \{ \} ( ) < >]
                if {[dict exists $pairs $delimiter]} {set delimiter [dict get $pairs $delimiter]}
                set end [string first "$delimiter'" $sql [expr {$i+3}]]
                if {$end < 0} {error "Unterminated Oracle quoted literal"}
                incr end
            } elseif {$char eq "'" || $char eq {"}} {
                set end [expr {$i+1}]
                while {1} {
                    set end [string first $char $sql $end]
                    if {$end < 0} {error "Unterminated SQL quote"}
                    if {[string index $sql [expr {$end+1}]] ne $char} {break}
                    incr end 2
                }
            } elseif {$char eq "-" && $next eq "-"} {
                set end [string first \n $sql $i]
                if {$end < 0} {set end [expr {$length-1}]}
            } elseif {$char eq "/" && $next eq "*"} {
                set end [string first */ $sql [expr {$i+2}]]
                if {$end < 0} {error "Unterminated SQL comment"}
                incr end
            } elseif {$char eq ":" && [regexp {^[A-Za-z_][A-Za-z0-9_$#]*} [string range $sql [expr {$i+1}] end] name]} {
                lappend names :[string toupper $name]
                append converted ?
                incr i [string length $name]
                continue
            }
            append converted [string range $sql $i $end]
            set i $end
        }
        return [list $converted $names]
    }

    proc oraopen {connection} {
        variable cursors
        set cursor [$connection open]
        dict set cursors $cursor [dict create connection $connection sql {} names {} values {}]
        return $cursor
    }
    proc oraparse {cursor sql} {
        variable cursors
        if {[dict get $cursors $cursor sql] eq $sql} {return}
        lassign [bind_sql $sql] converted names
        set count [$cursor prepare $converted]
        if {$count != [llength $names]} {error "Oracle placeholder count does not match libobclient metadata"}
        dict set cursors $cursor sql $sql
        dict set cursors $cursor names $names
        dict set cursors $cursor values {}
        dict unset cursors $cursor text_call
        dict unset cursors $cursor client_transaction
        dict unset cursors $cursor client_output
    }
    proc parse_client_transaction {cursor sql} {
        variable cursors
        if {![regexp -nocase {^CALL (neword|payment|ostat|delivery|slev)\(} $sql -> procedure]} {
            error "Expected a TPROC-C transaction"
        }
        lassign [bind_sql $sql] converted names
        dict set cursors $cursor sql {}
        dict set cursors $cursor names $names
        dict set cursors $cursor values {}
        dict set cursors $cursor client_transaction [string tolower $procedure]
        dict unset cursors $cursor text_call
        dict unset cursors $cursor client_output
    }
    proc parse_text_call {cursor sql} {
        variable cursors
        if {![regexp -nocase {^CALL (neword|payment|ostat|delivery|slev)\(} $sql -> procedure]} {
            error "Expected a TPROC-C text CALL"
        }
        lassign [bind_sql $sql] converted names
        set parts [split $converted ?]
        if {[llength $parts] != [llength $names]+1} {error "Unexpected marker in TPROC-C text CALL"}
        # Argument order matches the benchmark procedure signatures. DELIVERY
        # has no OUT parameters. The other calls return one row of OUT values.
        switch [string tolower $procedure] {
            neword {
                set outputs [lrange $names 5 10]
                set inout {}
            }
            payment {
                set outputs [list :P_C_ID {*}[lrange $names 7 31]]
                set inout {:P_C_ID :P_C_LAST :P_C_CREDIT :P_C_BALANCE}
            }
            ostat {
                set outputs [list :OS_C_ID {*}[lrange $names 4 10]]
                set inout {:OS_C_ID :OS_C_LAST}
            }
            slev {
                set outputs {:STOCKLEVEL}
                set inout {}
            }
            delivery {
                set outputs {}
                set inout {}
            }
        }
        dict set cursors $cursor sql {}
        dict set cursors $cursor names $names
        dict set cursors $cursor values {}
        dict set cursors $cursor text_call [list $parts $outputs $inout]
        dict unset cursors $cursor client_transaction
        dict unset cursors $cursor client_output
    }
    proc text_call_literal {name value} {
        if {$value eq {}} {return NULL}
        if {$name in {:TIMESTAMP :P_C_LAST :P_C_CREDIT :OS_C_LAST}} {
            if {[string first \x00 $value] >= 0} {error "NUL in TPROC-C text CALL parameter $name"}
            return "'[string map [list ' ''] $value]'"
        }
        if {![regexp {^[0-9]+$} $value]} {error "Expected numeric TPROC-C text CALL parameter $name"}
        return $value
    }
    proc orabind {cursor args} {
        variable cursors
        if {![llength $args] || [llength $args] % 2} {error "Expected Oracle bind name/value pairs"}
        set values {}
        foreach {name value} $args {dict set values [string toupper $name] $value}
        set ordered {}
        foreach name [dict get $cursors $cursor names] {
            if {![dict exists $values $name]} {error "Missing Oracle binding $name"}
            lappend ordered [dict get $values $name]
        }
        dict set cursors $cursor values $ordered
    }
    proc oraexec {cursor} {
        variable cursors
        if {[dict exists $cursors $cursor client_transaction]} {
            dict unset cursors $cursor client_output
            set names [dict get $cursors $cursor names]
            set values [dict get $cursors $cursor values]
            if {[llength $values] != [llength $names]} {error "Missing TPROC-C transaction bindings"}
            set bindings {}
            foreach name $names value $values {dict set bindings $name $value}
            set procedure [dict get $cursors $cursor client_transaction]
            set output [::oceanbaseoracletpcc::execute $cursor $procedure $bindings]
            if {[llength $output]} {dict set cursors $cursor client_output $output}
            return
        }
        if {[dict exists $cursors $cursor text_call]} {
            lassign [dict get $cursors $cursor text_call] parts outputs inout
            set names [dict get $cursors $cursor names]
            set values [dict get $cursors $cursor values]
            if {[llength $values] != [llength $names]} {error "Missing TPROC-C text CALL bindings"}
            set sql [lindex $parts 0]
            set assignments {}
            foreach name $names value $values suffix [lrange $parts 1 end] {
                if {$name in $outputs} {
                    set argument @hdb_[string tolower [string range $name 1 end]]
                    if {$name in $inout} {lappend assignments "$argument = [text_call_literal $name $value]"}
                } else {
                    set argument [text_call_literal $name $value]
                }
                append sql $argument $suffix
            }
            if {[llength $assignments]} {$cursor query "SET [join $assignments {, }]"}
            set rows [$cursor call $sql]
            if {[llength $outputs] && $rows != 1} {error "TPROC-C text CALL did not return its OUT row"}
            return $rows
        }
        return [$cursor execute [dict get $cursors $cursor values]]
    }
    proc orasql {cursor sql} {return [$cursor query $sql]}
    proc oraplexec {cursor sql} {oraparse $cursor $sql; return [oraexec $cursor]}
    proc orafetch {cursor args} {
        variable cursors
        if {[llength $args] != 2 || [lindex $args 0] ne "-datavariable"} {error "Expected -datavariable name"}
        upvar 1 [lindex $args 1] output
        if {[dict exists $cursors $cursor client_transaction]} {
            set output {}
            if {![dict exists $cursors $cursor client_output]} {return 1403}
            set output [dict get $cursors $cursor client_output]
            dict unset cursors $cursor client_output
            return 0
        }
        lassign [$cursor fetch] found output
        return [expr {$found ? 0 : 1403}]
    }
    proc oramsg {cursor {field rc}} {
        set status [$cursor status]
        if {$field eq "all"} {return [dict get $status message]}
        if {$field ni {rc rows}} {error "Unknown Oracle cursor status field: $field"}
        return [dict get $status $field]
    }
    proc oraclose {cursor} {
        variable cursors
        try {$cursor close} finally {dict unset cursors $cursor}
    }
    proc oralogoff {connection} {
        variable cursors
        foreach cursor [dict keys $cursors] {
            if {[dict get $cursors $cursor connection] eq $connection} {dict unset cursors $cursor}
        }
        $connection close
    }
    proc oraautocom {connection enabled} {$connection autocommit $enabled}
    proc oracommit {connection} {$connection commit}
    proc oraroll {connection} {$connection rollback}
}
package provide oceanbaseoracledriver 1.0
