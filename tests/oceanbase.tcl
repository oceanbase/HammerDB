set argv {}
package require tcltest 2
namespace import ::tcltest::*
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root modules oceanbasecommon-1.0.tm]
source [file join $root modules oceanbaseconfig-1.0.tm]
source [file join $root src oceanbase obopt.tcl]
source [file join $root src generic gengen.tcl]
# Offline generator fixtures stop at the confirmation dialog and create no files.
if {![llength [info commands findtempdir]]} {
    proc findtempdir {} {return [temporaryDirectory]}
}

test runtime-password-arguments {Empty and special-character passwords remain one connection argument} -body {
    set script {if [catch {package require $library} message] { error "Failed to load $library - $message" }
append connectstring " -user $user -password $password"
set login_command "mysqlconnect [ dict get $connectstring ]"
eval $login_command}
    set script [oceanbase::mysql::rewrite_runtime $script 120]
    set worker [interp create]
    $worker eval {package provide mysqltcl 1.0; package provide oceanbasecommon 1.0
        namespace eval oceanbasecommon {proc configure {args} {}}
        proc mysqlconnect {args} {return $args}}
    set results {}
    foreach password [list {} {two words} {a;[error unsafe]$x\{b}] {
        $worker eval [list set library mysqltcl]
        $worker eval [list set connectstring {-host host -port 2881}]
        $worker eval [list set user root@hammerdb]
        $worker eval [list set password $password]
        set args [$worker eval $script]
        lappend results [expr {[llength $args] == 8 && [lindex $args 7] eq $password}]
    }
    interp delete $worker
    set results
} -result {1 1 1}

test counter-oceanbase-order {OB counters need not be ordered or case-sensitive} -body {
    oceanbasecommon::parse_transaction_count {{{TRANS rollback COUNT} 7} {{trans COMMIT count} 20}}
} -result 27
test counter-oceanbase {OB commit and rollback counters are aggregated} -body {
    oceanbasecommon::configure 120
    oceanbasecommon::parse_transaction_count {{{trans rollback count} 2} {{trans commit count} 100}}
} -result 102
test counter-empty {An empty result must fail clearly, not become zero TPM} -body {
    oceanbasecommon::parse_transaction_count {}
} -returnCodes error -match glob -result {*counter unavailable*}
test counter-partial {Do not silently omit rollback statistics} -body {
    oceanbasecommon::parse_transaction_count {{{trans commit count} 100}}
} -returnCodes error -match glob -result {*trans rollback count*}
test counter-invalid {Reject malformed server values} -body {
    oceanbasecommon::parse_transaction_count {{{trans commit count} invalid}}
} -returnCodes error -match glob -result {Invalid OceanBase*}
test counter-wide {Counters can exceed 32-bit integers} -body {
    oceanbasecommon::parse_transaction_count {{{trans commit count} 9000000000} {{trans rollback count} 1}}
} -result 9000000001
test counter-query {Keep the dollar sign in OB system view names} -body {
    string match {*GV$SYSSTAT*} [oceanbasecommon::counter_sql]
} -result 1
namespace eval mysql {proc exec {handle sql} {set ::last_sql $sql}}
test session-oceanbase {Only configure the current OB session, in microseconds} -body {
    oceanbasecommon::configure 120
    oceanbasecommon::configure_session handle
    set ::last_sql
} -result {SET SESSION ob_query_timeout = 120000000}
test session-invalid {Reject non-numeric timeout before creating SQL} -body {
    oceanbasecommon::configure {1; invalid}
} -returnCodes error -match glob -result {*timeout must be*}
test login-direct {A direct tenant login has no cluster suffix} -body {
    oceanbase::mysql::username root hammerdb {}
} -result root@hammerdb
test login-proxy {An OBProxy login includes the configured cluster} -body {
    oceanbase::mysql::username root hammerdb ob_hammerdb
} -result ob_hammerdb:hammerdb:root
test login-qualified {Reject double qualification instead of inventing a login} -body {
    oceanbase::mysql::username root@hammerdb hammerdb {}
} -returnCodes error -match glob -result {Use separate*}
test login-empty {Tenant selection is explicit} -body {
    oceanbase::mysql::username root {} {}
} -returnCodes error -match glob -result {*required*}

source [file join $root modules xml-1.1.tm]
test config-empty {OceanBase supplies defaults without changing XML parsing} -body {
    set config [oceanbaseconfig::normalize [::XML::To_Dict [file join $root config oceanbase.xml]]]
    list [dict get $config connection ob_cluster] [dict get $config tpcc ob_pass] [dict get $config tpch ob_tpch_pass]
} -result {{} {} {}}
if {[llength [info commands find_config_dir]] == 0} {
    proc find_config_dir {} {return [file join $::root config]}
}
test config-mapping {OB credentials and port map without enabling legacy sys preparation} -body {
    set mapped [oceanbase::mysql::config [::XML::To_Dict [file join $root config oceanbase.xml]]]
    list [dict get $mapped tpcc mysql_user] [dict get $mapped connection mysql_port] [dict get $mapped tpch mysql_tpch_obcompat]
} -result {root@hammerdb 2881 false}
test distributed-defaults {Existing OceanBase configurations keep the native schema by default} -body {
    set normalized [oceanbaseconfig::normalize {connection {ob_compatibility_mode mysql} tpcc {} tpch {}}]
    list [dict get $normalized tpcc ob_distributed_schema] [dict get $normalized tpcc ob_partition_count]
} -result {false 24}
test distributed-validation {Reject an invalid distributed partition count} -body {
    set config [oceanbaseconfig::normalize [::XML::To_Dict [file join $root config oceanbase.xml]]]
    dict set config tpcc ob_distributed_schema true
    dict set config tpcc ob_partition_count 0
    oceanbase::mysql::config $config
} -returnCodes error -match glob -result {*partition count*}
test distributed-ddl {Warehouse-affine tables share one cluster-scoped table group} -setup {
    set ::captured_sql {}
    proc mysqlexec {handler sql} {lappend ::captured_sql $sql}
    proc ConnectToMySQL {args} {return item_handle}
    proc mysqluse {args} {}
    proc mysqlclose {args} {}
    eval [oceanbase::mysql::distributed_tprocc_script]
} -body {
    CreateOceanBaseTables handle InnoDB tpcc_test 24 host 2883 null {} user password
    set result [list [llength $::captured_sql] [string match {*SHARDING = 'PARTITION'*} [lindex $::captured_sql 0]] [string match {*SCOPE = 'CLUSTER'*} [lindex $::captured_sql 1]]]
    foreach {index key} {2 c_w_id 3 d_w_id 4 h_w_id 5 no_w_id 6 o_w_id 7 ol_w_id 8 s_w_id 9 w_id} {
        set ddl [lindex $::captured_sql $index]
        lappend result [expr {[string match {*TABLEGROUP = hdb_tpcc_test_tg*} $ddl] && [string match "*PARTITION BY HASH (`$key`)*PARTITIONS 24*" $ddl]}]
    }
    set item [lindex $::captured_sql 10]
    lappend result [string match {*DUPLICATE_SCOPE = 'CLUSTER'*} $item]
    lappend result [string match {*TABLEGROUP = hdb_tpcc_test_tg*} $item]
    set result
} -cleanup {
    rename CreateOceanBaseTables {}
    rename mysqlexec {}
    rename ConnectToMySQL {}
    rename mysqluse {}
    rename mysqlclose {}
    unset ::captured_sql
} -result {11 1 1 1 1 1 1 1 1 1 1 1 0}
test distributed-rewrite {Only an OceanBase distributed build replaces MySQL table creation} -body {
    set source {proc do_tpcc {} {
CreateTables $mysql_handler $mysql_storage_engine $num_part $history_pk
}
do_tpcc host}
    set rewritten [oceanbase::mysql::rewrite_distributed_tprocc $source 24]
    list [string match {*CreateOceanBaseTables $mysql_handler $mysql_storage_engine $db 24 $host $port $socket $ssl_options $user $password*} $rewritten] [string match {*proc CreateOceanBaseTables*} $rewritten]
} -result {1 1}
test distributed-query-rewrite {Distributed monitoring aggregates include the full partition-key range} -body {
    set source {select max(w_id) from warehouse
select max(d_id) from district
select sum(d_next_o_id) from district}
    oceanbase::mysql::rewrite_distributed_tprocc_queries $source 70
} -result {select max(w_id) from warehouse where w_id between 1 and 70
select max(d_id) from district where d_w_id between 1 and 70
select sum(d_next_o_id) from district where d_w_id between 1 and 70}
test duplicate-reconnect {A successful duplicate-table DDL survives an OBProxy disconnect} -setup {
    set ::captured_sql {}
    set ::item_attempts 0
    proc ConnectToMySQL {args} {return item_handle}
    proc mysqluse {args} {}
    proc mysqlclose {args} {}
    proc mysqlexec {handler sql} {
        lappend ::captured_sql $sql
        if {[string match {*CREATE TABLE `item`*} $sql] && [incr ::item_attempts] == 1} {error "Lost connection to MySQL server during query"}
    }
    namespace eval mysql {proc sel {args} {return [list item "CREATE TABLE `item` (`i_id` INT) DUPLICATE_SCOPE = 'CLUSTER'"]}}
    eval [oceanbase::mysql::distributed_tprocc_script]
} -body {
    CreateOceanBaseTables handle InnoDB tpcc_test 24 host 2883 null {} user password
    list $::item_attempts [llength $::captured_sql]
} -cleanup {
    rename CreateOceanBaseTables {}
    rename ConnectToMySQL {}
    rename mysqluse {}
    rename mysqlclose {}
    rename mysqlexec {}
    rename mysql::sel {}
    unset ::captured_sql ::item_attempts
} -result {1 11}
test config-isolation {A failing generator restores the saved MySQL configuration and TLS options} -body {
    set configoceanbase [::XML::To_Dict [file join $root config oceanbase.xml]]
    if {![info exists ::configmysql]} {set ::configmysql {sentinel unchanged}}
    set saved_config $::configmysql
    set ::mysql_ssl_options {sentinel unchanged}
    proc ob_failing_generator {} {error expected}
    catch {oceanbase::mysql::with_config ob_failing_generator} message
    list $message [expr {$::configmysql eq $saved_config}] $::mysql_ssl_options
} -cleanup {rename ob_failing_generator {}; unset ::mysql_ssl_options} -result {expected 1 {sentinel unchanged}}

test mode-legacy {Existing configurations default to the MySQL backend} -body {
    oceanbase::backend {connection {ob_host localhost}}
} -result ::oceanbase::mysql
test mode-oracle-unsupported {Oracle must never fall back to the MySQL implementation} -body {
    oceanbase::backend {connection {ob_compatibility_mode oracle}}
} -returnCodes error -match glob -result {*oracle*not implemented*}
test mode-unknown {Mode values cannot select arbitrary Tcl commands} -body {
    oceanbase::backend {connection {ob_compatibility_mode {mysql; error unexpected}}}
} -returnCodes error -match glob -result {*not implemented*}
test mode-extension {A second backend receives workload, counter and option operations} -setup {
    set saved_ob $::configoceanbase
    set saved_backends $::oceanbase::backends
    namespace eval ::ob_test_backend {
        proc generate {args} {return [linsert $args 0 generated]}
        proc counter {args} {return [linsert $args 0 counted]}
        proc options {args} {return [linsert $args 0 options]}
        proc validate {config} {return validated}
    }
    dict set ::oceanbase::backends oracle ::ob_test_backend
    dict set ::configoceanbase connection ob_compatibility_mode oracle
} -body {
    list [oceanbase::dispatch generate tpcc build] [oceanbase::dispatch counter TPC-H 1 master] [oceanbase::dispatch options tpch drive] [oceanbase::validate $::configoceanbase]
} -cleanup {
    set ::configoceanbase $saved_ob
    set ::oceanbase::backends $saved_backends
    namespace delete ::ob_test_backend
} -result {{generated tpcc build} {counted TPC-H 1 master} {options tpch drive} validated}

test xml-unchanged {The shared parser still omits self-closing elements} -body {
    set raw [::XML::To_Dict [file join $root config oceanbase.xml]]
    list [dict exists $raw connection ob_cluster] [dict exists $raw tpcc ob_pass]
} -result {0 0}
test defaults-preserved {Normalization preserves configured values and explicit empty values} -body {
    set input {connection {ob_cluster existing ob_compatibility_mode mysql} tpcc {ob_pass example} tpch {ob_tpch_pass {}}}
    set normalized [oceanbaseconfig::normalize $input]
    list [dict get $normalized connection ob_cluster] [dict get $normalized tpcc ob_pass] [dict get $normalized tpch ob_tpch_pass] [dict get $normalized tpcc ob_distributed_schema] [dict get $normalized tpcc ob_partition_count]
} -result {existing example {} false 24}
test defaults-oracle {MySQL password defaults are not injected into another mode} -body {
    dict exists [oceanbaseconfig::normalize {connection {ob_compatibility_mode oracle}}] tpcc
} -result 0
test data-native {Existing native formats are unchanged in both generators} -setup {
    set had_rdbms [info exists ::rdbms]
    if {$had_rdbms} {set saved_rdbms $::rdbms}
    set had_dialog [llength [info commands tk_messageBox]]
    if {$had_dialog} {rename tk_messageBox saved_data_dialog}
    proc tk_messageBox {args} {set ::selected_format [uplevel 1 {set db}]; return no}
} -body {
    set result {}
    foreach database {Oracle MSSQLServer Db2 MySQL MariaDB VillageSQL PostgreSQL} {
        set ::rdbms $database
        gendata_tpcc
        lappend result $::selected_format
        gendata_tpch
        lappend result $::selected_format
    }
    set result
} -cleanup {
    rename tk_messageBox {}
    if {$had_dialog} {rename saved_data_dialog tk_messageBox}
    if {$had_rdbms} {set ::rdbms $saved_rdbms} else {unset ::rdbms}
    unset ::selected_format
} -result {oracle oracle mssql mssql db2 db2 mysql mysql maria maria vsql vsql pg pg}
test data-oceanbase {Both offline generators select the OceanBase default format} -setup {
    set saved_ob $::configoceanbase
    set had_rdbms [info exists ::rdbms]
    if {$had_rdbms} {set saved_rdbms $::rdbms}
    set ::rdbms OceanBase
    dict set ::configoceanbase connection ob_compatibility_mode mysql
    set had_dialog [llength [info commands tk_messageBox]]
    if {$had_dialog} {rename tk_messageBox saved_data_dialog}
    proc tk_messageBox {args} {set ::selected_format [uplevel 1 {set db}]; return no}
} -body {
    gendata_tpcc
    set c $::selected_format
    gendata_tpch
    list $c $::selected_format
} -cleanup {
    set ::configoceanbase $saved_ob
    rename tk_messageBox {}
    if {$had_dialog} {rename saved_data_dialog tk_messageBox}
    if {$had_rdbms} {set ::rdbms $saved_rdbms} else {unset ::rdbms}
    unset ::selected_format
} -result {ob ob}
test data-oceanbase-unsupported {Offline generators reject unimplemented tenant modes before the dialog} -setup {
    set saved_ob $::configoceanbase
    set had_rdbms [info exists ::rdbms]
    if {$had_rdbms} {set saved_rdbms $::rdbms}
    set ::rdbms OceanBase
    dict set ::configoceanbase connection ob_compatibility_mode oracle
} -body {
    set result {}
    foreach command {gendata_tpcc gendata_tpch} {
        lappend result [catch {$command} message] [string match {*not implemented*} $message]
    }
    set result
} -cleanup {
    set ::configoceanbase $saved_ob
    if {$had_rdbms} {set ::rdbms $saved_rdbms} else {unset ::rdbms}
} -result {1 1 1 1}

set failed $::tcltest::numTests(Failed)
cleanupTests
if {$failed} {exit 1}
