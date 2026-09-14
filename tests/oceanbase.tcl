set argv {}
package require tcltest 2
namespace import ::tcltest::*
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root modules mysqlcommon-1.0.tm]
source [file join $root modules oceanbaseconfig-1.0.tm]
source [file join $root src oceanbase obopt.tcl]
source [file join $root src generic gengen.tcl]

test counter-mysql-order {MySQL counters need not be ordered or case-sensitive} -body {
    mysqlcommon::configure MySQL 0
    mysqlcommon::parse_transaction_count {{com_ROLLBACK 7} {COM_commit 20}}
} -result 27
test counter-oceanbase {OB commit and rollback counters are aggregated} -body {
    mysqlcommon::configure OceanBase 120
    mysqlcommon::parse_transaction_count {{{trans rollback count} 2} {{trans commit count} 100}}
} -result 102
test counter-empty {An empty result must fail clearly, not become zero TPM} -body {
    mysqlcommon::parse_transaction_count {}
} -returnCodes error -match glob -result {*counter unavailable*}
test counter-partial {Do not silently omit rollback statistics} -body {
    mysqlcommon::parse_transaction_count {{{trans commit count} 100}}
} -returnCodes error -match glob -result {*trans rollback count*}
test counter-invalid {Reject malformed server values} -body {
    mysqlcommon::parse_transaction_count {{{trans commit count} invalid}}
} -returnCodes error -match glob -result {Invalid OceanBase*}
test counter-wide {Counters can exceed 32-bit integers} -body {
    mysqlcommon::parse_transaction_count {{{trans commit count} 9000000000} {{trans rollback count} 1}}
} -result 9000000001
test counter-query {Keep the dollar sign in OB system view names} -body {
    string match {*GV$SYSSTAT*} [mysqlcommon::counter_sql]
} -result 1
namespace eval mysql {proc exec {handle sql} {set ::last_sql $sql}}
test session-mysql {Native MySQL sessions must be untouched} -body {
    mysqlcommon::configure MySQL 120
    set ::last_sql untouched
    mysqlcommon::configure_session handle
    set ::last_sql
} -result untouched
test session-oceanbase {Only configure the current OB session, in microseconds} -body {
    mysqlcommon::configure OceanBase 120
    mysqlcommon::configure_session handle
    set ::last_sql
} -result {SET SESSION ob_query_timeout = 120000000}
test session-invalid {Reject non-numeric timeout before creating SQL} -body {
    mysqlcommon::configure OceanBase {1; invalid}
} -returnCodes error -match glob -result {*timeout must be*}
test login-direct {A direct tenant login has no cluster suffix} -body {
    oceanbase::mysql::username root hammerdb {}
} -result root@hammerdb
test login-proxy {An OBProxy login includes the configured cluster} -body {
    oceanbase::mysql::username root hammerdb ob_hammerdb
} -result root@hammerdb#ob_hammerdb
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
    expr {[oceanbaseconfig::normalize $input] eq $input}
} -result 1
test defaults-oracle {MySQL password defaults are not injected into another mode} -body {
    dict exists [oceanbaseconfig::normalize {connection {ob_compatibility_mode oracle}}] tpcc
} -result 0
test data-native {Existing native data formats are unchanged} -body {
    set result {}
    foreach db {Oracle MSSQLServer Db2 MySQL MariaDB PostgreSQL} {lappend result [data_generation_format $db tpcc]}
    set result
} -result {oracle mssql db2 mysql maria pg}
test data-mode-dispatch {Both generators obtain their format from the selected backend} -setup {
    set saved_ob $::configoceanbase
    set saved_backends $::oceanbase::backends
    set had_dbdict [info exists ::dbdict]
    if {$had_dbdict} {set saved_dbdict $::dbdict}
    set ::dbdict {oceanbase {name OceanBase prefix ob}}
    namespace eval ::ob_format_test {
        proc data_format {workload} {lappend ::format_calls $workload; return oracle}
    }
    dict set ::oceanbase::backends oracle ::ob_format_test
    dict set ::configoceanbase connection ob_compatibility_mode oracle
    set ::format_calls {}
} -body {
    list [data_generation_format OceanBase tpcc] [data_generation_format OceanBase tpch] $::format_calls
} -cleanup {
    set ::configoceanbase $saved_ob
    set ::oceanbase::backends $saved_backends
    if {$had_dbdict} {set ::dbdict $saved_dbdict} else {unset ::dbdict}
    namespace delete ::ob_format_test
    unset ::format_calls
} -result {oracle oracle {tpcc tpch}}

set failed $::tcltest::numTests(Failed)
cleanupTests
if {$failed} {exit 1}
