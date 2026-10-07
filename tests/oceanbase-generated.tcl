# Run inside HammerDB CLI: hammerdbcli auto tests/oceanbase-generated.tcl
set argv {}
set root [file dirname [file dirname [file normalize [info script]]]]
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

test schema-passwords {Generated C/H build/check/delete entries preserve empty and spaced passwords} -setup {
    set saved_ob $::configoceanbase
    set had_dialog [llength [info commands tk_messageBox]]
    if {$had_dialog} {rename tk_messageBox saved_password_dialog}
    proc tk_messageBox {args} {return yes}
} -body {
    set results {}
    foreach workload {tpcc tpch} {
        foreach action {build check delete} {
            foreach password [list {} {two words} {a;[error unsafe]$x} {double"quote}] {
                set key [expr {$workload eq "tpcc" ? "ob_pass" : "ob_tpch_pass"}]
                dict set ::configoceanbase $workload $key [quotemeta $password]
                oceanbase::mysql::generate $workload $action
                set entry [dict get [dict create build do_$workload check check_$workload delete drop_schema] $action]
                set start [string last "\n$entry " $::_ED(package)]
                set call [string range $::_ED(package) [expr {$start + 1}] end]
                set worker [interp create]
                $worker eval [list proc $entry {args} {return $args}]
                set args [$worker eval $call]
                set password_index [expr {$action eq "build" ? 6 : 5}]
                lappend results [expr {[lindex $args $password_index] eq $password}]
                interp delete $worker
            }
        }
    }
    expr {0 ni $results && [llength $results] == 24}
} -cleanup {
    set ::configoceanbase $saved_ob
    rename tk_messageBox {}
    if {$had_dialog} {rename saved_password_dialog tk_messageBox}
} -result 1


test workload-passwords {Real diset and C test/timed/H query drivers preserve password bytes} -setup {
    set saved_ob $::configoceanbase
    set saved_db $::rdbms
} -body {
    set results {}
    dbset db ob
    foreach {workload action} {tpcc test tpcc timed tpch test} {
        foreach password [list {} {two words} {a;[error unsafe]$x} {double"quote} {back\nslash} {true} {false}] {
            set key [expr {$workload eq "tpcc" ? "ob_pass" : "ob_tpch_pass"}]
            diset $workload $key $password
            oceanbase::mysql::generate $workload $action
            set found 0
            foreach line [split $::_ED(package) \n] {
                if {[string match {set password *} $line]} {
                    set worker [interp create]
                    $worker eval $line
                    lappend results [expr {[$worker eval {set password}] eq $password}]
                    interp delete $worker
                    incr found
                }
            }
            if {!$found} {error "Missing password header"}
        }
    }
    expr {0 ni $results && [llength $results] >= 21}
} -cleanup {
    set ::configoceanbase $saved_ob
    set ::rdbms $saved_db
} -result 1

test counter-diset-passwords {Counter command after real diset contains decoded C and H credentials} -setup {
    set saved_ob $::configoceanbase
    set worker [interp create]
    $worker eval {
        namespace eval thread {
            proc create {script} {return counter-worker}
            proc send {args} {
                set command [lindex $args end]
                if {[lindex $command 0] eq "read_more"} {set ::counter_command $command}
            }
        }
        set dbdict {mysql {library mysqltcl}}
        set mysql_ssl_options {}
        set quote_passwords true
    }
    foreach file {src/generic/gentccmn.tcl src/oceanbase/mysql/runtime.tcl src/oceanbase/mysql/counter.tcl} {
        $worker eval [list source [file join $root $file]]
    }
} -body {
    set results {}
    dbset db ob
    foreach password [list {} {two words} {a$b} {a;[error unsafe]$x} {double"quote} {back\nslash}] {
        diset tpcc ob_pass $password
        diset tpch ob_tpch_pass $password
        $worker eval [list set configmysql [oceanbase::mysql::config $::configoceanbase]]
        $worker eval {tcount_oceanbase_mysql TPC-C 10 main 120}
        set command [$worker eval {set counter_command}]
        lappend results [expr {[lindex $command 8] eq $password && [lindex $command 10] eq $password}]
    }
    set results
} -cleanup {
    interp delete $worker
    set ::configoceanbase $saved_ob
} -result {1 1 1 1 1 1}

set failed $::tcltest::numTests(Failed)
cleanupTests
exit [expr {$failed > 0}]
