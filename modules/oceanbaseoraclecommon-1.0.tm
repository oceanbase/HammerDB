# OBCI uses OCI APIs over the OceanBase protocol. In particular, Oratcl's
# first-@ connection parser cannot accept user@tenant as a username; OBCI's
# TNS OB_USER_EXTRA_INFO field carries that suffix instead.
namespace eval oceanbaseoraclecommon {
    variable driver_library {}
    variable tns_file {}
    variable connection_options {}
    variable query_timeout 120
    variable allowed_aliases {}
    variable pool_configuration {}

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
        variable allowed_aliases
        set text [tns {*}[lrange $settings 1 6]]
        set aliases {}
        foreach user [lindex $settings 6] {lappend aliases hdb_ob_[string tolower $user]}
        if {[llength $settings] > 7} {
            foreach endpoint [lindex $settings 7] {
                dict with endpoint {
                    set descriptor [tns $host $port $tenant $cluster $service [list $user]]
                    append text [string map [list hdb_ob_[string tolower $user] $alias] $descriptor]
                    lappend aliases $alias
                }
            }
        }
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
        set allowed_aliases $aliases
        return $result
    }

    proc connect {user password {alias {}}} {
        if {[string first @ $password] >= 0} {
            error "This Oratcl build cannot encode @ in a password; use an account with a different password"
        }
        if {![regexp {^[A-Za-z][A-Za-z0-9_$#]*$} $user]} {error "Invalid OceanBase Oracle user"}
        variable query_timeout
        variable allowed_aliases
        if {$alias eq ""} {set alias hdb_ob_[string tolower $user]}
        if {$alias ni $allowed_aliases} {error "Unknown OceanBase Oracle connection alias"}
        set lda [oralogon "$user/$password@$alias"]
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
        set alias [string range $connection [expr {$at+1}] end]
        # Native schema builders use the future benchmark service name even
        # for the administrator login, before that schema exists. Keep the
        # configured per-user descriptor except for explicit pool routes.
        if {![string match hdb_ob_pool_c? $alias]} {set alias {}}
        return [connect [string range $connection 0 [expr {$slash-1}]] [string range $connection [expr {$slash+1}] [expr {$at-1}]] $alias]
    }

    proc pool_config {pool settings user password} {
        if {![dict exists $pool connections] || ![dict exists $pool sprocs]} {error "OceanBase Oracle pool needs connections and sprocs"}
        set endpoints {}
        set connections {}
        dict for {id values} [dict get $pool connections] {
            if {![regexp {^c[1-9]$} $id]} {error "OceanBase Oracle pool connection IDs must be c1 to c9"}
            set endpoint [dict create host [lindex $settings 1] port [lindex $settings 2] tenant [lindex $settings 3] \
                cluster [lindex $settings 4] service [lindex $settings 5] user $user alias hdb_ob_pool_$id]
            set pass $password
            foreach {key mapped} {ob_host host ob_port port ob_tenant tenant ob_cluster cluster instance service tpcc_user user} {
                if {[dict exists $values $key]} {dict set endpoint $mapped [dict get $values $key]}
            }
            if {[dict exists $values tpcc_pass]} {set pass [dict get $values tpcc_pass]}
            # Every endpoint must target the same tenant and benchmark schema.
            # Cluster Connect Pool routes transactions, not independent datasets.
            foreach key {tenant cluster user} expected [list [lindex $settings 3] [lindex $settings 4] $user] {
                if {![string equal -nocase [dict get $endpoint $key] $expected]} {error "OceanBase Oracle pool endpoints must use the same tenant, cluster and benchmark user"}
            }
            if {[string first @ $pass] >= 0} {error "This Oratcl build cannot encode @ in a pool password"}
            tns [dict get $endpoint host] [dict get $endpoint port] [dict get $endpoint tenant] [dict get $endpoint cluster] \
                [dict get $endpoint service] [list [dict get $endpoint user]]
            lappend endpoints $endpoint
            dict set connections $id [dict create tpcc_user [dict get $endpoint user] tpcc_pass $pass instance [dict get $endpoint alias]]
        }
        if {![llength $endpoints]} {error "OceanBase Oracle pool has no connections"}
        foreach procedure {neworder payment delivery stocklevel orderstatus} {
            if {![dict exists $pool sprocs $procedure connections] || ![dict exists $pool sprocs $procedure policy]} {error "Missing OceanBase Oracle pool routing for $procedure"}
            set ids [dict get $pool sprocs $procedure connections]
            if {![llength $ids]} {error "Empty OceanBase Oracle pool routing for $procedure"}
            foreach id $ids {if {![dict exists $connections $id]} {error "Unknown OceanBase Oracle pool connection $id"}}
            if {[dict get $pool sprocs $procedure policy] ni {first_named last_named random round_robin}} {error "Unknown OceanBase Oracle pool policy"}
        }
        return [list [dict replace $pool connections $connections] $endpoints]
    }

    proc configure_pool {settings timeout user password} {
        variable pool_configuration
        package require tpcccommon
        set pool [::tpcccommon::get_connect_xml obora]
        lassign [pool_config $pool $settings $user $password] pool endpoints
        configure [linsert $settings end $endpoints] $timeout
        set pool_configuration $pool
    }

    proc get_pool_config {} {
        variable pool_configuration
        if {$pool_configuration eq ""} {error "OceanBase Oracle pool was not configured"}
        return $pool_configuration
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
