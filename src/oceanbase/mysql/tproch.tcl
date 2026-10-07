# Add OceanBase distribution/storage options to HammerDB's MySQL TPROC-H DDL.
# Keep the original columns, types, lengths, keys and constraints in one place.
namespace eval oceanbase::mysql {
    variable optimized_tproch_procedure {
proc OceanBaseHTablegroups {database} {
    set name [string tolower $database]
    regsub -all {[^a-z0-9_]} $name _ name
    set name [string range $name 0 43]
    return [list "hdb_${name}_h_orders_tg" "hdb_${name}_h_parts_tg"]
}

proc OceanBaseHTableDDL {sql database partition_count} {
    if {![regexp -nocase {^CREATE TABLE `?([a-z_]+)`?} $sql -> table]} {
        error "Cannot identify the TPROC-H table for OceanBase distribution"
    }
    set table [string toupper $table]
    lassign [OceanBaseHTablegroups $database] orders_group parts_group
    set keys [dict create ORDERS O_ORDERKEY LINEITEM L_ORDERKEY \
        PART P_PARTKEY PARTSUPP PS_PARTKEY CUSTOMER C_CUSTKEY SUPPLIER S_SUPPKEY]
    append sql "\nROW_FORMAT = CONDENSED"
    if {$table in {ORDERS LINEITEM}} {
        append sql "\nTABLEGROUP = $orders_group"
    } elseif {$table in {PART PARTSUPP}} {
        append sql "\nTABLEGROUP = $parts_group"
    }
    if {[dict exists $keys $table]} {
        append sql "\nPARTITION BY KEY (`[dict get $keys $table]`) PARTITIONS $partition_count"
    } elseif {$table ni {NATION REGION}} {
        error "Unsupported TPROC-H table: $table"
    }
    append sql "\nWITH COLUMN GROUP(each column)"
    return $sql
}
    }

    proc rewrite_optimized_tproch {script partition_count} {
        variable optimized_tproch_procedure
        if {![string is integer -strict $partition_count] || $partition_count < 1 || $partition_count > 8192} {
            error "OceanBase TPROC-H partition count must be an integer from 1 to 8192"
        }
        set original {CreateTables $mysql_handler $mysql_tpch_storage_engine}
        set start [string first {proc CreateTables } $script]
        if {[string first $original $script] < 0 || $start < 0} {
            error "Cannot locate TPROC-H table creation in the generated script"
        }
        # Read only the complete original procedure, without evaluating the driver.
        set definition {}
        set end $start
        while {$end < [string length $script]} {
            set end [string first "\n" $script $end]
            if {$end < 0} {set end [string length $script]}
            set candidate [string range $script $start [expr {$end - 1}]]
            if {[info complete $candidate]} {
                set definition $candidate
                break
            }
            incr end
        }
        if {$definition eq "" || [llength $definition] != 4 ||
            [lindex $definition 0] ne "proc" || [lindex $definition 1] ne "CreateTables" ||
            [lrange [lindex $definition 2] 0 end] ne {mysql_handler mysql_tpch_storage_engine}} {
            error "Cannot read the original MySQL TPROC-H table builder"
        }
        set body [lindex $definition 3]
        set execute {mysqlexec $mysql_handler $sql($i)}
        if {[string first $execute $body] < 0} {
            error "Cannot locate the original MySQL TPROC-H DDL execution"
        }
        set body [string map [list $execute \
            {mysqlexec $mysql_handler [OceanBaseHTableDDL $sql($i) $database $partition_count]}] $body]
        set preamble {
    foreach group [OceanBaseHTablegroups $database] {
        mysqlexec $mysql_handler "CREATE TABLEGROUP IF NOT EXISTS $group SHARDING = 'PARTITION'"
    }
}
        set adapted [list proc CreateOceanBaseHTables \
            {mysql_handler mysql_tpch_storage_engine database partition_count} "$preamble$body"]
        set replacement "CreateOceanBaseHTables \$mysql_handler \$mysql_tpch_storage_engine \$db $partition_count"
        set script [string map [list $original $replacement] $script]
        set marker {proc CreateTables }
        return [string map [list $marker "$optimized_tproch_procedure\n$adapted\n$marker"] $script]
    }
}
