# Opt-in live tests using a disposable Oracle business schema, never sys tenant.
# Supply HDB_OB_ORACLE_{HOST,PORT,USER,PASSWORD,CA,WRONG_CA} in the environment.
# Only the unique objects created below are removed; credentials are not logged.
set argv {}
package require tcltest 2
namespace import ::tcltest::*
foreach key {HOST PORT USER PASSWORD CA WRONG_CA} {
    if {![info exists ::env(HDB_OB_ORACLE_$key)]} {
        puts "SKIP live Oracle driver tests: HDB_OB_ORACLE_$key is required"
        exit 0
    }
}
package require oceanbaseoraclecommon
set user $::env(HDB_OB_ORACLE_USER)
set password $::env(HDB_OB_ORACLE_PASSWORD)
set settings [dict create host $::env(HDB_OB_ORACLE_HOST) port $::env(HDB_OB_ORACLE_PORT) tenant {} cluster {} users [list $user]]
set ssl [list -ssl true -sslca $::env(HDB_OB_ORACLE_CA)]
oceanbaseoraclecommon::configure $settings 120 $ssl
set connection [oceanbaseoraclecommon::connect $user $password]
set cursor [oceanbaseoracledriver::oraopen $connection]
set suffix [format %x [clock microseconds]]
set procedure HDB_LIB_$suffix
set table HDB_TX_$suffix
set created {}
try {
    test oracle-driver-tls {The configured CA establishes an encrypted Oracle connection} -body {
        set info [$connection info]
        list [dict get $info oracle_mode] [expr {[dict get $info cipher] ne {}}]
    } -result {1 1}
    test oracle-driver-wrong-ca {A valid unrelated CA is rejected by libobclient, not by preflight} -body {
        oceanbaseoraclecommon::configure $settings 120 [list -ssl true -sslca $::env(HDB_OB_ORACLE_WRONG_CA)]
        set failed [catch {oceanbaseoraclecommon::connect $user $password} message options]
        list $failed [dict get $options -errorcode]
    } -cleanup {oceanbaseoraclecommon::configure $settings 120 $ssl} -result {1 {OBCLIENT 2026}}
    test oracle-driver-identity {The connection targets the requested business user} -body {
        oceanbaseoraclecommon::rows $cursor {SELECT USER FROM DUAL}
    } -result [list [list [string toupper $user]]]
    test oracle-driver-date-null-unicode {Values stay bound, including duplicate names and quoted colon literals} -body {
        oceanbaseoracledriver::oraparse $cursor {SELECT TO_CHAR(TO_DATE(:date,'YYYYMMDDHH24MISS'),'YYYY-MM-DD HH24:MI:SS'),NVL(:empty,7),:text,:text,':ignored' FROM DUAL}
        oceanbaseoracledriver::orabind $cursor :date 20261027123456 :empty {} :text {测试 'text' 😀}
        oceanbaseoracledriver::oraexec $cursor
        oceanbaseoracledriver::orafetch $cursor -datavariable row
        set row
    } -result {{2026-10-27 12:34:56} 7 {测试 'text' 😀} {测试 'text' 😀} :ignored}
    # Oracle DATE text follows NLS_DATE_FORMAT. Set it explicitly here to check
    # the complete timestamp; the production workload retains native NLS setup.
    oceanbaseoracledriver::orasql $cursor {ALTER SESSION SET NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS'}
    oceanbaseoracledriver::orasql $cursor "CREATE PROCEDURE $procedure (p_in IN NUMBER,p_io IN OUT VARCHAR2,p_out OUT NUMBER,p_date OUT DATE) AS BEGIN IF p_in<0 THEN RAISE_APPLICATION_ERROR(-20001,'HDB expected'); END IF; p_io:=p_io||'_ok'; p_out:=p_in+7; p_date:=TO_DATE('20261027123456','YYYYMMDDHH24MISS'); END;"
    lappend created procedure
    test oracle-driver-out {Oracle IN, OUT, INOUT and DATE outputs use native prepared execution} -body {
        oceanbaseoracledriver::oraparse $cursor "BEGIN ${procedure}(:input,:io,:output,:date); END;"
        oceanbaseoracledriver::orabind $cursor :input 42 :io seed :output {} :date {}
        oceanbaseoracledriver::oraexec $cursor
        oceanbaseoracledriver::orafetch $cursor -datavariable row
        list [lrange $row 0 1] [lindex $row 2]
    } -result {{seed_ok 49} {2026-10-27 12:34:56}}
    test oracle-driver-reuse {The same prepared statement survives an Oracle application exception} -body {
        oceanbaseoracledriver::orabind $cursor :input -1 :io seed :output {} :date {}
        catch {oceanbaseoracledriver::oraexec $cursor} message options
        set code [dict get $options -errorcode]
        oceanbaseoracledriver::orabind $cursor :input 17 :io recovery :output {} :date {}
        oceanbaseoracledriver::oraexec $cursor
        oceanbaseoracledriver::orafetch $cursor -datavariable row
        list $code [lrange $row 0 1]
    } -result {{OBCLIENT 20001} {recovery_ok 24}}
    test oracle-driver-large-out {Long output values are fetched completely instead of being truncated} -body {
        set long [string repeat x 12000]
        oceanbaseoracledriver::orabind $cursor :input 1 :io $long :output {} :date {}
        oceanbaseoracledriver::oraexec $cursor
        oceanbaseoracledriver::orafetch $cursor -datavariable row
        list [expr {[lindex $row 0] eq "${long}_ok"}] [lindex $row 1]
    } -result {1 8}
    oceanbaseoracledriver::orasql $cursor "CREATE TABLE $table (ID NUMBER PRIMARY KEY)"
    lappend created table
    test oracle-driver-rollback {The original manual commit boundary is honored} -body {
        oceanbaseoracledriver::orasql $cursor "INSERT INTO $table VALUES (1)"
        oceanbaseoracledriver::oraroll $connection
        oceanbaseoraclecommon::rows $cursor "SELECT COUNT(*) FROM $table"
    } -result 0
    test oracle-driver-commit {A committed row is visible from an independent connection} -body {
        oceanbaseoracledriver::orasql $cursor "INSERT INTO $table VALUES (1)"
        oceanbaseoracledriver::oracommit $connection
        set other [oceanbaseoraclecommon::connect $user $password]
        set second [oceanbaseoracledriver::oraopen $other]
        try {oceanbaseoraclecommon::rows $second "SELECT COUNT(*) FROM $table"} finally {oceanbaseoracledriver::oralogoff $other}
    } -result 1
    test oracle-driver-close-cursors {Closing a connection also releases its unfinished streaming cursors} -body {
        set other [oceanbaseoraclecommon::connect $user $password]
        set second [oceanbaseoracledriver::oraopen $other]
        oceanbaseoracledriver::orasql $second {SELECT LEVEL FROM DUAL CONNECT BY LEVEL<=100}
        oceanbaseoracledriver::oralogoff $other
        list [llength [info commands $other]] [llength [info commands $second]] \
            [dict exists $::oceanbaseoracledriver::cursors $second]
    } -result {0 0 0}
    test oracle-driver-interpreter-cleanup {Interpreter deletion releases open connections and cursors safely} -body {
        set child [interp create]
        try {
            $child eval [list set auto_path $::auto_path]
            $child eval {package require oboracle}
            set options [dict merge $ssl [dict create -host $::env(HDB_OB_ORACLE_HOST) \
                -port $::env(HDB_OB_ORACLE_PORT) -user $user -password $password]]
            set other [$child eval [list ::oboracle::connect $options]]
            set second [$child eval [list $other open]]
            $child eval [list $second query {SELECT LEVEL FROM DUAL CONNECT BY LEVEL<=100}]
        } finally {interp delete $child}
        oceanbaseoraclecommon::rows $cursor {SELECT 1 FROM DUAL}
    } -result 1
} finally {
    catch {oceanbaseoracledriver::oraroll $connection}
    if {"table" in $created} {oceanbaseoracledriver::orasql $cursor "DROP TABLE $table PURGE"}
    if {"procedure" in $created} {oceanbaseoracledriver::orasql $cursor "DROP PROCEDURE $procedure"}
    oceanbaseoracledriver::oralogoff $connection
}
set failed $::tcltest::numTests(Failed)
cleanupTests
exit [expr {$failed > 0}]
