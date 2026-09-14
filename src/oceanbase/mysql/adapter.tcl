# MySQL tenant backend. Oracle-specific options, connections and SQL belong in a separate backend.
namespace eval oceanbase::mysql {
    proc username {user tenant cluster} {
        foreach part [list $user $tenant $cluster] {
            if {[regexp {[@#\s]} $part]} {error "Use separate user, tenant and cluster fields without @, # or whitespace"}
        }
        if {$user eq "" || $tenant eq ""} {error "OceanBase user and tenant are required"}
        set login "$user@$tenant"
        if {$cluster ne ""} {append login "#$cluster"}
        return $login
    }

    proc config {config} {
        # Start with MySQL defaults, not the user's current MySQL configuration.
        set mapped [::XML::To_Dict [file join [find_config_dir] mysql.xml]]
        dict for {group values} $config {
            dict for {key value} $values {
                set mysql_key mysql_[string range $key 3 end]
                if {[dict exists $mapped $group $mysql_key]} {dict set mapped $group $mysql_key $value}
            }
        }
        set timeout [dict get $config connection ob_query_timeout]
        if {![string is integer -strict $timeout] || $timeout < 1 || $timeout > 86400} {
            error "OceanBase query timeout must be 1 to 86400 seconds"
        }
        set tenant [dict get $config connection ob_tenant]
        set cluster [dict get $config connection ob_cluster]
        foreach {group key} {tpcc user tpch tpch_user} {
            dict set mapped $group mysql_$key [username [dict get $config $group ob_$key] $tenant $cluster]
        }
        foreach {group key} {tpcc storage_engine tpch tpch_storage_engine} {
            if {[string tolower [dict get $mapped $group mysql_$key]] ne "innodb"} {
                error "OceanBase MySQL workloads require the innodb-compatible schema"
            }
        }
        # The legacy OceanBase option under MySQL prepares sys settings and uses
        # different DDL. The new category needs only the business tenant login.
        dict set mapped tpch mysql_tpch_obcompat false
        dict set mapped connection mysql_socket null
        return $mapped
    }

    proc with_config {command args} {
        global configmysql configoceanbase mysql_ssl_options
        set mapped [config $configoceanbase]
        set saved $configmysql
        set had_ssl [info exists mysql_ssl_options]
        if {$had_ssl} {set saved_ssl $mysql_ssl_options}
        set configmysql $mapped
        unset -nocomplain mysql_ssl_options
        try {
            return [uplevel #0 [list $command {*}$args]]
        } finally {
            set configmysql $saved
            if {$had_ssl} {set mysql_ssl_options $saved_ssl} else {unset -nocomplain mysql_ssl_options}
        }
    }

    proc generate {workload action} {
        set commands [dict create tpcc [dict create build build_mysqltpcc test loadmysqltpcc timed loadtimedmysqltpcc check check_mysqltpcc delete delete_mysqltpcc] tpch [dict create build build_mysqltpch test loadmysqltpch check check_mysqltpch delete delete_mysqltpch]]
        if {![dict exists $commands $workload $action]} {error "Unsupported OceanBase MySQL operation: $workload $action"}
        set command [dict get $commands $workload $action]
        global configoceanbase _ED
        with_config $command
        set graphical [info exists ::tk_version]
        if {$graphical} {ed_edit_commit}
        if {[string length $_ED(package)] > 0} {
            set timeout [dict get $configoceanbase connection ob_query_timeout]
            set _ED(package) [string map [list {mysqlcommon::configure MySQL 0} [list mysqlcommon::configure OceanBase $timeout]] $_ED(package)]
            if {$graphical} {
                .ed_mainFrame.mainwin.textFrame.left.text fastdelete 1.0 end
                .ed_mainFrame.mainwin.textFrame.left.text fastinsert end $_ED(package)
            }
            set _ED(packagekeyname) "OceanBase MySQL tenant"
        }
    }

    proc save_options {} {
        global configoceanbase
        variable options
        set updated $configoceanbase
        foreach entry [array names options] {
            lassign [split $entry ,] group key
            dict set updated $group $key $options($entry)
        }
        if {[catch {::oceanbase::validate $updated} message]} {
            tk_messageBox -parent .oboptions -icon error -message $message
            return
        }
        set configoceanbase $updated
        Dict2SQLite oceanbase $configoceanbase
        destroy .oboptions
    }

    proc options {group option} {
        global configoceanbase
        variable options
        catch {destroy .oboptions}
        array unset options
        ttk::toplevel .oboptions
        wm title .oboptions "OceanBase MySQL Tenant Options"
        wm transient .oboptions .ed_mainFrame
        ttk::notebook .oboptions.tabs
        pack .oboptions.tabs -fill both -expand 1 -padx 8 -pady 8
        set schema_keys {ob_user ob_pass ob_dbase ob_count_ware ob_num_vu ob_partition ob_storage_engine ob_tpch_user ob_tpch_pass ob_tpch_dbase ob_scale_fact ob_num_tpch_threads ob_tpch_storage_engine}
        foreach page {connection schema driver} {
            ttk::frame .oboptions.tabs.$page -padding 8
            .oboptions.tabs add .oboptions.tabs.$page -text [string totitle $page]
            set row($page) 0
        }
        dict for {section values} $configoceanbase {
            if {$section ni [list connection $group]} {continue}
            dict for {key value} $values {
                if {$section eq "connection"} {set page connection} elseif {$key in $schema_keys} {set page schema} else {set page driver}
                set frame .oboptions.tabs.$page
                set i [incr row($page)]
                set options($section,$key) $value
                set label [string totitle [string map {_ " "} [string range $key 3 end]]]
                ttk::label $frame.l$i -text $label
                if {$key eq "ob_compatibility_mode"} {
                    ttk::combobox $frame.e$i -textvariable ::oceanbase::mysql::options($section,$key) -values [::oceanbase::supported_modes] -state readonly
                } elseif {$value in {true false}} {
                    ttk::checkbutton $frame.e$i -variable ::oceanbase::mysql::options($section,$key) -onvalue true -offvalue false
                } elseif {$key eq "ob_driver"} {
                    ttk::combobox $frame.e$i -textvariable ::oceanbase::mysql::options($section,$key) -values {test timed} -state readonly
                } else {
                    ttk::entry $frame.e$i -textvariable ::oceanbase::mysql::options($section,$key) -width 30
                    if {[string match *pass $key]} {$frame.e$i configure -show *}
                }
                grid $frame.l$i -row $i -column 0 -sticky e -padx 5 -pady 2
                grid $frame.e$i -row $i -column 1 -sticky ew -padx 5 -pady 2
            }
        }
        if {$option eq "drive"} {.oboptions.tabs select .oboptions.tabs.driver}
        ttk::frame .oboptions.buttons
        ttk::button .oboptions.buttons.ok -text OK -command ::oceanbase::mysql::save_options
        ttk::button .oboptions.buttons.cancel -text Cancel -command {destroy .oboptions}
        pack .oboptions.buttons.cancel .oboptions.buttons.ok -side right -padx 5 -pady 5
        pack .oboptions.buttons -fill x
    }
    proc validate {configuration} {config $configuration}
    proc counter {bm interval masterthread} {
        global configoceanbase
        with_config tcount_mysql $bm $interval $masterthread OceanBase [dict get $configoceanbase connection ob_query_timeout]
    }

}
