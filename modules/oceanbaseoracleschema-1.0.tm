# OceanBase physical layout for the native Oracle logical benchmark schemas.
namespace eval oceanbaseoracleschema {
    proc tablegroups {owner workload} {
        if {![regexp {^[A-Za-z][A-Za-z0-9_$#]*$} $owner]} {error "Invalid benchmark schema owner"}
        set name [string range [string toupper $owner] 0 40]
        regsub -all {[^A-Z0-9_]} $name _ name
        if {$workload eq "tpcc"} {return [list HDB_${name}_C_TG]}
        return [list HDB_${name}_H_ORDERS_TG HDB_${name}_H_PARTS_TG]
    }

    proc prepare {lda workload owner} {
        set cursor [oraopen $lda]
        try {
            set groups [tablegroups $owner $workload]
            foreach group $groups {
                set existing [::oceanbaseoraclecommon::rows $cursor "SELECT TABLEGROUP_NAME FROM SYS.DBA_OB_TABLEGROUPS WHERE UPPER(TABLEGROUP_NAME)='$group'"]
                if {![llength $existing]} {orasql $cursor "CREATE TABLEGROUP $group SHARDING = 'PARTITION'"}
            }
            return $groups
        } finally {oraclose $cursor}
    }

    proc table_ddl {sql workload partitions groups} {
        if {![regexp -nocase {^CREATE TABLE ([A-Z_]+)\s*\(} $sql -> table]} {return $sql}
        set table [string toupper $table]
        if {$workload eq "tpcc"} {
            set primary {CUSTOMER {C_W_ID,C_D_ID,C_ID} DISTRICT {D_W_ID,D_ID} ITEM I_ID
                WAREHOUSE W_ID STOCK {S_W_ID,S_I_ID} ORDERS {O_W_ID,O_D_ID,O_ID}}
            set keys {CUSTOMER C_W_ID DISTRICT D_W_ID HISTORY H_W_ID WAREHOUSE W_ID
                STOCK S_W_ID NEW_ORDER NO_W_ID ORDERS O_W_ID ORDER_LINE OL_W_ID}
        } else {
            set primary {ORDERS O_ORDERKEY LINEITEM {L_ORDERKEY,L_LINENUMBER} PARTSUPP {PS_PARTKEY,PS_SUPPKEY}
                CUSTOMER C_CUSTKEY PART P_PARTKEY SUPPLIER S_SUPPKEY NATION N_NATIONKEY REGION R_REGIONKEY}
            set keys {ORDERS O_ORDERKEY LINEITEM L_ORDERKEY PART P_PARTKEY PARTSUPP PS_PARTKEY
                CUSTOMER C_CUSTKEY SUPPLIER S_SUPPKEY}
        }
        if {[dict exists $primary $table]} {
            set end [string last ) $sql]
            if {$end < 0} {error "Missing closing parenthesis in $table DDL"}
            set sql [string replace $sql $end $end ", CONSTRAINT HDB_${table}_PK PRIMARY KEY ([dict get $primary $table]))"]
        }
        if {$workload eq "tpcc" && $table eq "ITEM"} {
            append sql " DUPLICATE_SCOPE = 'CLUSTER'"
        } elseif {[dict exists $keys $table]} {
            if {$workload eq "tpcc" || $table in {ORDERS LINEITEM PART PARTSUPP}} {
                set group [lindex $groups [expr {$workload eq "tpch" && $table in {PART PARTSUPP} ? 1 : 0}]]
                append sql " TABLEGROUP = $group"
            }
            append sql " PARTITION BY HASH ([dict get $keys $table]) PARTITIONS $partitions"
        }
        if {$workload eq "tpch"} {append sql " WITH COLUMN GROUP(each column)"}
        return $sql
    }

    proc index_ddl {sql workload} {
        if {$workload eq "tpcc"} {
            if {[regexp -nocase {^CREATE UNIQUE INDEX (CUSTOMER|DISTRICT|ITEM|ORDERS|STOCK|WAREHOUSE)_I1\s} $sql]} {
                return {BEGIN NULL; END;}
            }
            if {[regexp -nocase {^CREATE (UNIQUE )?INDEX [A-Z_0-9]+ ON (CUSTOMER|ORDERS)\s*\(} $sql]} {
                append sql " LOCAL"
            }
        } elseif {[regexp -nocase {^ALTER TABLE [A-Z_]+ ADD CONSTRAINT [A-Z_]+ PRIMARY KEY} $sql]} {
            # Distributed tables get their storage primary key before loading.
            return {BEGIN NULL; END;}
        }
        return $sql
    }
}
package provide oceanbaseoracleschema 1.0
