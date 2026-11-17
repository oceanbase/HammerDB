# Oracle SQL and workloads use libobclient directly; SSL options are shared
# with the OceanBase MySQL backend. No OCI/TNS configuration is involved.
if {[catch {package require oceanbaseoracledriver}]} {
    source [file join [file dirname [info script]] oceanbaseoracledriver-1.0.tm]
}
namespace eval oceanbaseoraclecommon {
    namespace path ::oceanbaseoracledriver
    variable connection_options {}
    variable query_timeout 120
    variable endpoints {}
    variable pool_configuration {}

    proc validate_endpoint {endpoint} {
        foreach key {host tenant cluster} {
            set value [dict get $endpoint $key]
            if {($key eq "host" && $value eq "") || [regexp {[\s\x00]} $value]} {
                error "Invalid OceanBase Oracle $key"
            }
            if {$key ne "host" && [regexp {[@#]} $value]} {error "Use separate OceanBase tenant and cluster fields"}
        }
        set port [dict get $endpoint port]
        if {![string is integer -strict $port] || $port < 1 || $port > 65535} {error "Invalid OceanBase Oracle port"}
        if {[dict get $endpoint cluster] ne "" && [dict get $endpoint tenant] eq ""} {error "OceanBase tenant is required with a cluster"}
    }
    proc username {user endpoint} {
        if {![regexp {^[A-Za-z][A-Za-z0-9_$#]*$} $user]} {error "Invalid OceanBase Oracle user: use an unquoted schema name"}
        if {[dict get $endpoint tenant] ne ""} {append user @[dict get $endpoint tenant]}
        if {[dict get $endpoint cluster] ne ""} {append user #[dict get $endpoint cluster]}
        return $user
    }
    proc load_driver {} {
        if {[catch {package require oboracle 1.0} message options]} {
            return -options $options "Unable to load the OceanBase Oracle libobclient binding: $message. Build scripts/tcl/oceanbase/oracle/build-driver.sh and make the official libobclnt.so.2 available on the library path."
        }
        return [package provide oboracle]
    }
    proc ssl_setting {connection} {
        foreach key {ob_ssl ob_ssl_two_way} {
            if {[dict get $connection $key] ni {true false}} {error "$key must be true or false"}
        }
        package require oceanbasecommon
        return [::oceanbasecommon::ssl_options [dict create connection $connection]]
    }
    proc configure {settings {timeout 120} {ssl {-ssl false}}} {
        variable connection_options
        variable query_timeout
        variable endpoints
        if {![string is integer -strict $timeout] || $timeout < 1 || $timeout > 86400} {error "Invalid OceanBase Oracle query timeout"}
        validate_endpoint $settings
        set aliases {}
        foreach user [dict get $settings users] {
            username $user $settings
            dict set aliases hdb_ob_[string tolower $user] $settings
        }
        if {[dict exists $settings endpoints]} {
            foreach endpoint [dict get $settings endpoints] {
                validate_endpoint $endpoint
                username [dict get $endpoint user] $endpoint
                dict set aliases [dict get $endpoint alias] $endpoint
            }
        }
        dict size $ssl
        load_driver
        set query_timeout $timeout
        set connection_options $ssl
        set endpoints $aliases
        return [package provide oboracle]
    }
    proc connect {user password {alias {}}} {
        variable query_timeout
        variable endpoints
        variable connection_options
        if {$alias eq ""} {set alias hdb_ob_[string tolower $user]}
        if {![dict exists $endpoints $alias]} {error "Unknown OceanBase Oracle connection alias"}
        set endpoint [dict get $endpoints $alias]
        set options [dict merge [dict create -host [dict get $endpoint host] -port [dict get $endpoint port] \
            -user [username $user $endpoint] -password $password] $connection_options]
        set lda [::oboracle::connect $options]
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
        # The generators still pass user/password@alias. Split at the final @
        # so passwords containing @, / or Tcl metacharacters remain values.
        set slash [string first / $connection]
        set at [string last @ $connection]
        if {$slash < 1 || $at <= $slash} {error "Invalid generated OceanBase Oracle connection"}
        set alias [string range $connection [expr {$at+1}] end]
        if {![string match hdb_ob_pool_c? $alias]} {set alias {}}
        return [connect [string range $connection 0 [expr {$slash-1}]] [string range $connection [expr {$slash+1}] [expr {$at-1}]] $alias]
    }
    proc pool_config {pool settings user password} {
        if {![dict exists $pool connections] || ![dict exists $pool sprocs]} {error "OceanBase Oracle pool needs connections and sprocs"}
        set endpoints {}
        set connections {}
        dict for {id values} [dict get $pool connections] {
            if {![regexp {^c[1-9]$} $id]} {error "OceanBase Oracle pool connection IDs must be c1 to c9"}
            set endpoint [dict merge [dict remove $settings users endpoints] [dict create user $user alias hdb_ob_pool_$id]]
            set pass $password
            foreach {key mapped} {ob_host host ob_port port ob_tenant tenant ob_cluster cluster tpcc_user user} {
                if {[dict exists $values $key]} {dict set endpoint $mapped [dict get $values $key]}
            }
            if {[dict exists $values tpcc_pass]} {set pass [dict get $values tpcc_pass]}
            foreach key {tenant cluster user} expected [list [dict get $settings tenant] [dict get $settings cluster] $user] {
                if {![string equal -nocase [dict get $endpoint $key] $expected]} {error "OceanBase Oracle pool endpoints must use the same tenant, cluster and benchmark user"}
            }
            validate_endpoint $endpoint
            username [dict get $endpoint user] $endpoint
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
    proc configure_pool {settings timeout user password {ssl {-ssl false}}} {
        variable pool_configuration
        package require tpcccommon
        set pool [::tpcccommon::get_connect_xml obora]
        lassign [pool_config $pool $settings $user $password] pool endpoints
        configure [dict replace $settings endpoints $endpoints] $timeout $ssl
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
            error "OceanBase schema insert reported success but inserted no rows"
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
