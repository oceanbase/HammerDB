# Offline Oracle-mode configuration and OBCI connection-format regression tests.
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
test oracle-library-default {A portable driver default does not override a saved library path} -setup {
    set had_library [info exists ::env(OBCI_LIBRARY)]
    if {$had_library} {set saved_library $::env(OBCI_LIBRARY)}
    set ::env(OBCI_LIBRARY) /portable/libobci.so
} -body {
    set configured $baseline
    set default [dict get [oceanbaseconfig::oracle_options $configured] connection obci_library]
    dict set configured connection ob_oracle_options {connection {obci_library /saved/libobci.so}}
    list $default [dict get [oceanbaseconfig::oracle_options $configured] connection obci_library]
} -cleanup {
    if {$had_library} {set ::env(OBCI_LIBRARY) $saved_library} else {unset ::env(OBCI_LIBRARY)}
} -result {/portable/libobci.so /saved/libobci.so}
test oracle-tns {Tenant qualification is carried by OBCI, outside Oratcl's username parser} -body {
    set tns [oceanbaseoraclecommon::tns host 2883 tenant cluster {} {sys tpcc}]
    list [string match {*OB_USER_EXTRA_INFO=@tenant#cluster*} $tns] [string match {*SERVICE_NAME=tpcc*} $tns] [llength [split [string trim $tns] \n]]
} -result {1 1 2}
test oracle-tns-cloud {Cloud endpoints can omit tenant and cluster qualification} -body {
    string match {*OB_USER_EXTRA_INFO*} [oceanbaseoraclecommon::tns host 2883 {} {} {} {sys tpcc}]
} -result 0
test oracle-tns-injection {TNS values cannot inject another descriptor} -body {
    oceanbaseoraclecommon::tns {host)(PORT=1} 2883 tenant {} {} {sys tpcc}
} -returnCodes error -match glob -result {Invalid*host*}
test oracle-tns-qualified {Reject a qualified user before constructing a TNS file} -body {
    oceanbaseoraclecommon::tns host 2883 tenant {} {} {sys@tenant}
} -returnCodes error -match glob -result {Invalid*user*}
test oracle-tns-cluster {Cluster routing requires a tenant} -body {
    oceanbaseoraclecommon::tns host 2883 {} cluster {} {sys}
} -returnCodes error -match glob -result {*tenant is required*}
test oracle-password {Fail clearly for a password Oratcl cannot represent} -body {
    oceanbaseoraclecommon::connect tpcc {pass@word}
} -returnCodes error -match glob -result {*cannot encode @*}
test oracle-configure-retry {Fixing a failed driver load cannot retain an earlier tenant descriptor} -setup {
    set had_tns [info exists ::env(OBCI_TNS_FILE)]
    if {$had_tns} {set saved_tns $::env(OBCI_TNS_FILE)}
    rename ::oceanbaseoraclecommon::load_driver ::oceanbaseoraclecommon::test_load_driver
    proc ::oceanbaseoraclecommon::load_driver {library} {
        if {$library eq "missing"} {error "Missing library"}
        return 4.6.1
    }
} -body {
    catch {oceanbaseoraclecommon::configure {missing old.example 2881 old_tenant {} {} {sys tpcc}}}
    oceanbaseoraclecommon::configure {available new.example 2881 new_tenant {} {} {sys tpcc}}
    set f [open $::env(OBCI_TNS_FILE)]
    set descriptor [read $f]
    close $f
    list [string match {*HOST=new.example*OB_USER_EXTRA_INFO=@new_tenant*} $descriptor] \
        [string match {*old_tenant*} $descriptor]
} -cleanup {
    file delete $::oceanbaseoraclecommon::tns_file
    set ::oceanbaseoraclecommon::tns_file {}
    set ::oceanbaseoraclecommon::connection_options {}
    rename ::oceanbaseoraclecommon::load_driver {}
    rename ::oceanbaseoraclecommon::test_load_driver ::oceanbaseoraclecommon::load_driver
    if {$had_tns} {set ::env(OBCI_TNS_FILE) $saved_tns} else {unset -nocomplain ::env(OBCI_TNS_FILE)}
} -result {1 0}
test oracle-insert-empty {A silently skipped insert fails the schema build} -setup {
    proc ::oraexec {cursor} {return 0}
    proc ::oramsg {args} {return 0}
} -body {
    oceanbaseoraclecommon::exec_insert cursor
} -cleanup {rename ::oraexec {}; rename ::oramsg {}} -returnCodes error -match glob -result {*inserted no rows*}
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
    diset tpcc ob_user ora_cli
    diset tpcc count_ware 3
    set active [oceanbase::active_config $::configoceanbase]
    list [dict get $active connection ob_host] [dict get $active tpcc ob_user] \
        [dict get $active tpcc ob_count_ware] [dict get $::configoceanbase tpcc ob_user] \
        [expr {$saved_ora eq $::configoracle}]
} -cleanup {
    rename ::oceanbaseconfig::save {}
    rename ::oceanbaseconfig::oracle_test_save ::oceanbaseconfig::save
    set ::configoceanbase $saved_ob
    set ::rdbms $saved_rdbms
} -result {oracle.example ora_cli 3 root 1}
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
