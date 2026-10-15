namespace eval oceanbase::oracle {
    proc option_fields {group option} {
        if {$group eq "tpcc"} {
            set schema {{count_ware {Warehouses} warehouse} {num_vu {Virtual Users to Build Schema} spin}
                {distributed_schema {Distributed schema} boolean} {partition_count {Partition count} entry}}
            set driver {{ora_driver {Driver Script} driver} {total_iterations {Total Transactions per User} entry}
                {raiseerror {Exit on OceanBase Error} boolean} {keyandthink {Keying and Thinking Time} boolean}
                {rampup {Minutes of Rampup Time} entry} {duration {Minutes for Test Duration} entry}
                {allwarehouse {Use All Warehouses} boolean} {ora_timeprofile {Time Profile} boolean}
                {async_scale {Asynchronous Scaling} boolean} {async_client {Asynch Clients per Virtual User} entry}
                {async_delay {Asynch Client Login Delay (ms)} entry} {async_verbose {Asynchronous Verbose} boolean}
                {connect_pool {Cluster Connect Pool} boolean}}
        } else {
            set schema {{scale_fact {Scale Factor} scale} {num_tpch_threads {Virtual Users to Build Schema} spin}
                {distributed_schema {Distributed schema} boolean} {partition_count {Partition count} entry}}
            set driver {{total_querysets {Total Query Sets per User} entry} {raise_query_error {Exit on OceanBase Error} boolean}
                {verbose {Verbose Output} boolean} {degree_of_parallel {Degree of Parallelism} entry}
                {refresh_on {Refresh Function} boolean} {update_sets {Number of Update Sets} entry}
                {trickle_refresh {Trickle Refresh Delay (ms)} entry} {refresh_verbose {Refresh Verbose} boolean}}
        }
        switch $option {
            build {return $schema}
            drive {return $driver}
            all {return [concat $schema $driver]}
        }
        error "Unknown OceanBase Oracle options: $option"
    }

    proc render_options {group option} {
        set frame .oboptions.tabs.connection
        set row 0
        foreach field {{ob_host {OceanBase Host} entry}
                {ob_port {OceanBase Port} entry} {ob_tenant {Tenant Name} entry} {ob_cluster {Cluster Name} entry}
                {ob_query_timeout {Query Timeout (secs)} entry}} {
            lassign $field key label kind
            ::oceanbase::mysql::option_row $frame [incr row] oracle_connection $key $label $kind
        }
        foreach field {{instance {OBCI Service Name (optional)} entry} {obci_library {OBCI Library} entry}
                {system_user {System User} entry} {system_password {System User Password} password}} {
            lassign $field key label kind
            ::oceanbase::mysql::option_row $frame [incr row] oracle_connection $key $label $kind
        }
        foreach field [expr {$group eq "tpcc" ?
                {{tpcc_user {TPROC-C User} entry} {tpcc_pass {TPROC-C User Password} password}} :
                {{tpch_user {TPROC-H User} entry} {tpch_pass {TPROC-H User Password} password}}}] {
            lassign $field key label kind
            ::oceanbase::mysql::option_row $frame [incr row] oracle_$group $key $label $kind
        }
        grid columnconfigure $frame 1 -weight 1
        set frame .oboptions.tabs.settings.fields
        ttk::frame $frame -padding 4
        pack $frame -fill both -expand 1
        set row 0
        if {$option eq "counter"} {
            foreach field [::oceanbase::mysql::option_fields $group counter] {
                lassign $field key label kind
                if {$kind eq "boolean"} {set kind flag}
                ::oceanbase::mysql::option_row $frame [incr row] counter $key $label $kind
            }
        } else {
            foreach field [option_fields $group $option] {
                lassign $field key label kind
                ::oceanbase::mysql::option_row $frame [incr row] oracle_$group $key $label $kind
            }
        }
        if {$group eq "tpcc" && $option in {all drive}} {
            ttk::label $frame.poolhelp -text "Pool endpoints: config/connectpool/oboracpool.xml" -wraplength 440
            grid $frame.poolhelp -row [incr row] -column 0 -columnspan 2 -sticky w -padx 5 -pady 5
        }
        grid columnconfigure $frame 1 -weight 1
        update_option_states $group $option
    }

    proc option_changed {key} {
        upvar #0 ::oceanbase::mysql::options options
        upvar #0 ::oceanbase::mysql::options_context context
        if {[lindex $context 0] eq "tpcc"} {
            if {$key eq "ora_driver" && $options(oracle_tpcc,ora_driver) eq "test"} {
                foreach key {async_scale async_verbose allwarehouse ora_timeprofile} {set options(oracle_tpcc,$key) false}
            }
            if {$key eq "async_scale" && $options(oracle_tpcc,async_scale) eq "true"} {set options(oracle_tpcc,keyandthink) true}
            if {$key eq "keyandthink" && $options(oracle_tpcc,keyandthink) eq "false"} {set options(oracle_tpcc,async_scale) false}
            if {$options(oracle_tpcc,async_scale) eq "false"} {set options(oracle_tpcc,async_verbose) false}
        } elseif {$key eq "refresh_on" && $options(oracle_tpch,refresh_on) eq "false"} {
            set options(oracle_tpch,refresh_verbose) false
        }
        update_option_states {*}$context
    }

    proc update_option_states {group option} {
        upvar #0 ::oceanbase::mysql::options options
        ::oceanbase::mysql::option_enabled partition_count $options(oracle_$group,distributed_schema)
        if {$option eq "counter"} {
            foreach key {tc_unique_log_name tc_log_timestamps} {::oceanbase::mysql::option_enabled $key $options(counter,tc_log_to_temp)}
        } elseif {$group eq "tpcc"} {
            set timed [expr {$options(oracle_tpcc,ora_driver) eq "timed"}]
            foreach key {rampup duration allwarehouse ora_timeprofile async_scale} {::oceanbase::mysql::option_enabled $key $timed}
            foreach key {async_client async_delay async_verbose} {::oceanbase::mysql::option_enabled $key [expr {$timed && $options(oracle_tpcc,async_scale) eq "true"}]}
            ::oceanbase::mysql::option_enabled keyandthink true
        } else {
            foreach key {update_sets trickle_refresh refresh_verbose} {::oceanbase::mysql::option_enabled $key $options(oracle_tpch,refresh_on)}
        }
    }
}
