# OBCI uses OCI APIs over the OceanBase protocol. In particular, Oratcl's
# first-@ connection parser cannot accept user@tenant as a username; OBCI's
# TNS OB_USER_EXTRA_INFO field carries that suffix instead.
namespace eval oceanbaseoraclecommon {
    variable driver_library {}
    variable tns_file {}
    variable connection_options {}
    variable query_timeout 120

    proc component {value label {empty false}} {
        if {(!$empty && $value eq "") || [regexp {[()=\s\x00]} $value]} {
            error "Invalid OceanBase Oracle $label"
        }
        return $value
    }

    proc tns {host port tenant cluster service users} {
        component $host host
        if {![string is integer -strict $port] || $port < 1 || $port > 65535} {error "Invalid OceanBase Oracle port"}
        foreach {value label} [list $tenant tenant $cluster cluster] {
            component $value $label true
            if {[regexp {[@#]} $value]} {error "Use separate OceanBase tenant and cluster fields"}
        }
        if {$cluster ne "" && $tenant eq ""} {error "OceanBase tenant is required with a cluster"}
        component $service {service name} true
        set suffix {}
        if {$tenant ne ""} {append suffix @$tenant}
        if {$cluster ne ""} {append suffix #$cluster}
        set result {}
        foreach user [lsort -unique $users] {
            # These are also schema identifiers, not already-qualified logins.
            if {![regexp {^[A-Za-z][A-Za-z0-9_$#]*$} $user]} {error "Invalid OceanBase Oracle user: use an unquoted schema name"}
            set sid [expr {$service eq "" ? $user : $service}]
            append result "hdb_ob_[string tolower $user] = (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=$host)(PORT=$port))(CONNECT_DATA=(SERVICE_NAME=$sid)"
            if {$suffix ne ""} {append result "(OB_MODE=1)(OB_USER_EXTRA_INFO=$suffix)"}
            append result "))\n"
        }
        return $result
    }

    proc load_driver {library} {
        variable driver_library
        set library [file normalize $library]
        if {![file isfile $library] || ![file readable $library]} {
            error "OBCI library is not readable: $library. Install OBCI and libobclient and set their library directory in LD_LIBRARY_PATH before starting HammerDB."
        }
        if {[package provide Oratcl] ne "" && $driver_library ne $library} {
            error "Oratcl is already loaded with another client. Start a separate HammerDB process for OceanBase Oracle mode."
        }
        set ::env(ORACLE_LIBRARY) $library
        # Allow an isolated corrected package without replacing the package
        # bundled in HammerDB (including a zipfs/starpack installation).
        if {[package provide Oratcl] eq "" && [info exists ::env(OBCI_ORATCL_LIBRARY)]} {
            set corrected [file normalize $::env(OBCI_ORATCL_LIBRARY)]
            if {![file isfile $corrected] || ![file readable $corrected]} {error "Corrected Oratcl library is not readable: $corrected"}
            load $corrected Oratcl
        }
        set version [package require Oratcl]
        if {[package provide OratclOCI32] eq ""} {
            error "OceanBase Oracle mode requires the OCI-width-corrected Oratcl build. See scripts/tcl/oceanbase/oracle/build-oratcl.sh; the stock Tcl 9 array-bind callback is incompatible with OBCI."
        }
        set driver_library $library
        return $version
    }

    proc configure {settings {timeout 120}} {
        variable connection_options
        variable tns_file
        variable query_timeout
        if {![string is integer -strict $timeout] || $timeout < 1 || $timeout > 86400} {error "Invalid OceanBase Oracle query timeout"}
        set query_timeout $timeout
        set text [tns {*}[lrange $settings 1 end]]
        if {$connection_options ne "" && $connection_options ne $settings} {
            error "OceanBase Oracle connection settings changed after driver initialization; start a new HammerDB process"
        }
        if {$tns_file eq ""} {
            set channel [file tempfile tns_file [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : [pwd]}] hdb-obci-]]
            try {puts -nonewline $channel $text} finally {close $channel}
            if {$::tcl_platform(platform) ne "windows"} {file attributes $tns_file -permissions 0600}
        }
        set ::env(OBCI_TNS_FILE) $tns_file
        try {
            set result [load_driver [lindex $settings 0]]
        } on error {message options} {
            # A retry after fixing a missing library must not reuse an old
            # tenant descriptor if the user has also edited the connection.
            catch {file delete $tns_file}
            set tns_file {}
            unset -nocomplain ::env(OBCI_TNS_FILE)
            return -options $options $message
        }
        set connection_options $settings
        return $result
    }

    proc connect {user password} {
        if {[string first @ $password] >= 0} {
            error "This Oratcl build cannot encode @ in a password; use an account with a different password"
        }
        if {![regexp {^[A-Za-z][A-Za-z0-9_$#]*$} $user]} {error "Invalid OceanBase Oracle user"}
        variable query_timeout
        set lda [oralogon "$user/$password@hdb_ob_[string tolower $user]"]
        set cursor [oraopen $lda]
        try {
            orasql $cursor "SET SESSION ob_query_timeout=[expr {wide($query_timeout)*1000000}]"
        } on error {message options} {
            catch {oralogoff $lda}
            return -options $options $message
        } finally {catch {oraclose $cursor}}
        return $lda
    }

    proc logon {connection} {
        # Native Oracle generators build user/password@instance. Keep the
        # actual tenant suffix in the TNS descriptor, not in that string.
        set slash [string first / $connection]
        set at [string first @ $connection]
        if {$slash < 1 || $at <= $slash} {error "Invalid generated OceanBase Oracle connection"}
        return [connect [string range $connection 0 [expr {$slash-1}]] [string range $connection [expr {$slash+1}] [expr {$at-1}]]]
    }

    proc rows {cursor sql} {
        orasql $cursor $sql
        set rows {}
        while {1} {
            orafetch $cursor -datavariable row
            set code [oramsg $cursor rc]
            if {$code == 1403} {break}
            if {$code != 0} {error "OceanBase Oracle fetch failed: [oramsg $cursor all]"}
            lappend rows $row
        }
        return $rows
    }

    proc exec_insert {cursor} {
        set result [oraexec $cursor]
        if {[oramsg $cursor rows] == 0} {
            error "OBCI schema insert reported success but inserted no rows; check array bindings"
        }
        return $result
    }

    proc create_user {lda user password} {
        if {![regexp {^[A-Za-z][A-Za-z0-9_$#]*$} $user] || [string toupper $user] in {SYS SYSTEM PUBLIC LBACSYS ORAAUDITOR}} {
            error "Choose a separate OceanBase Oracle benchmark user"
        }
        set cursor [oraopen $lda]
        try {
            set name [string toupper $user]
            set existing [rows $cursor "SELECT USERNAME FROM DBA_USERS WHERE USERNAME='$name'"]
            if {[llength $existing]} {
                set count [lindex [rows $cursor "SELECT COUNT(*) FROM DBA_TABLES WHERE OWNER='$name'"] 0 0]
                if {$count != 0} {error "Benchmark user $user already has tables; choose a new user or explicitly delete its schema"}
            } else {
                set escaped [string map [list \" \"\"] $password]
                orasql $cursor "CREATE USER $user IDENTIFIED BY \"$escaped\""
            }
            orasql $cursor "GRANT CONNECT, RESOURCE, CREATE VIEW TO $user"
        } finally {oraclose $cursor}
    }

    proc transaction_count {cursor} {
        set values [rows $cursor {SELECT NAME,SUM(VALUE) FROM GV$SYSSTAT
            WHERE NAME IN ('trans commit count','trans rollback count') GROUP BY NAME}]
        package require oceanbasecommon
        return [::oceanbasecommon::parse_transaction_count $values]
    }

    proc wait_minutes {minutes} {
        set end [expr {[clock milliseconds] + wide($minutes)*60000}]
        while {[clock milliseconds] < $end} {
            if {[tsv::get application abort]} {return false}
            after [expr {min(1000, $end-[clock milliseconds])}]
        }
        return [expr {![tsv::get application abort]}]
    }

    proc monitor {connection rampup duration users mode} {
        if {$mode ni {Local Primary}} {puts "Replica mode: monitoring runs on the primary client"; return}
        set lda [logon $connection]
        set cursor [oraopen $lda]
        try {
            puts "Beginning rampup time of $rampup minutes"
            if {![wait_minutes $rampup]} {return}
            set start_trans [transaction_count $cursor]
            set start_nopm [lindex [rows $cursor {SELECT SUM(D_NEXT_O_ID) FROM DISTRICT}] 0 0]
            set started [clock milliseconds]
            puts "Timing test period of $duration minutes"
            if {![wait_minutes $duration]} {return}
            set end_trans [transaction_count $cursor]
            set end_nopm [lindex [rows $cursor {SELECT SUM(D_NEXT_O_ID) FROM DISTRICT}] 0 0]
            set elapsed [expr {([clock milliseconds]-$started)/60000.0}]
            set nopm [expr {wide(round(($end_nopm-$start_nopm)/$elapsed))}]
            set tpm [expr {wide(round(($end_trans-$start_trans)/$elapsed))}]
            if {$nopm < 0 || $tpm < 0} {error "OceanBase Oracle counters reset during measurement"}
            puts "[expr {$users-1}] Active Virtual Users configured"
            puts [testresult $nopm $tpm OceanBase]
        } finally {
            tsv::set application abort 1
            catch {oraclose $cursor}
            catch {oralogoff $lda}
        }
    }
}
package provide oceanbaseoraclecommon 1.0
