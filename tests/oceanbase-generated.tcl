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
test mysql-after-ob {A MySQL script explicitly resets the runtime database mode} -body {
    dbset db mysql
    diset tpcc mysql_driver test
    loadscript
    expr {[string first {mysqlcommon::configure MySQL 0} $::_ED(package)] >= 0 && [string first {mysqlcommon::configure OceanBase} $::_ED(package)] < 0}
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

set failed $::tcltest::numTests(Failed)
cleanupTests
exit [expr {$failed > 0}]
