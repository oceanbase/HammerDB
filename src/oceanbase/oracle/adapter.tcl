# Oracle tenant parameters and SQL are independent of the MySQL backend.
if {[catch {package require oceanbaseoraclecommon}]} {
    source [file join [file dirname [info script]] .. .. .. modules oceanbaseoraclecommon-1.0.tm]
}
if {[catch {package require oceanbaseoracleschema}]} {
    source [file join [file dirname [info script]] .. .. .. modules oceanbaseoracleschema-1.0.tm]
}
source [file join [file dirname [info script]] options.tcl]
source [file join [file dirname [info script]] runtime.tcl]
namespace eval oceanbase::oracle {
    proc config {configuration} {return [::oceanbaseconfig::oracle_options $configuration]}

    proc driver_settings {configuration} {
        set native [config $configuration]
        set c [dict get $native connection]
        set timeout [dict get $c ob_query_timeout]
        if {![string is integer -strict $timeout] || $timeout < 1 || $timeout > 86400} {error "OceanBase query timeout must be 1 to 86400 seconds"}
        set o $c
        return [list [dict get $o obci_library] [dict get $c ob_host] [dict get $c ob_port] \
            [dict get $c ob_tenant] [dict get $c ob_cluster] [dict get $o instance] \
            [list [dict get $o system_user] [dict get $native tpcc tpcc_user] [dict get $native tpch tpch_user]]]
    }

    proc connection_setup {configuration {pool false}} {
        set native [config $configuration]
        set command [list ::oceanbaseoraclecommon::configure [driver_settings $configuration] [dict get $native connection ob_query_timeout]]
        if {$pool} {
            set command [list ::oceanbaseoraclecommon::configure_pool [driver_settings $configuration] \
                [dict get $native connection ob_query_timeout] [dict get $native tpcc tpcc_user] \
                [::oceanbase::mysql::decode_password [dict get $native tpcc tpcc_pass]]]
        }
        lappend command [::oceanbaseoraclecommon::ssl_setting [dict get $native connection]]
        return "package require oceanbaseoraclecommon\n$command\n"
    }

    proc validate {configuration} {
        set native [config $configuration]
        ::oceanbaseoraclecommon::tns {*}[lrange [driver_settings $configuration] 1 end]
        foreach group {tpcc tpch} {
            if {[string toupper [dict get $native $group ${group}_user]] in {SYS SYSTEM PUBLIC LBACSYS ORAAUDITOR}} {
                error "Choose a separate OceanBase Oracle benchmark user"
            }
        }
        foreach {group key minimum maximum} {
            tpcc count_ware 1 100000 tpcc num_vu 1 512
            tpcc partition_count 1 8192 tpch partition_count 1 8192
            tpcc total_iterations 1 2147483647 tpcc rampup 0 2147483647 tpcc duration 1 2147483647
            tpcc async_client 1 2147483647 tpcc async_delay 0 2147483647
            tpch num_tpch_threads 1 512 tpch total_querysets 1 2147483647
            tpch degree_of_parallel 1 1024 tpch update_sets 1 2147483647 tpch trickle_refresh 0 2147483647
        } {
            set value [dict get $native $group $key]
            if {![string is integer -strict $value] || $value < $minimum || $value > $maximum} {error "$key must be an integer from $minimum to $maximum"}
        }
        if {[dict get $native tpcc num_vu] > [dict get $native tpcc count_ware]} {error "Build virtual users cannot exceed warehouses"}
        if {[dict get $native tpcc ora_driver] ni {test timed}} {error "Driver must be test or timed"}
        if {[dict get $native tpcc ora_driver] eq "test"} {
            foreach key {allwarehouse async_scale} {
                if {[dict get $native tpcc $key] eq "true"} {error "$key requires the Timed Driver Script"}
            }
        }
        if {[dict get $native tpcc async_scale] eq "true"} {dict set native tpcc keyandthink true}
        foreach key {partition hash_clusters tpcc_tt_compat checkpoint} {
            if {[dict get $native tpcc $key] ne "false"} {error "OceanBase Oracle mode does not support $key"}
        }
        if {[dict get $native tpch tpch_tt_compat] ne "false"} {error "OceanBase Oracle mode does not support TimesTen"}
        if {[dict get $native tpch cloud_query] ne "false"} {error "OceanBase Oracle mode uses the standard TPROC-H query set; disable cloud_query"}
        if {[dict get $native tpch scale_fact] ni {1 10 30 100 300 1000 3000 10000 30000 100000}} {error "Unsupported TPROC-H scale factor"}
        foreach group {connection tpcc tpch} {
            dict for {key value} [dict get $native $group] {
                if {$key in {ob_ssl distributed_schema raiseerror keyandthink checkpoint partition hash_clusters tpcc_tt_compat allwarehouse ora_timeprofile async_scale async_verbose connect_pool tpch_tt_compat raise_query_error verbose refresh_on refresh_verbose cloud_query} && $value ni {true false}} {error "$key must be true or false"}
                if {[string match *pass* $key] && [string first @ [::oceanbase::mysql::decode_password $value]] >= 0} {error "This Oratcl build cannot encode @ in a password; use an account with a different password"}
            }
        }
        return $native
    }

