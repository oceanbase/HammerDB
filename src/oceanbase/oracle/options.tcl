# Mirror the native Oracle dialogs. Backend-specific connection settings live
# on their own page, and unavailable Oracle features stay visible but disabled.
namespace eval oceanbase::oracle {
    proc option_fields {group option} {
        if {$group eq "tpcc"} {
            set schema {{tpcc_def_tab {TPROC-C Default Tablespace} entry}
                {tpcc_ol_tab {TPROC-C Order Line Tablespace} entry}
                {tpcc_def_temp {TPROC-C Temporary Tablespace} entry}
                {hash_clusters {Use Hash Clusters} boolean} {partition {Partition Tables} boolean}
                {count_ware {Number of Warehouses} warehouse} {num_vu {Virtual Users to Build Schema} spin}}
            set driver {{ora_driver {TPROC-C Driver Script} driver} {total_iterations {Total Transactions per User} entry}
                {raiseerror {Exit on Oracle Error} boolean} {keyandthink {Keying and Thinking Time} boolean}
                {checkpoint {Checkpoint when complete} boolean}
                {rampup {Minutes of Rampup Time} entry} {duration {Minutes for Test Duration} entry}
                {allwarehouse {Use All Warehouses} boolean} {ora_timeprofile {Time Profile} boolean}
                {async_scale {Asynchronous Scaling} boolean} {async_client {Asynch Clients per Virtual User} entry}
                {async_delay {Asynch Client Login Delay} entry} {async_verbose {Asynchronous Verbose} boolean}}
        } else {
            set schema {{tpch_def_tab {TPROC-H Default Tablespace} entry}
                {tpch_def_temp {TPROC-H Temporary Tablespace} entry}
                {scale_fact {Scale Factor} scale} {num_tpch_threads {Virtual Users to Build Schema} spin}}
            set driver {{total_querysets {Total Query Sets per User} entry} {raise_query_error {Exit on Oracle Error} boolean}
                {verbose {Verbose Output} boolean} {degree_of_parallel {Degree of Parallelism} entry}
                {refresh_on {Refresh Function} boolean} {update_sets {Number of Update Sets} entry}
                {trickle_refresh {Trickle Refresh Delay(ms)} entry} {refresh_verbose {Refresh Verbose} boolean}
                {cloud_query {Cloud Analytic Queries} boolean}}
        }
        switch $option {
            build {return $schema}
            drive {return $driver}
            all {return [concat $schema $driver]}
        }
        error "Unknown OceanBase Oracle options: $option"
    }

    proc unavailable_options {group} {
        if {$group eq "tpcc"} {
            return {tpcc_def_tab tpcc_ol_tab tpcc_def_temp hash_clusters partition tpcc_tt_compat checkpoint connect_pool}
        }
        return {tpch_def_tab tpch_def_temp tpch_tt_compat}
    }

    proc option_row {frame row section key label kind} {
        upvar #0 ::oceanbase::mysql::option_widgets widgets
        if {$kind eq "scale"} {
            ttk::label $frame.l$row -text "$label :"
            set widget $frame.e$row
            ttk::frame $widget
            set index 0
            foreach value {1 10 30 100 300 1000 3000 10000 30000 100000} {
                ttk::radiobutton $widget.r$value -text $value -value $value -width [string length $value] \
                    -variable ::oceanbase::mysql::options($section,$key)
                grid $widget.r$value -row [expr {$index / 5}] -column [expr {$index % 5}] -sticky w
                incr index
            }
            set widgets($key) $widget
        } else {
            ::oceanbase::mysql::option_row $frame $row $section $key $label $kind
        }
        # Native Oracle uses compact rows and left-aligned check/radio buttons.
        grid $frame.l$row -row $row -column 0 -sticky e -padx 0 -pady 0
        grid $widgets($key) -row $row -column 1 -sticky [expr {$kind in {boolean flag driver} ? "w" : "ew"}] -padx 0 -pady 0
        if {[string match {TPROC-? *} $label] && [llength [info commands ::create_image]]} {
            $frame.l$row configure -image [create_image hdbicon icons] -compound left
        }
        if {$kind eq "driver"} {
            grid $frame.l$row -sticky ne
            pack configure $widgets($key).test $widgets($key).timed -pady 0
        }
        if {$key in {count_ware num_vu}} {
            bind $widgets($key) <KeyRelease> ::oceanbase::oracle::limit_build_users
            bind $widgets($key) <<Increment>> ::oceanbase::oracle::limit_build_users
            bind $widgets($key) <<Decrement>> ::oceanbase::oracle::limit_build_users
            $widgets($key) configure -command ::oceanbase::oracle::limit_build_users
        }
    }

