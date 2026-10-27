# Offline Oracle-mode configuration and libobclient connection regression tests.
set argv {}
package require tcltest 2
namespace import ::tcltest::*
set root [file dirname [file dirname [file normalize [info script]]]]
source [file join $root modules oceanbaseconfig-1.0.tm]
source [file join $root src oceanbase obopt.tcl]
source [file join $root modules xml-1.1.tm]
set baseline [oceanbaseconfig::normalize [::XML::To_Dict [file join $root config oceanbase.xml]]]
test oracle-options-defaults {Oracle credentials are independent of the MySQL credentials} -body {
    set native [oceanbaseconfig::oracle_options $baseline]
    list [dict get $native connection system_user] [dict get $native tpcc tpcc_user] [dict get $native tpcc tpcc_pass] [dict get $baseline tpcc ob_user]
} -result {sys tpcc {} root}
test oracle-options-isolation {Saved Oracle options leave the MySQL options intact} -body {
    set configured $baseline
    dict set configured connection ob_oracle_options {tpcc {tpcc_user ora_user count_ware 7}}
    set native [oceanbaseconfig::oracle_options $configured]
    list [dict get $native tpcc tpcc_user] [dict get $native tpcc count_ware] [dict get $configured tpcc ob_user]
} -result {ora_user 7 root}
test oracle-library-migration {Legacy OCI controls disappear without altering credentials or SSL} -body {
    set configured $baseline
    dict set configured connection ob_oracle_options {connection {obci_library /old/libobci.so instance old_service system_user admin ob_ssl_ca custom.pem}}
    set c [dict get [oceanbaseconfig::oracle_options $configured] connection]
    list [dict exists $c obci_library] [dict get $c instance] [dict get $c system_user] [dict get $c ob_ssl_ca]
} -result {0 {} admin custom.pem}
foreach key {obci_library instance} {
    test oracle-retired-option-$key {New CLI settings cannot silently select an unused OCI option} -body {
        oceanbase::oracle::set_option connection $key ignored
    } -returnCodes error -match glob -result {*retired OCI option*}
}
test oracle-username {Tenant and cluster qualify the protocol username directly} -body {
    oceanbaseoraclecommon::username tpcc {tenant tenant cluster cluster}
} -result tpcc@tenant#cluster
test oracle-username-cloud {Cloud endpoints can omit tenant and cluster qualification} -body {
    oceanbaseoraclecommon::username TEST {tenant {} cluster {}}
} -result TEST
test oracle-username-qualified {Reject a qualified user instead of silently double-qualifying it} -body {
    oceanbaseoraclecommon::username sys@tenant {tenant tenant cluster {}}
} -returnCodes error -match glob -result {Invalid*user*}
test oracle-endpoint-cluster {Cluster routing requires a tenant} -body {
    oceanbaseoraclecommon::validate_endpoint {host host port 2883 tenant {} cluster cluster}
} -returnCodes error -match glob -result {*tenant is required*}
test oracle-endpoint-port {Reject an invalid port before connecting} -body {
    oceanbaseoraclecommon::validate_endpoint {host host port 0 tenant {} cluster {}}
} -returnCodes error -match glob -result {*port*}
test oracle-configure-retry {A failed load cannot commit partially configured endpoints} -setup {
    rename ::oceanbaseoraclecommon::load_driver ::oceanbaseoraclecommon::test_load_driver
    set ::driver_load_attempt 0
    proc ::oceanbaseoraclecommon::load_driver {} {
        if {[incr ::driver_load_attempt] == 1} {error "Missing library"}
        return 1.0
    }
} -body {
    catch {oceanbaseoraclecommon::configure {host old.example port 2881 tenant old_tenant cluster {} users {sys tpcc}}}
    oceanbaseoraclecommon::configure {host new.example port 2881 tenant new_tenant cluster {} users {sys tpcc}} 120 {-ssl true}
    set e [dict get $::oceanbaseoraclecommon::endpoints hdb_ob_tpcc]
    list [dict get $e host] [dict get $e tenant] $::oceanbaseoraclecommon::connection_options
} -cleanup {
    set ::oceanbaseoraclecommon::connection_options {}
    set ::oceanbaseoraclecommon::endpoints {}
    rename ::oceanbaseoraclecommon::load_driver {}
    rename ::oceanbaseoraclecommon::test_load_driver ::oceanbaseoraclecommon::load_driver
    unset ::driver_load_attempt
} -result {new.example new_tenant {-ssl true}}
test oracle-bind-lexer {Only placeholders outside literals, quoted names and comments are converted} -body {
    oceanbaseoracledriver::bind_sql {BEGIN p(:x,:X,':skip',q'[a':skip]',"colon:name"); -- :skip
/* :skip */ :out := :value; END;}
} -result {{BEGIN p(?,?,':skip',q'[a':skip]',"colon:name"); -- :skip
/* :skip */ ? := ?; END;} {:X :X :OUT :VALUE}}
test oracle-ssl-default {Oracle SSL is independent of the MySQL switch} -body {
    set configured $baseline
    dict set configured connection ob_ssl true
    set connection [dict get [oceanbaseconfig::oracle_options $configured] connection]
    dict get $connection ob_ssl
} -result false
test oracle-ssl-switch {No CA is optional just as in the MySQL SSL form} -body {
    set c [dict get [oceanbaseconfig::oracle_options $baseline] connection]
    dict set c ob_ssl true
    dict set c ob_ssl_ca {}
    dict set c ob_ssl_linux_capath {}
    dict set c ob_ssl_windows_capath {}
    oceanbaseoraclecommon::ssl_setting $c
} -result {-ssl true}
test oracle-ssl-ca-mapping {A populated CA is validated and passed to the same C option as MySQL} -setup {
    set ca [makeFile {test CA} oracle-ca.pem]
} -body {
    set c [dict get [oceanbaseconfig::oracle_options $baseline] connection]
    dict set c ob_ssl true
    dict set c ob_ssl_ca $ca
    dict set c ob_ssl_linux_capath {}
    dict set c ob_ssl_windows_capath {}
    list [expr {[oceanbaseoraclecommon::ssl_setting $c] eq [oceanbasecommon::ssl_options [dict create connection $c]]}] \
        [dict get [oceanbaseoraclecommon::ssl_setting $c] -sslca]
} -cleanup {removeFile oracle-ca.pem} -result [list 1 [file join [temporaryDirectory] oracle-ca.pem]]
test oracle-ssl-ca-unreadable {Do not silently ignore an explicitly configured CA} -body {
    set c [dict get [oceanbaseconfig::oracle_options $baseline] connection]
    dict set c ob_ssl true
    dict set c ob_ssl_ca /nonexistent/hdb-test-ca.pem
    oceanbaseoraclecommon::ssl_setting $c
} -returnCodes error -match glob -result {SSL CA file is not readable:*}
test oracle-insert-empty {A silently skipped insert fails the schema build} -setup {
    rename ::oceanbaseoracledriver::oraexec ::oceanbaseoracledriver::saved_exec
    rename ::oceanbaseoracledriver::oramsg ::oceanbaseoracledriver::saved_msg
    proc ::oceanbaseoracledriver::oraexec {cursor} {return 0}
    proc ::oceanbaseoracledriver::oramsg {args} {return 0}
} -body {
    oceanbaseoraclecommon::exec_insert cursor
} -cleanup {rename ::oceanbaseoracledriver::oraexec {}; rename ::oceanbaseoracledriver::oramsg {}; rename ::oceanbaseoracledriver::saved_exec ::oceanbaseoracledriver::oraexec; rename ::oceanbaseoracledriver::saved_msg ::oceanbaseoracledriver::oramsg} -returnCodes error -match glob -result {*inserted no rows*}
test oracle-cli-options {CLI changes the active Oracle profile and preserves MySQL and native Oracle settings} -setup {
    set saved_ob $::configoceanbase
    set saved_ora $::configoracle
    set saved_rdbms $::rdbms
    rename ::oceanbaseconfig::save ::oceanbaseconfig::oracle_test_save
    proc ::oceanbaseconfig::save {args} {}
    set ::configoceanbase $baseline
    set ::rdbms OceanBase
    dict set ::configoceanbase connection ob_compatibility_mode oracle
} -body {
    diset connection ob_host oracle.example
    diset connection ob_ssl true
    diset tpcc ob_user ora_cli
    diset tpcc count_ware 3
    set active [oceanbase::active_config $::configoceanbase]
    list [dict get $active connection ob_host] [dict get $active tpcc ob_user] \
        [dict get $active tpcc ob_count_ware] [dict get $::configoceanbase tpcc ob_user] \
        [expr {$saved_ora eq $::configoracle}] [dict get $active connection ob_ssl] \
        [dict get $::configoceanbase connection ob_ssl]
} -cleanup {
    rename ::oceanbaseconfig::save {}
    rename ::oceanbaseconfig::oracle_test_save ::oceanbaseconfig::save
    set ::configoceanbase $saved_ob
    set ::rdbms $saved_rdbms
} -result {oracle.example ora_cli 3 root 1 true false}
test oracle-distributed-cli-aliases {OB distribution options target the selected Oracle profile for both workloads} -setup {
    set saved_ob $::configoceanbase
    set saved_rdbms $::rdbms
    rename ::oceanbaseconfig::save ::oceanbaseconfig::oracle_alias_test_save
    proc ::oceanbaseconfig::save {args} {}
    set ::configoceanbase $baseline
    set ::rdbms OceanBase
    dict set ::configoceanbase connection ob_compatibility_mode oracle
} -body {
    diset tpcc ob_distributed_schema true
    diset tpcc ob_partition_count 4
    diset tpch ob_tpch_optimized_schema true
    diset tpch ob_tpch_partition_count 8
    set active [oceanbase::active_config $::configoceanbase]
    list [dict get $active tpcc ob_distributed_schema] [dict get $active tpcc ob_partition_count] \
        [dict get $active tpch ob_tpch_optimized_schema] [dict get $active tpch ob_tpch_partition_count] \
        [dict get $::configoceanbase tpcc ob_distributed_schema] [dict get $::configoceanbase tpch ob_tpch_partition_count]
} -cleanup {
    rename ::oceanbaseconfig::save {}
    rename ::oceanbaseconfig::oracle_alias_test_save ::oceanbaseconfig::save
    set ::configoceanbase $saved_ob
    set ::rdbms $saved_rdbms
} -result {true 4 true 8 false 24}

test oracle-no-fallback {Oracle execution never silently uses the MySQL workload} -body {
    set ::configoceanbase $baseline
    dict set ::configoceanbase connection ob_compatibility_mode oracle
    dict set ::configoceanbase connection ob_oracle_options {tpcc {checkpoint true}}
    oceanbase::dispatch generate tpcc build
} -returnCodes error -match glob -result {*Oracle*does not support checkpoint*}
foreach key {allwarehouse async_scale} {
    test oracle-test-driver-$key {Timed-only options fail before test-driver generation} -body {
        set configured $baseline
        dict set configured connection ob_compatibility_mode oracle
        dict set configured connection ob_oracle_options [dict create tpcc [dict create ora_driver test $key true]]
        oceanbase::oracle::validate $configured
    } -returnCodes error -match glob -result {*requires the Timed Driver Script}
}
set failed $::tcltest::numTests(Failed)
cleanupTests
exit [expr {$failed > 0}]