    proc options {group option} {::oceanbase::mysql::show_options $group $option}
    proc set_option {group key value} {
        global configoceanbase
        set native [config $configoceanbase]
        set mapped $key
        if {[string match ob_* $key] && $group ne "connection"} {
            set mapped [string range $key 3 end]
            if {$group eq "tpcc"} {
                set aliases {user tpcc_user pass tpcc_pass driver ora_driver timeprofile ora_timeprofile}
                if {[dict exists $aliases $mapped]} {set mapped [dict get $aliases $mapped]}
            } elseif {$group eq "tpch"} {
                set aliases {tpch_optimized_schema distributed_schema tpch_partition_count partition_count}
                if {[dict exists $aliases $mapped]} {set mapped [dict get $aliases $mapped]}
            }
        }
        if {![dict exists $native $group $mapped]} {error "Unknown OceanBase Oracle option: $group $key"}
        if {[string match *pass* $mapped]} {set value [quotemeta $value]}
        dict set native $group $mapped $value
        set updated $configoceanbase
        dict set updated connection ob_oracle_options $native
        validate $updated
        ::oceanbaseconfig::save $updated
        set configoceanbase $updated
        if {$mapped eq "ora_driver" && [llength [info commands ::clearscript]]} {clearscript}
        puts "Updated OceanBase Oracle option $group:$mapped"
    }
    proc counter_options {bm} {options [expr {$bm eq "TPC-C" ? "tpcc" : "tpch"}] counter}
    proc with_config {command} {
        global configoracle configoceanbase
        set saved $configoracle
        set saved_ob $configoceanbase
        set configoracle [validate $configoceanbase]
        dict set configoracle connection rac 1
        set configoceanbase [::oceanbase::active_config $configoceanbase]
        try {return [uplevel 1 [list $command]]} finally {set configoracle $saved; set configoceanbase $saved_ob}
    }

    proc generate {workload action} {
        global configoceanbase _ED
        set commands {tpcc {build build_oratpcc test loadoratpcc timed loadtimedoratpcc check check_oratpcc delete delete_oratpcc}
            tpch {build build_oratpch test loadoratpch check check_oratpch delete delete_oratpch}}
        if {![dict exists $commands $workload $action]} {error "Unsupported OceanBase Oracle operation: $workload $action"}
        with_config [dict get $commands $workload $action]
        set graphical [info exists ::tk_version]
        if {$graphical} {ed_edit_commit}
        if {[string length [string trim $_ED(package)]]} {
            set _ED(package) [rewrite $_ED(package) $configoceanbase $workload $action]
            if {$graphical} {
                .ed_mainFrame.mainwin.textFrame.left.text fastdelete 1.0 end
                .ed_mainFrame.mainwin.textFrame.left.text fastinsert end $_ED(package)
            }
            set _ED(packagekeyname) "OceanBase Oracle tenant"
        }
    }
    proc counter {bm interval masterthread} {
        global configoceanbase
        set body [info body ::tcount_ora]
        set native [config $configoceanbase]
        set setup [connection_setup $configoceanbase [expr {$bm eq "TPC-C" && [dict get $native tpcc connect_pool] eq "true"}]]
        # The parent installs module paths before invoking read_more.
        set marker {set timeout 0}
        if {[string first $marker $body] < 0} {error "OceanBase Oracle adapter: missing native counter thread"}
        set c [dict get $native connection]
        set connection "[dict get $c system_user]/[::oceanbase::mysql::decode_password [dict get $c system_password]]@hdb_ob_sys"
        set body [string map [list $marker "$setup$marker" {oralogon } {::oceanbaseoraclecommon::logon } \
            {set connectstr $system_user/[ quotemeta $system_password ]@$instance} [list set connectstr $connection] \
            {eval [ subst {thread::send -async $tc_threadID { read_more $masterthread $library $connectstr $interval $old tce $rac $bm $tpcc_tt_compat $tpch_tt_compat }}]} \
            {thread::send -async $tc_threadID [list read_more $masterthread $library $connectstr $interval $old tce $rac $bm $tpcc_tt_compat $tpch_tt_compat]} \
            {set new $outc} {if {$bm eq "TPC-H"} {
                if {![info exists select_polls]} {set select_polls 0}
                incr select_polls
                set new [expr {[lindex $outc 0 0] - $select_polls}]
            } else {set new $outc}} \
            {select sum(value) from gv$sysstat where name = 'user commits' or name = 'user rollbacks'} \
            {select sum(value) from gv$sysstat where name in ('trans commit count','trans rollback count') having count(distinct name)=2} \
            {select sum(executions) from gv$sqlarea where command_type = 3 and parsing_user_id in (select user# from sys.user$ where type# = 1 and astatus = 0 and name not in ('SYS','SYSTEM','SYSMAN','DBSNMP'))} \
            {select sum(value) from gv$sysstat where name='sql select count' having count(*)>0}] $body]
        proc ::oceanbase::oracle::native_counter [info args ::tcount_ora] $body
        global configoracle
        set saved $configoracle
        set configoracle [validate $configoceanbase]
        dict set configoracle connection rac 1
        try {return [native_counter $bm $interval $masterthread]} finally {set configoracle $saved}
    }
}
