# Pure schema/pool contracts: no connections or workers are started.
set argv {}
package require tcltest 2
namespace import ::tcltest::*
package require oceanbaseoracleschema
package require oceanbaseoraclecommon
package require tpcccommon
set settings {/test/libobci.so host 2881 tenant cluster {} {sys tpcc tpch}}
set pool [::tpcccommon::get_connect_xml obora]

test oracle-bootstrap-alias {Administrator logins do not select a not-yet-created benchmark schema; pools keep their route} -setup {
    rename ::oceanbaseoraclecommon::connect ::oceanbaseoraclecommon::test_real_connect
    proc ::oceanbaseoraclecommon::connect {args} {return $args}
} -body {
    list [oceanbaseoraclecommon::logon sys/password@hdb_ob_new_schema] \
        [oceanbaseoraclecommon::logon tpcc/password@hdb_ob_pool_c1]
} -cleanup {
    rename ::oceanbaseoraclecommon::connect {}
    rename ::oceanbaseoraclecommon::test_real_connect ::oceanbaseoraclecommon::connect
} -result {{sys password {}} {tpcc password hdb_ob_pool_c1}}

test oracle-pool-inherit {Oracle pool inherits the active profile without reading MySQL pool credentials} -body {
    lassign [oceanbaseoraclecommon::pool_config $pool $settings tpcc {a;[literal]$x}] mapped endpoints
    list [dict get $mapped connections c1 tpcc_user] [dict get $mapped connections c2 tpcc_pass] \
        [dict get $mapped connections c1 instance] [llength $endpoints] [dict get [lindex $endpoints 0] tenant]
} -result {tpcc {a;[literal]$x} hdb_ob_pool_c1 2 tenant}
foreach key {ob_tenant ob_cluster tpcc_user} {
    test oracle-pool-isolation-$key {Pool connections cannot silently route a transaction to a different dataset} -body {
        set changed $pool
        dict set changed connections c2 $key other
        oceanbaseoraclecommon::pool_config $changed $settings tpcc password
    } -returnCodes error -match glob -result {*same tenant, cluster and benchmark user}
}
test oracle-pool-unknown-route {Pool routes refer to configured connections} -body {
    set changed $pool
    dict set changed sprocs neworder connections c9
    oceanbaseoraclecommon::pool_config $changed $settings tpcc password
} -returnCodes error -match glob -result {*Unknown*connection c9}
test oracle-pool-policy {Unsupported route policies fail instead of falling back silently} -body {
    set changed $pool
    dict set changed sprocs payment policy invalid
    oceanbaseoraclecommon::pool_config $changed $settings tpcc password
} -returnCodes error -match glob -result {*Unknown*policy}

test oracle-c-distribution {All warehouse tables partition by their warehouse key in the same tablegroup} -body {
    set result {}
    foreach {table key} {CUSTOMER C_W_ID DISTRICT D_W_ID HISTORY H_W_ID WAREHOUSE W_ID STOCK S_W_ID NEW_ORDER NO_W_ID ORDERS O_W_ID ORDER_LINE OL_W_ID} {
        set sql [oceanbaseoracleschema::table_ddl "CREATE TABLE $table (ID NUMBER)" tpcc 4 {HDB_TPCC_C_TG}]
        lappend result [expr {[string first "TABLEGROUP = HDB_TPCC_C_TG PARTITION BY HASH ($key) PARTITIONS 4" $sql] >= 0}]
    }
    lsort -unique $result
} -result 1

test oracle-c-item {ITEM is a duplicate table with its native logical primary key} -body {
    set sql [oceanbaseoracleschema::table_ddl {CREATE TABLE ITEM (I_ID NUMBER)} tpcc 4 {HDB_TPCC_C_TG}]
    list [string match {*PRIMARY KEY (I_ID)*DUPLICATE_SCOPE = 'CLUSTER'} $sql] [string match {*PARTITION BY*} $sql]
} -result {1 0}

test oracle-c-indexes {Storage primary keys replace redundant indexes and secondary indexes become local} -body {
    list [oceanbaseoracleschema::index_ddl {CREATE UNIQUE INDEX STOCK_I1 ON STOCK (S_I_ID,S_W_ID)} tpcc] \
        [oceanbaseoracleschema::index_ddl {CREATE UNIQUE INDEX CUSTOMER_I2 ON CUSTOMER (C_LAST,C_W_ID,C_D_ID,C_FIRST,C_ID)} tpcc]
} -result {{BEGIN NULL; END;} {CREATE UNIQUE INDEX CUSTOMER_I2 ON CUSTOMER (C_LAST,C_W_ID,C_D_ID,C_FIRST,C_ID) LOCAL}}

test oracle-h-distribution {Orders and parts families use separate colocated tablegroups} -body {
    set result {}
    foreach {table key group} {ORDERS O_ORDERKEY ORDERS_TG LINEITEM L_ORDERKEY ORDERS_TG PART P_PARTKEY PARTS_TG PARTSUPP PS_PARTKEY PARTS_TG} {
        set sql [oceanbaseoracleschema::table_ddl "CREATE TABLE $table (ID NUMBER)" tpch 4 {ORDERS_TG PARTS_TG}]
        lappend result [expr {[string first "TABLEGROUP = $group PARTITION BY HASH ($key) PARTITIONS 4" $sql] >= 0}] \
            [string match {*WITH COLUMN GROUP(each column)} $sql] [expr {![string match {*ROW_FORMAT*} $sql]}]
    }
    lsort -unique $result
} -result 1

test oracle-h-primary-before-load {H primary keys are created with the tables, preserving foreign-key definitions} -body {
    list [oceanbaseoracleschema::index_ddl {ALTER TABLE ORDERS ADD CONSTRAINT ORDERS_PK PRIMARY KEY (O_ORDERKEY)} tpch] \
        [oceanbaseoracleschema::index_ddl {ALTER TABLE LINEITEM ADD CONSTRAINT LINEITEM_ORDER_FK FOREIGN KEY (L_ORDERKEY) REFERENCES ORDERS (O_ORDERKEY)} tpch]
} -result {{BEGIN NULL; END;} {ALTER TABLE LINEITEM ADD CONSTRAINT LINEITEM_ORDER_FK FOREIGN KEY (L_ORDERKEY) REFERENCES ORDERS (O_ORDERKEY)}}
set failed $::tcltest::numTests(Failed)
cleanupTests
exit [expr {$failed > 0}]
