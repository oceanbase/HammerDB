# Adapt only scripts generated for the OceanBase category.
namespace eval oceanbase::mysql {
    proc rewrite_runtime {script timeout} {
        set library_check {if [catch {package require $library} message] { error "Failed to load $library - $message" }}
        if {[string first $library_check $script] < 0} {error "OceanBase adapter: missing generated library check"}
        append library_check "\n"
        set setup $library_check
        append setup "package require oceanbasecommon\n" [list oceanbasecommon::configure $timeout] "\n"
        set script [string map [list $library_check $setup \
            {append connectstring " -user $user -password $password"} {lappend connectstring -user $user -password $password} \
            {set login_command "mysqlconnect [ dict get $connectstring ]"} {set login_command [linsert $connectstring 0 mysqlconnect]} \
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
