# Run inside HammerDB CLI: hammerdbcli auto tests/oceanbase-generated.tcl
set argv {}
package require tcltest 2
namespace import ::tcltest::*
dbset db ob
dbset bm TPROC-C
diset tpcc ob_driver test
diset tpcc ob_no_stored_procs true
loadscript
proc generated_proc {name script} {
    set start [string first "proc $name \{" $script]
    if {$start < 0} {error "Missing generated procedure $name"}
    set command ""
    foreach line [split [string range $script $start end] \n] {
        append command $line \n
        if {[info complete $command]} {return $command}
    }
    error "Incomplete generated procedure $name"
}
set mock [interp create]
$mock eval [generated_proc ostat $::_ED(package)]
$mock eval {
    set byname 1
    set queries {}
    proc RandomNumber {lo hi} {if {$hi == 100 && !$::byname} {return 99}; return 1}
    proc NURand {args} {return 1}
    proc randname {args} {return Known}
    proc mysqlexec {args} {}
    proc puts {args} {set ::output [lindex $args end]}
    namespace eval mysql {
        proc commit {args} {}
        proc sel {handle sql mode} {
            lappend ::queries $sql
            if {[string match {SELECT count(c_id)*} $sql]} {return 1}
            if {[string match {SELECT c_balance, c_first, c_middle, c_id*} $sql]} {return {{25 First M 777}}}
            if {[string match {SELECT c_balance, c_first, c_middle, c_last*} $sql]} {
                if {$mode ne "-flatlist"} {error "Customer ID lookup must use a flat row"}
                return {25 First M Known}
            }
            return {}
        }
    }
}
test order-status-byname {Use the chosen customer's ID, including customers with no orders} -body {
    $mock eval {
        set byname 1
        set queries {}
        ostat handle 1 false true
        expr {[lsearch -glob $queries {*o_c_id = 777*}] >= 0 && [string match {777,Known,First,M,25,0,,} $output]}
    }
} -result 1
test order-status-byid {Flat customer rows and empty order dates are handled} -body {
    $mock eval {
        set byname 0
        ostat handle 1 false true
        set output
    }
} -result {1,Known,First,M,25,0,,}
interp delete $mock
test mysql-after-ob {A native MySQL script has no OceanBase runtime dependency} -body {
    dbset db mysql
    diset tpcc mysql_driver test
    loadscript
    expr {[string first {oceanbasecommon} $::_ED(package)] < 0}
} -result 1
# Generate schema scripts without allocating loader threads or connecting to a database.
rename load_virtual original_load_virtual
proc load_virtual {} {}
proc tpch_date_formats {script} {
    list [regexp -all {str_to_date\('[^']*','%Y-%M-%d'\)} $script] \
         [regexp -all {str_to_date\('[^']*','%Y-%b-%d'\)} $script]
}
foreach database {mysql ob mysql} label {mysql-before-ob oceanbase mysql-after-ob} expected {{4 0} {0 4} {4 0}} {
    dbset db $database
    dbset bm TPROC-H
    test date-build-$label {Only OceanBase initial-load SQL uses abbreviated-month parsing} -body {
        if {$database eq "ob"} {build_obtpch} else {build_mysqltpch}
        tpch_date_formats $::_ED(package)
    } -result $expected
    test date-refresh-$label {Only OceanBase refresh SQL uses abbreviated-month parsing} -body {
        loadscript
        tpch_date_formats $::_ED(package)
    } -result $expected
}
rename load_virtual {}
rename original_load_virtual load_virtual

# Reusing the generator must leave native scripts untouched after OB generation.
foreach asynchronous {false true} {
    test runtime-timed-$asynchronous {OB timed counters, labels and session hooks are isolated} -setup {
        set saved_ob $::configoceanbase
    } -body {
        dbset db mysql
        dbset bm TPROC-C
        diset tpcc mysql_async_scale $asynchronous
        loadtimedmysqltpcc
        set native $::_ED(package)
        dbset db ob
        # Exercise the backend with an async fixture; the OB UI does not expose it.
        dict set ::configoceanbase tpcc ob_async_scale $asynchronous
        loadtimedobtpcc
        set ob $::_ED(package)
        dbset db mysql
        loadtimedmysqltpcc
        list [expr {$native eq $::_ED(package)}] [info complete $ob] \
            [regexp -all {oceanbasecommon::transaction_count} $ob] \
            [expr {[string first {testresult $nopm $tpm OceanBase} $ob] >= 0}] \
            [expr {[string first {Com_commit} $ob] < 0}] \
            [expr {[string first {oceanbasecommon} $native] < 0}]
    } -cleanup {
        set ::configoceanbase $saved_ob
    } -result {1 1 2 1 1 1}
}
test runtime-connect {Both synchronous and asynchronous OB connections apply a session timeout} -setup {
    set mock [interp create]
    $mock eval [list source [file join [file dirname [file dirname [info script]]] modules oceanbasecommon-1.0.tm]]
    foreach name {chk_socket ConnectToMySQL ConnectToMySQLAsynch} {
        $mock eval [generated_proc $name $ob]
    }
    $mock eval {
        set calls {}
        proc mysqlconnect {args} {return handle}
        proc mysqluse {args} {}
        proc puts {args} {}
        namespace eval mysql {
            proc autocommit {args} {}
            proc sel {args} {return {}}
            proc exec {handle sql} {lappend ::calls $sql}
        }
        oceanbasecommon::configure 120
    }
} -body {
    $mock eval {
        ConnectToMySQL host 2881 null {} root@tenant password tpcc
        ConnectToMySQLAsynch host 2881 null {} root@tenant password tpcc client false
        set calls
    }
} -cleanup {
    interp delete $mock
} -result {{SET SESSION ob_query_timeout = 120000000} {SET SESSION ob_query_timeout = 120000000}}

test tproch-optimized-build {Real TPROC-H generation injects OB layout only when selected} -setup {
    set saved_ob $::configoceanbase
    set had_dialog [llength [info commands tk_messageBox]]
    if {$had_dialog} {rename tk_messageBox saved_h_dialog}
    proc tk_messageBox {args} {return yes}
    dbset db ob
    dbset bm TPROC-H
} -body {
    dict set ::configoceanbase tpch ob_tpch_optimized_schema true
    dict set ::configoceanbase tpch ob_tpch_partition_count 12
    oceanbase::mysql::generate tpch build
    set optimized $::_ED(package)
    dict set ::configoceanbase tpch ob_tpch_optimized_schema false
    oceanbase::mysql::generate tpch build
    list [info complete $optimized] \
        [expr {[string first {CreateOceanBaseHTables $mysql_handler $db 12} $optimized] >= 0}] \
        [expr {[string first {proc CreateOceanBaseHTables} $::_ED(package)] == -1}]
} -cleanup {
    set ::configoceanbase $saved_ob
    rename tk_messageBox {}
    if {$had_dialog} {rename saved_h_dialog tk_messageBox}
} -result {1 1 1}

set failed $::tcltest::numTests(Failed)
cleanupTests
exit [expr {$failed > 0}]
