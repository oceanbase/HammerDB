# Offline SSL contracts. Real TLS handshakes are tested by oracle-tls-wire.py.
set argv {}
package require tcltest 2
namespace import ::tcltest::*
set original $configoceanbase
set baseline [oceanbaseconfig::normalize $configoceanbase]
dict set baseline connection ob_compatibility_mode oracle
set directory [makeDirectory {ob ssl files}]
foreach name {ca.pem cert.pem key.pem} {set f [open [file join $directory $name] w]; puts $f fixture; close $f}
set connection [dict get [oceanbaseconfig::oracle_options $baseline] connection]
rename load_virtual oracle_ssl_original_load_virtual
proc load_virtual {} {}
dict set connection ob_ssl true
dict set connection ob_ssl_linux_capath $directory
dict set connection ob_ssl_windows_capath $directory
dict set connection ob_ssl_ca ca.pem
dict set connection ob_ssl_cert cert.pem
dict set connection ob_ssl_key key.pem
try {
    test oracle-ssl-independent-defaults {Oracle does not inherit the MySQL SSL switch or CA} -body {
        set configuration $baseline
        dict set configuration connection ob_ssl true
        dict set configuration connection ob_ssl_ca mysql.pem
        set c [dict get [oceanbaseconfig::oracle_options $configuration] connection]
        list [dict get $c ob_ssl] [dict get $c ob_ssl_ca]
    } -result {false ca-cert.pem}
    test oracle-ssl-one-way {Reuse MySQL path resolution; preserve paths with spaces as values} -body {
        set ssl [oceanbaseoraclecommon::ssl_options $connection]
        list [dict get $ssl -ssl] [expr {[dict get $ssl -sslca] eq [file join $directory ca.pem]}] \
            [dict exists $ssl -sslcert] [dict get $ssl -library]
    } -result {true 1 0 /u01/obclient/lib/libhdbobcitls.so}
    test oracle-ssl-mutual {Two-way authentication carries the client key and certificate} -body {
        set c $connection
        dict set c ob_ssl_two_way true
        set ssl [oceanbaseoraclecommon::ssl_options $c]
        list [expr {[dict get $ssl -sslcert] eq [file join $directory cert.pem]}] \
            [expr {[dict get $ssl -sslkey] eq [file join $directory key.pem]}]
    } -result {1 1}
    test oracle-ssl-off {Disabled SSL does not read stale certificate paths or load the TLS client} -body {
        set c $connection
        dict set c ob_ssl false
        dict set c ob_ssl_ca missing.pem
        oceanbaseoraclecommon::ssl_options $c
    } -result {-ssl false}
    test oracle-ssl-missing-ca {An unreadable CA fails before connection or workload generation} -body {
        set c $connection
        dict set c ob_ssl_ca missing.pem
        oceanbaseoraclecommon::ssl_options $c
    } -returnCodes error -match glob -result {*SSL CA file is not readable:*missing.pem}
    test oracle-ssl-ca-directory {A CA directory is accepted when no single CA file is selected} -body {
        set c $connection
        dict set c ob_ssl_ca {}
        dict get [oceanbaseoraclecommon::ssl_options $c] -sslcapath
    } -result $directory
    test oracle-ssl-missing-key {Mutual SSL requires a readable private key} -body {
        set c $connection
        dict set c ob_ssl_two_way true
        dict set c ob_ssl_key missing.key
        oceanbaseoraclecommon::ssl_options $c
    } -returnCodes error -match glob -result {*SSL client file is not readable:*missing.key}
    test oracle-ssl-invalid-boolean {Invalid SSL values cannot silently select plaintext} -body {
        set c $connection
        dict set c ob_ssl typo
        oceanbaseoraclecommon::ssl_options $c
    } -returnCodes error -result {ob_ssl must be true or false}
    test oracle-ssl-driver-setup {Pooled and standalone setup carry the same SSL policy} -body {
        set configuration $baseline
        dict set configuration connection ob_oracle_options connection $connection
        set result {}
        foreach pool {false true} {
            set command [lindex [split [oceanbase::oracle::connection_setup $configuration $pool] \n] 1]
            lappend result [dict get [lindex $command end] -ssl] \
                [expr {[dict get [lindex $command end] -sslca] eq [file join $directory ca.pem]}]
        }
        set result
    } -result {true 1 true 1}
    test oracle-ssl-active-profile {CLI/job metadata reads Oracle SSL without changing the MySQL profile} -body {
        set configuration $baseline
        dict set configuration connection ob_ssl false
        dict set configuration connection ob_oracle_options connection $connection
        list [dict get [oceanbase::active_config $configuration] connection ob_ssl] [dict get $configuration connection ob_ssl]
    } -result {true false}
    test oracle-ssl-generated-paths {All schema and workload scripts carry the active SSL policy} -body {
        set configoceanbase $baseline
        dict set configoceanbase connection ob_oracle_options connection $connection
        set setup [oceanbase::oracle::connection_setup $configoceanbase]
        set result {}
        foreach {workload actions} {tpcc {build test timed check delete} tpch {build test check delete}} {
            foreach action $actions {
                oceanbase::dispatch generate $workload $action
                lappend result [expr {[string first $setup $::_ED(package)] >= 0}] [info complete $::_ED(package)]
            }
        }
        lsort -unique $result
    } -result 1
} finally {
    set configoceanbase $original
    rename load_virtual {}
    rename oracle_ssl_original_load_virtual load_virtual
    removeDirectory $directory
}
set failed $::tcltest::numTests(Failed)
cleanupTests
exit [expr {$failed > 0}]
