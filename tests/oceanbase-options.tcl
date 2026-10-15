# Run in the built CLI with DISPLAY pointing at a disposable X server.
set argv {}
package require tcltest 2
namespace import ::tcltest::*
set root [file dirname [file dirname [file normalize [info script]]]]
set isolation_channel [file tempfile oceanbase_options_state [file join [temporaryDirectory] ob-options-]]
close $isolation_channel
file delete $oceanbase_options_state
file mkdir $oceanbase_options_state
set failed 1
try {
    if {$::tcl_platform(platform) ne "windows"} {file attributes $oceanbase_options_state -permissions 0700}
    catch {hdb close}
    foreach name [concat {generic database} [dict keys $dbdict]] {
        set original [CheckSQLiteDB $name]
        if {[file exists $original]} {file copy $original [file join $oceanbase_options_state "$name.db"]}
    }
    rename ::CheckSQLiteDB ::oceanbase_options_original_CheckSQLiteDB
    proc ::CheckSQLiteDB {name} {return [file join $::oceanbase_options_state "$name.db"]}
set gui [zipfs mount [file join [pwd] hammerdb] /ob-options-test]
lappend auto_path $gui/lib
set ::env(TK_LIBRARY) $gui/tk_library
package require Tk
set f [open [file join $root src generic gened.tcl]]
set themed_toplevel {}
while {[gets $f line] >= 0} {
    append themed_toplevel $line \n
    if {[info complete $themed_toplevel]} {break}
}
close $f
eval $themed_toplevel
set f [open [file join $root src generic gened.tcl]]
set editor_source [read $f]
close $f
set start [string first {proc get_warehouse_list_for_spinbox } $editor_source]
set definition {}
foreach line [split [string range $editor_source $start end] \n] {
    append definition $line \n
    if {[info complete $definition]} {eval $definition; break}
}
wm withdraw .
ttk::toplevel .ed_mainFrame
wm withdraw .ed_mainFrame
set configoceanbase [oceanbaseconfig::normalize [::XML::To_Dict [file join $root config oceanbase.xml]]]
set baseline $configoceanbase
set mysql_before $configmysql
set oracle_before $configoracle

proc select_ob_mode {mode} {
    set widget $::oceanbase::mysql::option_widgets(ob_compatibility_mode)
    $widget set $mode
    event generate $widget <<ComboboxSelected>>
    update
}

test options-mode-switch {Selecting Oracle replaces MySQL fields in the same dialog} -body {
    oceanbase::mysql::show_options tpcc all
    select_ob_mode oracle
    list [winfo exists .oboptions] [info exists ::oceanbase::mysql::option_widgets(system_user)] \
        [info exists ::oceanbase::mysql::option_widgets(tpcc_user)] \
        [info exists ::oceanbase::mysql::option_widgets(ob_storage_engine)] \
        [.oboptions.tabs tab 0 -text] [.oboptions.tabs tab 1 -text]
} -cleanup {destroy .oboptions} -result {1 1 1 0 Connection Settings}

test options-mode-drafts {Switching modes retains both unsaved forms} -body {
    oceanbase::mysql::show_options tpcc all
    set ::oceanbase::mysql::options(tpcc,ob_user) mysql_draft
    select_ob_mode oracle
    set ::oceanbase::mysql::options(oracle_tpcc,tpcc_user) oracle_draft
    select_ob_mode mysql
    set mysql $::oceanbase::mysql::options(tpcc,ob_user)
    select_ob_mode oracle
    list $mysql $::oceanbase::mysql::options(oracle_tpcc,tpcc_user) \
        [expr {$configoracle eq $oracle_before}] [expr {$configmysql eq $mysql_before}]
} -cleanup {destroy .oboptions} -result {mysql_draft oracle_draft 1 1}

test options-oracle-dependencies {Oracle test driver disables the timed controls} -body {
    oceanbase::mysql::show_options tpcc drive
    select_ob_mode oracle
    $::oceanbase::mysql::option_widgets(async_scale) invoke
    set widget $::oceanbase::mysql::option_widgets(ora_driver)
    $widget.test invoke
    list $::oceanbase::mysql::options(oracle_tpcc,async_scale) \
        [$::oceanbase::mysql::option_widgets(duration) instate disabled] \
        [$::oceanbase::mysql::option_widgets(async_client) instate disabled]
} -cleanup {destroy .oboptions} -result {false 1 1}

test options-oracle-tpch {Oracle TPROC-H has a parallelism control and refresh dependencies} -body {
    oceanbase::mysql::show_options tpch all
    select_ob_mode oracle
    set before [$::oceanbase::mysql::option_widgets(update_sets) instate disabled]
    $::oceanbase::mysql::option_widgets(refresh_on) invoke
    list [winfo class $::oceanbase::mysql::option_widgets(degree_of_parallel)] \
        $before [$::oceanbase::mysql::option_widgets(update_sets) instate disabled]
} -cleanup {destroy .oboptions} -result {TEntry 1 0}

test options-oracle-save {Oracle settings persist separately and reopen through the selected backend} -body {
    oceanbase::mysql::show_options tpcc all
    select_ob_mode oracle
    set ::oceanbase::mysql::options(oracle_tpcc,tpcc_user) oracle_saved
    .oboptions.buttons.ok invoke
    configobtpcc all
    sqlite3 settings [CheckSQLiteDB oceanbase]
    set stored [settings onecolumn {SELECT val FROM connection WHERE key='ob_oracle_options'}]
    settings close
    list $::oceanbase::mysql::options(connection,ob_compatibility_mode) \
        $::oceanbase::mysql::options(oracle_tpcc,tpcc_user) [dict get $stored tpcc tpcc_user] \
        [dict get $configoceanbase tpcc ob_user] [expr {$configoracle eq $oracle_before}]
} -cleanup {destroy .oboptions; set configoceanbase $baseline} -result {oracle oracle_saved oracle_saved root 1}

test options-oracle-endpoint {Each mode retains its own endpoint and tenant after saving} -body {
    oceanbase::mysql::show_options tpcc all
    set ::oceanbase::mysql::options(connection,ob_host) mysql.example
    set ::oceanbase::mysql::options(connection,ob_tenant) mysql_tenant
    select_ob_mode oracle
    set ::oceanbase::mysql::options(oracle_connection,ob_host) oracle.example
    set ::oceanbase::mysql::options(oracle_connection,ob_tenant) oracle_tenant
    .oboptions.buttons.ok invoke
    configobtpcc all
    set active [oceanbase::active_config $configoceanbase]
    list $::oceanbase::mysql::options(oracle_connection,ob_host) \
        [dict get $active connection ob_tenant] [dict get $configoceanbase connection ob_host] \
        [dict get $configoceanbase connection ob_tenant]
} -cleanup {destroy .oboptions; set configoceanbase $baseline} -result {oracle.example oracle_tenant mysql.example mysql_tenant}

# Compare the rendered dialogs against the real native Oracle renderer so
# missing labels, wrong pages, ordering and replacement control types regress.
proc oracle_tab_labels {frame} {
    set labels {}
    foreach widget [winfo children $frame] {
        if {[winfo class $widget] in {TLabel TRadiobutton}} {
            set label [$widget cget -text]
            if {$label ne "" && $label ne "Tenant Mode :"} {lappend labels $label}
        }
        lappend labels {*}[oracle_tab_labels $widget]
    }
    return $labels
}
proc oracle_tab_controls {frame} {
    set controls {}
    foreach widget [winfo children $frame] {
        set class [winfo class $widget]
        if {$class in {TEntry TSpinbox TCheckbutton TRadiobutton}} {lappend controls $class}
        lappend controls {*}[oracle_tab_controls $widget]
    }
    return $controls
}
source [file join $root src oracle oraopt.tcl]
if {![llength [info commands ::create_image]]} {proc ::create_image {args} {return {}}}
foreach group {tpcc tpch} {
    foreach option {all build drive} {
        test options-oracle-parity-$group-$option {Native Oracle labels, controls and order match on both tabs} -body {
            configora$group $option
            set native [expr {$group eq "tpcc" ? ".tpc" : ".tpch"}]
            set expected [list [oracle_tab_labels $native.c1] [oracle_tab_labels $native.f1] \
                [oracle_tab_controls $native.c1] [oracle_tab_controls $native.f1]]
            destroy $native
            oceanbase::mysql::show_options $group $option
            select_ob_mode oracle
            set actual [list [oracle_tab_labels .oboptions.tabs.connection] [oracle_tab_labels .oboptions.tabs.settings] \
                [oracle_tab_controls .oboptions.tabs.connection] [oracle_tab_controls .oboptions.tabs.settings]]
            expr {$actual eq $expected}
        } -cleanup {catch {destroy .tpc}; catch {destroy .tpch}; destroy .oboptions} -result 1
    }
}

test options-oracle-unavailable {Unsupported Oracle controls remain visible and disabled} -body {
    set disabled {}
    foreach group {tpcc tpch} {
        oceanbase::mysql::show_options $group all
        select_ob_mode oracle
        foreach key [oceanbase::oracle::unavailable_options $group] {
            lappend disabled [$::oceanbase::mysql::option_widgets($key) instate disabled]
        }
        destroy .oboptions
    }
    lsort -unique $disabled
} -result 1

test options-oracle-page-and-types {Oracle uses native scale radio buttons and a separate OceanBase endpoint page} -body {
    oceanbase::mysql::show_options tpch all
    select_ob_mode oracle
    set widget $::oceanbase::mysql::option_widgets(scale_fact)
    list [llength [.oboptions.tabs tabs]] [.oboptions.tabs tab 2 -text] \
        [winfo class $widget.r1] [winfo class $widget.r100000] \
        [winfo parent $::oceanbase::mysql::option_widgets(ob_host)] \
        [.oboptions.heading cget -text]
} -cleanup {destroy .oboptions} -result {3 OceanBase TRadiobutton TRadiobutton .oboptions.tabs.oceanbase {Build Options}}

test options-oracle-mode-cleanup {Switching back to MySQL removes Oracle-only pages and headings} -body {
    oceanbase::mysql::show_options tpcc all
    select_ob_mode oracle
    select_ob_mode mysql
    list [llength [.oboptions.tabs tabs]] [winfo exists .oboptions.heading] \
        [winfo exists .oboptions.tabs.oceanbase] [info exists ::oceanbase::mysql::option_widgets(ob_storage_engine)]
} -cleanup {destroy .oboptions} -result {2 0 0 1}

test options-oracle-async-keying {Keying remains editable like Oracle and disabling it clears async} -body {
    oceanbase::mysql::show_options tpcc drive
    select_ob_mode oracle
    $::oceanbase::mysql::option_widgets(async_scale) invoke
    set editable [$::oceanbase::mysql::option_widgets(keyandthink) instate !disabled]
    $::oceanbase::mysql::option_widgets(keyandthink) invoke
    list $editable $::oceanbase::mysql::options(oracle_tpcc,async_scale) \
        [$::oceanbase::mysql::option_widgets(async_client) instate disabled]
} -cleanup {destroy .oboptions} -result {1 false 1}

test options-oracle-build-users {Build users follow a reduced warehouse count} -body {
    oceanbase::mysql::show_options tpcc all
    select_ob_mode oracle
    set ::oceanbase::mysql::options(oracle_tpcc,num_vu) 8
    set ::oceanbase::mysql::options(oracle_tpcc,count_ware) 3
    .oboptions.tabs select .oboptions.tabs.settings
    wm transient .oboptions {}
    wm deiconify .oboptions
    update
    focus -force $::oceanbase::mysql::option_widgets(count_ware)
    event generate $::oceanbase::mysql::option_widgets(count_ware) <KeyRelease> -keysym 3
    update
    set ::oceanbase::mysql::options(oracle_tpcc,num_vu)
} -cleanup {destroy .oboptions} -result 3

test options-layout {Independent OB dialog follows native Connection/Settings layout} -body {
    oceanbase::mysql::show_options tpcc all
    list [.oboptions.tabs tab 0 -text] [.oboptions.tabs tab 1 -text] \
        [winfo class $::oceanbase::mysql::option_widgets(ob_pass)] \
        [winfo class $::oceanbase::mysql::option_widgets(ob_count_ware)]
} -cleanup {destroy .oboptions} -result {Connection Settings TEntry TSpinbox}

test options-global-tenant-mode {Tenant Mode stays above every tab in all OB dialogs} -setup {
    wm deiconify .ed_mainFrame
    update
} -body {
    set result {}
    foreach group {tpcc tpch} {
        foreach option {all build drive counter} {
            oceanbase::mysql::show_options $group $option
            update idletasks
            set selector $::oceanbase::mysql::option_widgets(ob_compatibility_mode)
            lappend result [expr {[winfo parent $selector] eq {.oboptions.mode}}] \
                [expr {[lsearch -exact [pack slaves .oboptions] .oboptions.mode] < [lsearch -exact [pack slaves .oboptions] .oboptions.tabs]}] \
                [expr {[$selector cget -values] eq [oceanbase::supported_modes]}]
            foreach tab {.oboptions.tabs.connection .oboptions.tabs.settings} {
                .oboptions.tabs select $tab
                update idletasks
                lappend result [winfo ismapped $selector]
            }
            destroy .oboptions
        }
    }
    lsort -unique $result
} -cleanup {catch {destroy .oboptions}; wm withdraw .ed_mainFrame} -result 1

test options-pool-dependencies {Pool requires prepared stored procedures and disables conflicting choices} -body {
    oceanbase::mysql::show_options tpcc drive
    set ::oceanbase::mysql::options(tpcc,ob_no_stored_procs) true
    $::oceanbase::mysql::option_widgets(ob_connect_pool) invoke
    list $::oceanbase::mysql::options(tpcc,ob_prepared) $::oceanbase::mysql::options(tpcc,ob_no_stored_procs) \
        [$::oceanbase::mysql::option_widgets(ob_prepared) instate disabled] \
        [$::oceanbase::mysql::option_widgets(ob_no_stored_procs) instate disabled]
} -cleanup {destroy .oboptions} -result {true false 1 1}

test options-async-dependencies {Async exposes client controls and enables keying/thinking} -body {
    oceanbase::mysql::show_options tpcc drive
    set before [$::oceanbase::mysql::option_widgets(ob_async_client) instate disabled]
    $::oceanbase::mysql::option_widgets(ob_async_scale) invoke
    list $before $::oceanbase::mysql::options(tpcc,ob_keyandthink) \
        [$::oceanbase::mysql::option_widgets(ob_async_client) instate disabled]
} -cleanup {destroy .oboptions} -result {1 true 0}

test options-test-driver {Test driver disables timed-only options and clears async} -body {
    oceanbase::mysql::show_options tpcc drive
    set ::oceanbase::mysql::options(tpcc,ob_allwarehouse) true
    $::oceanbase::mysql::option_widgets(ob_async_scale) invoke
    set widget $::oceanbase::mysql::option_widgets(ob_driver)
    $widget.test invoke
    list $::oceanbase::mysql::options(tpcc,ob_async_scale) \
        $::oceanbase::mysql::options(tpcc,ob_allwarehouse) \
        [$::oceanbase::mysql::option_widgets(ob_allwarehouse) instate disabled] \
        [$::oceanbase::mysql::option_widgets(ob_duration) instate disabled] \
        [$::oceanbase::mysql::option_widgets(ob_async_scale) instate disabled]
} -cleanup {destroy .oboptions} -result {false false 1 1 1}

test options-tls-controls {TLS CA and mutual-authentication controls follow SSL selection} -body {
    oceanbase::mysql::show_options tpcc build
    $::oceanbase::mysql::option_widgets(ob_ssl) invoke
    set one_way [$::oceanbase::mysql::option_widgets(ob_ssl_cert) instate disabled]
    set widget $::oceanbase::mysql::option_widgets(ob_ssl_two_way)
    $widget.true invoke
    list $one_way [$::oceanbase::mysql::option_widgets(ob_ssl_ca) instate disabled] \
        [$::oceanbase::mysql::option_widgets(ob_ssl_cert) instate disabled]
} -cleanup {destroy .oboptions} -result {1 0 0}

test options-refresh-controls {Refresh function enables update count, delay and verbose controls} -body {
    oceanbase::mysql::show_options tpch drive
    set before [$::oceanbase::mysql::option_widgets(ob_update_sets) instate disabled]
    $::oceanbase::mysql::option_widgets(ob_refresh_on) invoke
    list $before [$::oceanbase::mysql::option_widgets(ob_update_sets) instate disabled]
} -cleanup {destroy .oboptions} -result {1 0}

test options-cancel-isolation {Editing and cancelling does not publish credentials or touch MySQL} -body {
    oceanbase::mysql::show_options tpcc all
    set ::oceanbase::mysql::options(tpcc,ob_user) changed
    .oboptions.buttons.cancel invoke
    list [expr {$baseline eq $configoceanbase}] [expr {$mysql_before eq $configmysql}]
} -result {1 1}

test counter-options-save {Counter settings persist and retain an independent connection} -body {
    countobopts TPC-C
    set ::oceanbase::mysql::options(counter,tc_refresh_rate) 7
    set ::oceanbase::mysql::options(counter,tc_log_to_temp) 1
    set ::oceanbase::mysql::options(counter,tc_unique_log_name) 1
    set ::oceanbase::mysql::options(counter,tc_log_timestamps) 1
    .oboptions.buttons.ok invoke
    sqlite3 settings [CheckSQLiteDB generic]
    set persisted [settings eval {SELECT val FROM transaction_counter WHERE key='tc_refresh_rate'}]
    settings close
    list $persisted [dict get $genericdict transaction_counter tc_log_to_temp] \
        [winfo exists .oboptions] [expr {$mysql_before eq $configmysql}]
} -result {7 1 0 1}

test counter-save-rollback {A failed combined save retains both the connection and counter preferences} -body {
    set updated $configoceanbase
    dict set updated tpcc ob_user should_not_persist
    set failed [catch {oceanbaseconfig::save $updated {tc_refresh_rate 13 invalid_counter_key 1}}]
    sqlite3 settings [CheckSQLiteDB generic]
    set refresh [settings onecolumn {SELECT val FROM transaction_counter WHERE key='tc_refresh_rate'}]
    settings close
    sqlite3 settings [CheckSQLiteDB oceanbase]
    set user [settings onecolumn {SELECT val FROM tpcc WHERE key='ob_user'}]
    settings close
    list $failed $refresh [expr {$user eq [dict get $configoceanbase tpcc ob_user]}]
} -result {1 7 1}

test feature-pool-credentials {Pool qualification and special-character credentials remain data} -body {
    set mapped [oceanbasecommon::pool_connection {ob_host host ob_port 2883 ob_user root ob_pass {a;[not executed]$x} ob_dbase tpcc ob_tenant tenant ob_cluster cluster ob_ssl_options {-ssl false}}]
    list [dict get $mapped mysql_user] [dict get $mapped mysql_pass]
} -result {root@tenant#cluster {a;[not executed]$x}}

test feature-pool-script {OB pools read independent XML, preserving native generator isolation} -body {
    set saved_tk_version $::tk_version
    unset ::tk_version
    dbset db ob
    dbset bm TPROC-C
    dict set configoceanbase tpcc ob_connect_pool true
    dict set configoceanbase tpcc ob_no_stored_procs false
    loadtimedobtpcc
    list [info complete $::_ED(package)] \
        [expr {[string first {get_connect_xml ob} $::_ED(package)] >= 0}] \
        [expr {[string first {oceanbasecommon::pool_connection} $::_ED(package)] >= 0}] \
        [expr {$mysql_before eq $configmysql}]
} -cleanup {set ::tk_version $saved_tk_version; set configoceanbase $baseline} -result {1 1 1 1}

test feature-history-native {OB native HISTORY PK does not use the MySQL VERSION gate} -body {
    set saved_tk_version $::tk_version
    unset ::tk_version
    rename load_virtual real_load_virtual
    proc load_virtual {} {}
    dict set configoceanbase tpcc ob_history_pk true
    build_obtpcc
    list [info complete $::_ED(package)] \
        [expr {[string first {pkmin_version} $::_ED(package)] < 0}] \
        [expr {[string first {AUTO_INCREMENT INVISIBLE} $::_ED(package)] >= 0}]
} -cleanup {set ::tk_version $saved_tk_version; rename load_virtual {}; rename real_load_virtual load_virtual; set configoceanbase $baseline} -result {1 1 1}

test feature-history-distributed {Distributed HISTORY primary key includes its partition key} -body {
    set saved_tk_version $::tk_version
    unset ::tk_version
    rename load_virtual real_load_virtual
    proc load_virtual {} {}
    dict set configoceanbase tpcc ob_distributed_schema true
    dict set configoceanbase tpcc ob_history_pk true
    build_obtpcc
    list [info complete $::_ED(package)] \
        [expr {[string first {PRIMARY KEY (`h_w_id`, `id`)} $::_ED(package)] >= 0}]
} -cleanup {set ::tk_version $saved_tk_version; rename load_virtual {}; rename real_load_virtual load_virtual; set configoceanbase $baseline} -result {1 1}

destroy .ed_mainFrame
set failed $::tcltest::numTests(Failed)
cleanupTests
} finally {
    catch {destroy .oboptions}
    catch {destroy .ed_mainFrame}
    catch {hdb close}
    if {[llength [info commands ::oceanbase_options_original_CheckSQLiteDB]]} {
        rename ::CheckSQLiteDB {}
        rename ::oceanbase_options_original_CheckSQLiteDB ::CheckSQLiteDB
    }
    file delete -force $oceanbase_options_state
}
exit [expr {$failed > 0}]
