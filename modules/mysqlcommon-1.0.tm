# Shared runtime support for MySQL protocol workloads.
# OceanBase uses the same workload SQL with tenant-local session settings and counters.
namespace eval mysqlcommon {
    variable database MySQL
    variable query_timeout 0

    proc configure {db timeout} {
        variable database
        variable query_timeout
        if {$db ni {MySQL OceanBase}} {error "Unsupported MySQL protocol database: $db"}
        if {![string is integer -strict $timeout] || $timeout < 0} {
            error "Query timeout must be a non-negative number of seconds"
        }
        set database $db
        set query_timeout $timeout
    }

    proc database {} {
        variable database
        return $database
    }

    proc configure_session {handle} {
        variable database
        variable query_timeout
        if {$database eq "OceanBase" && $query_timeout > 0} {
            mysql::exec $handle "SET SESSION ob_query_timeout = [expr {wide($query_timeout) * 1000000}]"
        }
    }

    proc run {args} {
        # Wake a schema monitor if a loader fails before reporting "done".
        try {
            return [uplevel 1 $args]
        } on error {message options} {
            tsv::set application abort 1
            return -options $options $message
        }
    }

    proc counter_sql {} {
        variable database
        if {$database eq "OceanBase"} {
            # A MySQL tenant sees its own server statistics. Aggregate across its OBServers.
            return {SELECT NAME, SUM(VALUE) FROM oceanbase.GV$SYSSTAT
                    WHERE NAME IN ('trans commit count', 'trans rollback count') GROUP BY NAME}
        }
        return {SHOW GLOBAL STATUS WHERE Variable_name IN ('Com_commit', 'Com_rollback')}
    }

    proc transaction_count {handle} {
        return [parse_transaction_count [mysql::sel $handle [counter_sql] -list]]
    }

    proc parse_transaction_count {rows} {
        variable database
        set counters [dict create]
        foreach row $rows {
            if {[llength $row] != 2} {error "Unexpected $database transaction counter row"}
            lassign $row name value
            if {![string is entier -strict $value] || $value < 0} {
                error "Invalid $database transaction counter: $name"
            }
            dict set counters [string tolower $name] $value
        }
        if {$database eq "OceanBase"} {
            set names {{trans commit count} {trans rollback count}}
        } else {
            set names {com_commit com_rollback}
        }
        set total 0
        foreach name $names {
            if {![dict exists $counters $name]} {error "$database transaction counter unavailable: $name"}
            incr total [dict get $counters $name]
        }
        return $total
    }
}
package provide mysqlcommon 1.0
