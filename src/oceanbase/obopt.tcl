# OceanBase category entry point. Backend names come from this registry, never
# from a user-supplied Tcl command or file path.
package require oceanbaseconfig
namespace eval oceanbase {
    variable backends [dict create mysql ::oceanbase::mysql oracle ::oceanbase::oracle]
    proc supported_modes {} {
        variable backends
        return [dict keys $backends]
    }
    proc backend {configuration} {
        variable backends
        # Configurations created before the mode field existed are MySQL tenants.
        set mode mysql
        if {[dict exists $configuration connection ob_compatibility_mode]} {
            set mode [string tolower [dict get $configuration connection ob_compatibility_mode]]
        }
        if {![dict exists $backends $mode]} {
            error "OceanBase tenant mode '$mode' is not implemented; supported modes: [join [supported_modes] {, }]"
        }
        return [dict get $backends $mode]
    }
    proc validate {configuration} {
        set implementation [backend $configuration]
        return [${implementation}::validate $configuration]
    }
    proc active_config {configuration} {
        if {[backend $configuration] ne "::oceanbase::oracle"} {return $configuration}
        set native [::oceanbaseconfig::oracle_options $configuration]
        foreach key {ob_host ob_port ob_tenant ob_cluster ob_query_timeout} {
            dict set configuration connection $key [dict get $native connection $key]
        }
        foreach {key native_key} {ob_driver ora_driver ob_count_ware count_ware ob_num_vu num_vu
            ob_allwarehouse allwarehouse ob_timeprofile ora_timeprofile ob_async_scale async_scale
            ob_rampup rampup ob_duration duration ob_total_iterations total_iterations
            ob_user tpcc_user ob_pass tpcc_pass ob_raiseerror raiseerror ob_keyandthink keyandthink
            ob_distributed_schema distributed_schema ob_partition_count partition_count ob_connect_pool connect_pool} {
            dict set configuration tpcc $key [dict get $native tpcc $native_key]
        }
        foreach {key native_key} {ob_cloud_query cloud_query ob_scale_fact scale_fact
            ob_num_tpch_threads num_tpch_threads ob_tpch_user tpch_user ob_tpch_pass tpch_pass
            ob_tpch_optimized_schema distributed_schema ob_tpch_partition_count partition_count} {
            dict set configuration tpch $key [dict get $native tpch $native_key]
        }
        return $configuration
    }
    proc dispatch {operation args} {
        global configoceanbase
        if {$operation ni {generate counter options counter_options}} {error "Unknown OceanBase operation: $operation"}
        set implementation [backend $configoceanbase]
        return [${implementation}::$operation {*}$args]
    }
}
source [file join [file dirname [info script]] mysql adapter.tcl]
source [file join [file dirname [info script]] oracle adapter.tcl]
proc configobtpcc {option} {oceanbase::dispatch options tpcc $option}
proc configobtpch {option} {oceanbase::dispatch options tpch $option}
proc countobopts {bm} {oceanbase::dispatch counter_options $bm}
