# OceanBase MySQL tenant session settings and transaction counters.
namespace eval oceanbasecommon {
    variable query_timeout 0

    proc configure {timeout} {
        variable query_timeout
        if {![string is integer -strict $timeout] || $timeout < 0} {
            error "Query timeout must be a non-negative number of seconds"
        }
        set query_timeout $timeout
    }

    proc configure_session {handle} {
        variable query_timeout
        if {$query_timeout > 0} {
            mysql::exec $handle "SET SESSION ob_query_timeout = [expr {wide($query_timeout) * 1000000}]"
        }
    }

    proc counter_sql {} {
        # A MySQL tenant sees its own server statistics. Aggregate across its OBServers.
        return {SELECT NAME, SUM(VALUE) FROM oceanbase.GV$SYSSTAT
                WHERE NAME IN ('trans commit count', 'trans rollback count') GROUP BY NAME}
    }

    proc transaction_count {handle} {
        return [parse_transaction_count [mysql::sel $handle [counter_sql] -list]]
    }

    proc parse_transaction_count {rows} {
        set counters [dict create]
        foreach row $rows {
            if {[llength $row] != 2} {error "Unexpected OceanBase transaction counter row"}
            lassign $row name value
            if {![string is entier -strict $value] || $value < 0} {
                error "Invalid OceanBase transaction counter: $name"
            }
            dict set counters [string tolower $name] $value
        }
        set names {{trans commit count} {trans rollback count}}
        set total 0
        foreach name $names {
            if {![dict exists $counters $name]} {error "OceanBase transaction counter unavailable: $name"}
            incr total [dict get $counters $name]
        }
        return $total
    }
}
package provide oceanbasecommon 1.0
