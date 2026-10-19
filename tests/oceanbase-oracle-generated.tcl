# Run in the built CLI. Generate scripts only; do not connect or start workers.
set argv {}
package require tcltest 2
namespace import ::tcltest::*
set original_ob $configoceanbase
set original_ora $configoracle
set original_mysql $configmysql
rename load_virtual oracle_test_original_load_virtual
proc load_virtual {} {}
set configoceanbase [oceanbaseconfig::normalize $configoceanbase]
dict set configoceanbase connection ob_compatibility_mode oracle
set baseline $configoceanbase
try {
    foreach {workload actions} {tpcc {build test timed check delete} tpch {build test check delete}} {
        foreach action $actions {
            test oracle-generated-$workload-$action {Oracle scripts use OBCI with complete Tcl and native-category isolation} -body {
                oceanbase::dispatch generate $workload $action
                list [info complete $::_ED(package)] \
                    [expr {[string first {package require oceanbaseoraclecommon} $::_ED(package)] >= 0}] \
                    [expr {[string first {dbms_workload_repository} $::_ED(package)] < 0}] \
                    [expr {$configoracle eq $original_ora}] [expr {$configmysql eq $original_mysql}]
            } -result {1 1 1 1 1}
        }
    }
    foreach {driver async} {test false timed false timed true} {
        test oracle-pool-$driver-$async {Pool generators preserve tenant routing, monitoring and native-category isolation} -body {
            dict set configoceanbase connection ob_oracle_options [dict create tpcc [dict create ora_driver $driver async_scale $async connect_pool true]]
            oceanbase::dispatch generate tpcc $driver
            list [info complete $::_ED(package)] \
                [expr {[string first {::oceanbaseoraclecommon::configure_pool} $::_ED(package)] >= 0}] \
                [expr {[string first {::oceanbaseoraclecommon::get_pool_config} $::_ED(package)] >= 0}] \
                [expr {[string first {get_connect_xml ora} $::_ED(package)] < 0}] \
                [expr {[string first {dbms_workload_repository} $::_ED(package)] < 0}] \
                [expr {$configoracle eq $original_ora}]
        } -cleanup {set configoceanbase $baseline} -result {1 1 1 1 1 1}
    }
    foreach workload {tpcc tpch} {
        test oracle-distributed-$workload {OB physical layout is opt-in and stays independent of native Oracle partition flags} -body {
            dict set configoceanbase connection ob_oracle_options [dict create $workload {distributed_schema true partition_count 4}]
            oceanbase::dispatch generate $workload build
            list [info complete $::_ED(package)] \
                [expr {[string first {package require oceanbaseoracleschema} $::_ED(package)] >= 0}] \
                [expr {[string first {::oceanbaseoracleschema::table_ddl $sql($i)} $::_ED(package)] >= 0}] \
                [expr {[string first {::oceanbaseoracleschema::index_ddl $sql($i)} $::_ED(package)] >= 0}] \
                [expr {$configoracle eq $original_ora}]
        } -cleanup {set configoceanbase $baseline} -result {1 1 1 1 1}
    }
    test oracle-async-pool-verbose {The standalone async pool login reports its own handle, not a per-route handle} -body {
        dict set configoceanbase connection ob_oracle_options {tpcc {ora_driver timed connect_pool true async_scale true async_verbose true}}
        oceanbase::dispatch generate tpcc timed
        set login [string first {set mlda [ OracleLogon $connect mlda $timesten ]} $::_ED(package)]
        set verbose [string first {puts "Connected $clientname:$mlda"} $::_ED(package) $login]
        set pool [string first {set cpool [::oceanbaseoraclecommon::get_pool_config]} $::_ED(package) $login]
        list [expr {$login >= 0 && $login < $verbose && $verbose < $pool}] \
            [expr {[string first {puts "Connected $clientname:$lda"} [oceanbase::oracle::procedure_definition $::_ED(package) AsyncClientLogon]] >= 0}]
    } -cleanup {set configoceanbase $baseline} -result {1 1}
    foreach pool {false true} {
        test oracle-timed-profile-$pool {Time profiling attaches after the OB monitor with VU counts initialized} -body {
            dict set configoceanbase connection ob_oracle_options [dict create tpcc [dict create ora_driver timed connect_pool $pool ora_timeprofile true allwarehouse true]]
            dbset db ob
            dbset bm TPROC-C
            loadscript
            set position [string first {set rema [ lassign [ findvuposition ] myposition totalvirtualusers ]} $::_ED(package)]
            set monitor [string first {::oceanbaseoraclecommon::monitor $connect} $::_ED(package)]
            set profile [string first {xttimeproflog $totalvirtualusers $library} $::_ED(package)]
            list [info complete $::_ED(package)] [expr {$position >= 0 && $position < $monitor && $monitor < $profile}]
        } -cleanup {set configoceanbase $baseline} -result {1 1}
    }
    test oracle-pool-counter-setup {The counter and pooled drivers register the same descriptors before loading OBCI} -body {
        dict set configoceanbase connection ob_oracle_options {tpcc {connect_pool true}}
        set setup [oceanbase::oracle::connection_setup $configoceanbase true]
        oceanbase::dispatch generate tpcc timed
        expr {[string first $setup $::_ED(package)] >= 0 && [string first {configure_pool} $setup] >= 0}
    } -cleanup {set configoceanbase $baseline} -result 1
    test oracle-distributed-h-covering-index {The real H index builder executes the covering index before closing its cursor} -body {
        dict set configoceanbase connection ob_oracle_options {tpch {distributed_schema true partition_count 4}}
        oceanbase::dispatch generate tpch build
        set definition [oceanbase::oracle::procedure_definition $::_ED(package) CreateIndexes]
        set start [string first {CREATE INDEX HDB_LINEITEM_SHIPDATE_COVER_IDX} $definition]
        list [expr {$start >= 0}] [expr {$start < [string last {oraclose $curn1} $definition]}]
    } -cleanup {set configoceanbase $baseline} -result {1 1}
    test oracle-no-cloud-query {Oracle mode does not silently select an alternative Oracle analytic workload} -body {
        oceanbase::dispatch generate tpch cloud
    } -returnCodes error -match glob -result {*Unsupported OceanBase Oracle operation*}
    test oracle-schema-physical-clauses {Only OceanBase scripts remove Oracle physical table options} -body {
        oceanbase::dispatch generate tpcc build
        set definition [oceanbase::oracle::procedure_definition $::_ED(package) CreateTables]
        list [regexp -nocase {ORGANIZATION INDEX|INITRANS|PCTFREE|PCTUSED|TABLESPACE} $definition] \
            [expr {[string first {CONSTRAINT INORD PRIMARY KEY} $definition] >= 0}]
    } -result {0 1}
    test oracle-active-driver {Generic script loading reads the Oracle driver selection without changing MySQL options} -body {
        dict set configoceanbase connection ob_oracle_options {tpcc {ora_driver test count_ware 4}}
        set active [oceanbase::active_config $configoceanbase]
        list [dict get $active tpcc ob_driver] [dict get $active tpcc ob_count_ware] \
            [dict get $configoceanbase tpcc ob_driver]
    } -cleanup {set configoceanbase $baseline} -result {test 4 timed}
    test oracle-schema-array-limit {One-to-many loaders stay below the Observer 1024-piece limit} -body {
        oceanbase::dispatch generate tpcc build
        set orders [oceanbase::oracle::procedure_definition $::_ED(package) Orders]
        set results [list [expr {[string first {$o_id % 50} $orders] >= 0}]]
        oceanbase::dispatch generate tpch build
        foreach name {mk_supp mk_cust mk_part mk_order} {
            set definition [oceanbase::oracle::procedure_definition $::_ED(package) $name]
            lappend results [expr {![regexp {\$i % 1000\M} $definition]}]
        }
        set results
    } -result {1 1 1 1 1}
    test oracle-schema-values-only {Only build loaders use multi-row SQL; drivers keep native binding} -body {
        set result {}
        foreach {workload loaders} {tpcc {Customer Orders LoadItems Stock District LoadWare} tpch {mk_region mk_nation mk_supp mk_cust mk_part mk_order}} {
            oceanbase::dispatch generate $workload build
            lappend result [expr {[string first {package require oceanbaseoracleload} $::_ED(package)] >= 0}]
            foreach name $loaders {
                set definition [oceanbase::oracle::procedure_definition $::_ED(package) $name]
                lappend result [expr {![regexp {\m(orabind|oraparse|oraexec|oracommit|oraclose)\M} $definition]}] \
                    [expr {[string first {::oceanbaseoracleload::exec } $definition] >= 0}]
            }
            foreach action [expr {$workload eq {tpcc} ? {test timed} : {test}}] {
                oceanbase::dispatch generate $workload $action
                lappend result [expr {[string first {oceanbaseoracleload} $::_ED(package)] < 0}]
            }
        }
        lsort -unique $result
    } -result 1
    test oracle-tpch-date-format {Load and refresh dates match the numeric month SQL mask} -body {
        set result {}
        foreach action {build test} {
            oceanbase::dispatch generate tpch $action
            lappend result [expr {[string first {[ mk_time $d ]} $::_ED(package)] < 0}] \
                [expr {[string first {[ mk_time_bcp $d ]} $::_ED(package)] >= 0}]
        }
        set result
    } -result {1 1 1 1}
    test oracle-history-binds {Every HISTORY column has a distinct OBCI array binding name} -body {
        oceanbase::dispatch generate tpcc build
        set definition [oceanbase::oracle::procedure_definition $::_ED(package) Customer]
        list [expr {[string first {:h_c_id, :h_c_d_id, :h_c_w_id, :h_w_id, :h_d_id} $definition] >= 0}] \
            [expr {[string first {:h_w_id $h_w_id_c6 :h_d_id $h_d_id_c6 :h_date $h_date_c6} $definition] >= 0}]
    } -result {1 1}
    test oracle-tpch-primary-indexes {OceanBase creates native primary keys without attaching Oracle indexes} -body {
        oceanbase::dispatch generate tpch build
        set definition [oceanbase::oracle::procedure_definition $::_ED(package) CreateIndexes]
        list [regexp -nocase {USING INDEX|CREATE UNIQUE INDEX|DEFERRABLE} $definition] \
            [expr {[string first {CONSTRAINT PARTSUPP_PK PRIMARY KEY(PS_PARTKEY,PS_SUPPKEY)} $definition] >= 0}] \
            [expr {[string first {CONSTRAINT LINEITEM_PARTSUPP_FK FOREIGN KEY} $definition] >= 0}] \
            [expr {[string first {CONSTRAINT LINEITEM_PK PRIMARY KEY (L_ORDERKEY, L_LINENUMBER)} $definition] >= 0}] \
            [regexp {LINEITEM_PK PRIMARY KEY \(L_LINENUMBER, L_ORDERKEY\)} $definition]
    } -result {0 1 1 1 0}
    test oracle-refresh-immediate-foreign-key {Refresh inserts the order before its buffered lines without deferred constraints} -body {
        oceanbase::dispatch generate tpch test
        set definition [oceanbase::oracle::procedure_definition $::_ED(package) mk_order_ref]
        list [regexp -nocase {set constraints|DEFERRED} $definition] \
            [expr {[string first {eval $statement} $definition] < [string first {foreach hdb_row} $definition]}] \
            [expr {[string first {lappend hdb_lines [list $lsdate $lokey} $definition] >= 0}]
    } -result {0 1 1}
    test oracle-date-outputs {Call wrappers keep DATE values away from the OBCI implicit-cursor DATE buffer} -body {
        set result {}
        foreach action {test timed} {
            oceanbase::dispatch generate tpcc $action
            foreach bind {p_c_since os_entdate} {
                lappend result [expr {[string first ":$bind := TO_CHAR(hdb_date,'YYYY-MM-DD HH24:MI:SS')" $::_ED(package)] >= 0}]
            }
        }
        set result
    } -result {1 1 1 1}
    test oracle-job-metadata {Job snapshots use the active workload without saving the inactive credential profile} -setup {
        set saved_rdbms $::rdbms
        set saved_bm $::bm
        set ::rdbms OceanBase
        set ::bm TPC-C
    } -body {
        dict set configoceanbase connection ob_oracle_options {tpcc {count_ware 7} connection {ob_tenant oracle_tenant}}
        set snapshot [find_current_dict]
        list [dict get $snapshot tpcc ob_count_ware] [dict get $snapshot connection ob_tenant] \
            [dict exists $snapshot tpch] [dict exists $snapshot connection ob_oracle_options]
    } -cleanup {
        set configoceanbase $baseline
        set ::rdbms $saved_rdbms
        set ::bm $saved_bm
    } -result {7 oracle_tenant 0 0}
    test oracle-credential-values {Special characters and newlines in passwords remain literal data in generated drivers} -body {
        set result {}
        foreach password [list {two words} {a;[error unsafe]$x} {double"quote} {back\nslash} "two\nlines"] {
            foreach {workload action} {tpcc test tpcc timed tpch test} {
                set configoceanbase $baseline
                dict set configoceanbase connection ob_oracle_options [dict create $workload [dict create ${workload}_pass [quotemeta $password]]]
                oceanbase::dispatch generate $workload $action
                set start [string first "\nset connect " $::_ED(package)]
                set command {}
                foreach line [split [string range $::_ED(package) [expr {$start+1}] end] \n] {
                    append command $line \n
                    if {[info complete $command]} {break}
                }
                set probe [interp create -safe]
                try {
                    set value [$probe eval $command]
                    lappend result [expr {$value eq "$workload/$password@hdb_ob_$workload" && [info complete $::_ED(package)]}]
                } finally {interp delete $probe}
            }
        }
        lsort -unique $result
    } -cleanup {set configoceanbase $baseline} -result 1
} finally {
    set configoceanbase $original_ob
    rename load_virtual {}
    rename oracle_test_original_load_virtual load_virtual
}
set failed $::tcltest::numTests(Failed)
cleanupTests
exit [expr {$failed>0}]