    proc limit_build_users {} {
        upvar #0 ::oceanbase::mysql::options options
        if {[string is integer -strict $options(oracle_tpcc,count_ware)] &&
                [string is integer -strict $options(oracle_tpcc,num_vu)] &&
                $options(oracle_tpcc,num_vu) > $options(oracle_tpcc,count_ware)} {
            set options(oracle_tpcc,num_vu) $options(oracle_tpcc,count_ware)
        }
    }

    proc render_fields {frame row group option} {
        foreach field [option_fields $group $option] {
            lassign $field key label kind
            option_row $frame [incr row] oracle_$group $key $label $kind
        }
        return $row
    }

    proc render_options {group option} {
        set frame .oboptions.tabs.connection
        set row 0
        option_row $frame [incr row] connection ob_compatibility_mode {Tenant Mode} mode
        foreach field {{instance {Oracle Service Name} entry} {system_user {System User} entry}
                {system_password {System User Password} password}} {
            lassign $field key label kind
            option_row $frame [incr row] oracle_connection $key $label $kind
        }
        if {$option ne "counter"} {
            set workload [expr {$group eq "tpcc" ? "TPROC-C" : "TPROC-H"}]
            option_row $frame [incr row] oracle_$group ${group}_user "$workload User" entry
            option_row $frame [incr row] oracle_$group ${group}_pass "$workload User Password" password
            option_row $frame [incr row] oracle_$group ${group}_tt_compat {TimesTen Database Compatible} boolean
            if {$group eq "tpcc" && $option in {all drive}} {
                option_row $frame [incr row] oracle_tpcc connect_pool {Cluster Connect Pool} boolean
            }
        }
        grid columnconfigure $frame 1 -weight 1

        ttk::frame .oboptions.tabs.oceanbase -padding 0
        .oboptions.tabs add .oboptions.tabs.oceanbase -text OceanBase -sticky ne
        set frame .oboptions.tabs.oceanbase
        set row 0
        foreach field {{ob_host {OceanBase Host} entry} {ob_port {OceanBase Port} entry}
                {ob_tenant {Tenant Name} entry} {ob_cluster {Cluster Name} entry}
                {ob_query_timeout {Query Timeout (secs)} entry} {obci_library {OBCI Library} entry}} {
            lassign $field key label kind
            option_row $frame [incr row] oracle_connection $key $label $kind
        }
        grid columnconfigure $frame 1 -weight 1
        ttk::label $frame.help -text "Leave Oracle Service Name empty to use this host and port." -wraplength 460
        grid $frame.help -row [incr row] -column 0 -columnspan 2 -sticky w -pady 5

        set frame .oboptions.tabs.settings.fields
        ttk::frame $frame -padding 0
        pack $frame -fill both -expand 1
        set row 0
        if {$option eq "counter"} {
            foreach field [::oceanbase::mysql::option_fields $group counter] {
                lassign $field key label kind
                if {$kind eq "boolean"} {set kind flag}
                option_row $frame [incr row] counter $key $label $kind
            }
        } else {
            set heading [expr {$option eq "drive" ? "Driver Options" : "Build Options"}]
            ttk::label .oboptions.heading -text $heading -compound left
            if {[llength [info commands ::create_image]]} {
                .oboptions.heading configure -image [create_image [expr {$option eq "drive" ? "driveroptlo" : "boxes"}] icons]
            }
            pack .oboptions.heading -before .oboptions.tabs -anchor center
            pack configure .oboptions.tabs -pady 0
            if {$option in {all build}} {set row [render_fields $frame $row $group build]}
            if {$option eq "all"} {
                ttk::label $frame.drivericon
                if {[llength [info commands ::create_image]]} {$frame.drivericon configure -image [create_image driveroptlo icons]}
                ttk::label $frame.driverheading -text "Driver Options"
                grid $frame.drivericon -row [incr row] -column 0 -sticky e
                grid $frame.driverheading -row $row -column 1 -sticky w
            }
            if {$option in {all drive}} {render_fields $frame $row $group drive}
            ttk::label .oboptions.notice -text "Unavailable Oracle options are disabled; hover for details." -wraplength 480
            pack .oboptions.notice -before .oboptions.buttons -padx 5 -pady 3 -anchor w
            foreach key [unavailable_options $group] {
                ::oceanbase::mysql::option_enabled $key false
                if {[info exists ::oceanbase::mysql::option_widgets($key)] && [llength [info commands ::tooltip::tooltip]]} {
                    set widget $::oceanbase::mysql::option_widgets($key)
                    set reason "This Oracle feature is not supported by the OceanBase Oracle adapter."
                    if {[string match *tab $key] || [string match *temp $key]} {
                        set reason "The OceanBase schema builder omits Oracle tablespace and storage clauses."
                    }
                    tooltip::tooltip $widget $reason
                    tooltip::tooltip [string map {.e .l} $widget] $reason
                }
            }
        }
        foreach tab {.oboptions.tabs.connection .oboptions.tabs.settings} {
            $tab configure -padding 0
            .oboptions.tabs tab $tab -sticky ne
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
