# Adapt only scripts generated for the OceanBase category.
namespace eval oceanbase::mysql {
    proc decode_password {value} {
        # diset/GUI store quotemeta escapes. Decode only that alphabet, leaving
        # literal backslashes (for example in a password containing \n) alone.
        if {[info exists ::quote_passwords] && !$::quote_passwords} {return $value}
        return [regsub -all {\\([][#$;{}])} $value {\1}]
    }

    proc rewrite_workload_credentials {script workload configuration} {
        set user_key [expr {$workload eq "tpcc" ? "mysql_user" : "mysql_tpch_user"}]
        set password_key [expr {$workload eq "tpcc" ? "mysql_pass" : "mysql_tpch_pass"}]
        set user [dict get $configuration $workload $user_key]
        set stored [dict get $configuration $workload $password_key]
        set password [decode_password $stored]
        # Match complete generator assignments, including any newlines. Their
        # interpolated values need not be valid Tcl before list serialization.
        foreach {variable value generated comment} [list \
            user $user $user {MySQL user} \
            password $password [quotemeta $stored] {Password for the MySQL user}] {
            set original "set $variable \"$generated\" ;# $comment"
            if {[string first $original $script] < 0} {error "OceanBase adapter: missing workload $variable assignment"}
            set script [string map [list $original "[list set $variable $value] ;# $comment"] $script]
        }
        return $script
    }

    proc rewrite_schema_entry {script workload action configuration} {
        set entry [dict get [dict create build do_$workload check check_$workload delete drop_schema] $action]
        set index [string last "\n$entry " $script]
        if {$index < 0} {error "OceanBase adapter: missing schema entry point $entry"}
        set line [string range $script [expr {$index + 1}] end]
        set user_key [expr {$workload eq "tpcc" ? "mysql_user" : "mysql_tpch_user"}]
        set password_key [expr {$workload eq "tpcc" ? "mysql_pass" : "mysql_tpch_pass"}]
        set database_key [expr {$workload eq "tpcc" ? "mysql_dbase" : "mysql_tpch_dbase"}]
        set user [dict get $configuration $workload $user_key]
        set encoded [quotemeta [dict get $configuration $workload $password_key]]
        # Decode the generator's backslash quoting without command or variable
        # substitution, then serialize all entry arguments as a Tcl list.
        set password [decode_password [dict get $configuration $workload $password_key]]
        set database [dict get $configuration $workload $database_key]
        set original "$user $encoded $database"
        if {[string first $original $line] < 0} {error "OceanBase adapter: missing schema credentials"}
        set line [string map [list $original [list $user $password $database]] $line]
        return "[string range $script 0 $index][list {*}$line]"
    }

    proc rewrite_runtime {script timeout} {
        set library_check {if [catch {package require $library} message] { error "Failed to load $library - $message" }}
        if {[string first $library_check $script] < 0} {error "OceanBase adapter: missing generated library check"}
        append library_check "\n"
        set setup $library_check
        append setup "package require oceanbasecommon\n" [list oceanbasecommon::configure $timeout] "\n"
        set script [string map [list $library_check $setup \
            {append connectstring " -user $user -password $password"} {lappend connectstring -user $user -password $password} \
            {set login_command "mysqlconnect [ dict get $connectstring ]"} {set login_command [linsert $connectstring 0 mysqlconnect]} \
            {puts "login_command $login_command"} {} \
            {return $mysql_handler} {oceanbasecommon::configure_session $mysql_handler
        return $mysql_handler} \
            {testresult $nopm $tpm MySQL} {testresult $nopm $tpm OceanBase} \
            {lsearch $table_exists $table} {lsearch -nocase $table_exists $table}] $script]
        foreach boundary {start end} {
            set original [string map [list @boundary@ $boundary] {            if {[catch {set handler_stat [ list [ mysql::sel $mysql_handler "show global status where Variable_name = 'Com_commit' or Variable_name =  'Com_rollback'" -list ] ]}]} {
                puts stderr {error, failed to query transaction statistics}
                return
            } else {
                regexp {\{\{Com_commit\ ([0-9]+)\}\ \{Com_rollback\ ([0-9]+)\}\}} $handler_stat all com_comm com_roll
                set @boundary@_trans [ expr $com_comm + $com_roll ]
            }}]
            set replacement [string map [list @boundary@ $boundary] {            if {[catch {set @boundary@_trans [oceanbasecommon::transaction_count $mysql_handler]} message]} {
                tsv::set application abort 1
                catch {mysqlclose $mysql_handler}
                error "Transaction statistics failed: $message"
            }}]
            set script [string map [list $original $replacement] $script]
        }
        return $script
    }
}
