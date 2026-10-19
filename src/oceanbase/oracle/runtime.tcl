namespace eval oceanbase::oracle {
    proc procedure_definition {script name} {
        set start [string first "proc $name \{" $script]
        if {$start < 0} {error "OceanBase Oracle adapter: missing native procedure $name"}
        set definition {}
        foreach line [split [string range $script $start end] \n] {
            append definition $line \n
            if {[info complete $definition]} {return [string trimright $definition \n]}
        }
        error "OceanBase Oracle adapter: incomplete native procedure $name"
    }

    proc rewrite_schema {script workload} {
        set original [procedure_definition $script CreateUser]
        set arguments [lindex $original 2]
        set user [expr {$workload eq "tpcc" ? "tpcc_user" : "tpch_user"}]
        set password [expr {$workload eq "tpcc" ? "tpcc_pass" : "tpch_pass"}]
        set replacement [list proc CreateUser $arguments "::oceanbaseoraclecommon::create_user \$lda \$$user \$$password"]
        set script [string map [list $original $replacement] $script]
        foreach name {CreateTables CreateIndexes} {
            set original [procedure_definition $script $name]
            set replacement $original
            # Preserve the native logical schema; remove Oracle physical
            # storage clauses which do not describe OceanBase storage.
            regsub -all -nocase {\s+(INITRANS|PCTFREE|PCTUSED)\s+[0-9]+} $replacement {} replacement
            regsub -all -nocase {\s+ORGANIZATION INDEX\s+NOCOMPRESS} $replacement {} replacement
            regsub -all -nocase {\s+TABLESPACE\s+\$tpcc_ol_tab} $replacement {} replacement
            regsub -all -nocase {\s+ENABLE\M} $replacement {} replacement
            regsub -all -nocase {\s+PARALLEL\M} $replacement {} replacement
            set replacement [string map [list {alter session set sort_area_size=5000000} {BEGIN NULL; END;}] $replacement]
            if {$workload eq "tpch" && $name eq "CreateIndexes"} {
                # RF2 deletes by order key. Keep those rows adjacent in the
                # storage primary key, as in the distributed OceanBase layout.
                regsub -all -nocase {(LINEITEM_PK\s+PRIMARY KEY\s*)\(\s*L_LINENUMBER\s*,\s*L_ORDERKEY\s*\)} $replacement {\1(L_ORDERKEY, L_LINENUMBER)} replacement
                # OceanBase builds the primary index with ADD PRIMARY KEY;
                # it cannot attach an existing Oracle index with USING INDEX.
                regsub -all -nocase {\s+USING INDEX\s+[A-Z_]+} $replacement {} replacement
                regsub -all -nocase {\s+(NOT\s+)?DEFERRABLE\M} $replacement {} replacement
                regsub -all -nocase {"CREATE UNIQUE INDEX [^"]+"} $replacement {"BEGIN NULL; END;"} replacement
            }
            set script [string map [list $original $replacement] $script]
        }
        # Retain the existing generator batch sizes. The loader below renders
        # their values as SQL tuples instead of OBCI's per-value piece protocol.
        if {$workload eq "tpcc"} {
            set original [procedure_definition $script Orders]
            regsub -all {\$o_id % 100\M} $original {$o_id % 50} replacement
            set script [string map [list $original $replacement] $script]
            set original [procedure_definition $script Customer]
            set replacement [string map [list \
                {values (:c_id, :c_d_id, :c_w_id, :c_w_id, :c_d_id, to_date(:timestamp,'YYYYMMDDHH24MISS'), :h_amount, :h_data)} \
                {values (:h_c_id, :h_c_d_id, :h_c_w_id, :h_w_id, :h_d_id, to_date(:h_date,'YYYYMMDDHH24MISS'), :h_amount, :h_data)} \
                {orabind $curn6 -arraydml :c_id $h_c_id_c6 :c_d_id $h_c_d_id_c6 :c_w_id $h_c_w_id_c6 :c_w_id $h_w_id_c6 :c_d_id $h_d_id_c6 :timestamp $h_date_c6} \
                {orabind $curn6 -arraydml :h_c_id $h_c_id_c6 :h_c_d_id $h_c_d_id_c6 :h_c_w_id $h_c_w_id_c6 :h_w_id $h_w_id_c6 :h_d_id $h_d_id_c6 :h_date $h_date_c6}] $original]
            set script [string map [list $original $replacement] $script]
        } else {
            foreach name {mk_supp mk_cust mk_part mk_order} {
                set original [procedure_definition $script $name]
                regsub -all {\$i % 1000\M} $original {$i % 100} replacement
                set script [string map [list $original $replacement] $script]
            }
        }
        # Stop a failed loader immediately. In addition to hiding the failure,
        # the native all-fields formatter can mask OBCI batch errors.
        regsub -all {puts \[ oramsg \$curn[0-9]+ all \]} $script {error $message} script
        set script [string map [list {oraexec } {::oceanbaseoraclecommon::exec_insert }] $script]
        set loaders [expr {$workload eq "tpcc" ?
            {Customer Orders LoadItems Stock District LoadWare} :
            {mk_region mk_nation mk_supp mk_cust mk_part mk_order}}]
        foreach name $loaders {
            set original [procedure_definition $script $name]
            set replacement [string map [list \
                {oraopen } {::oceanbaseoracleload::open } \
                {oraparse } {::oceanbaseoracleload::parse } \
                {orabind } {::oceanbaseoracleload::bind } \
                {::oceanbaseoraclecommon::exec_insert } {::oceanbaseoracleload::exec } \
                {oracommit } {::oceanbaseoracleload::commit } \
                {oraclose } {::oceanbaseoracleload::close }] $original]
            set script [string map [list $original $replacement] $script]
        }
        set script "package require oceanbaseoracleload\n$script"
        return $script
    }

    proc rewrite_distributed {script workload partitions owner} {
        # Tablegroup metadata/creation requires the tenant administrator.
        # Create it alongside the benchmark user, not in each loader session.
        set original [procedure_definition $script CreateUser]
        set body [lindex $original 3]
        append body "\n::oceanbaseoracleschema::prepare \$lda $workload [list $owner]"
        set script [string map [list $original [list proc CreateUser [lindex $original 2] $body]] $script]
        foreach name {CreateTables CreateIndexes} {
            set original [procedure_definition $script $name]
            set execute {orasql $curn1 $sql($i)}
            if {[string first $execute $original] < 0} {error "OceanBase distributed schema: missing $name DDL execution"}
            if {$name eq "CreateTables"} {
                set body [lindex $original 3]
                set prepare "\n    [list set hdb_groups [::oceanbaseoracleschema::tablegroups $owner $workload]]\n"
                set body "$prepare$body"
                set replacement [list proc $name [lindex $original 2] [string map [list $execute \
                    "orasql \$curn1 \[::oceanbaseoracleschema::table_ddl \$sql(\$i) $workload $partitions \$hdb_groups\]"] $body]]
            } else {
                set replacement [string map [list $execute \
                    "orasql \$curn1 \[::oceanbaseoracleschema::index_ddl \$sql(\$i) $workload\]"] $original]
                if {$workload eq "tpch"} {
                    set body [lindex $replacement 3]
                    set index {    orasql $curn1 "CREATE INDEX HDB_LINEITEM_SHIPDATE_COVER_IDX ON LINEITEM (L_SHIPDATE,L_PARTKEY,L_SUPPKEY,L_DISCOUNT,L_QUANTITY,L_EXTENDEDPRICE) LOCAL"}
                    set end [string last {    oraclose $curn1} $body]
                    if {$end < 0} {error "OceanBase distributed schema: missing index cursor close"}
                    set body "[string range $body 0 [expr {$end-1}]]$index\n[string range $body $end end]"
                    set replacement [list proc $name [lindex $original 2] $body]
                }
            }
            set script [string map [list $original $replacement] $script]
        }
        return $script
    }

    proc rewrite_monitor {script} {
        set switch_start [string first {switch $myposition} $script]
        set start [string first "    1 \{" $script $switch_start]
        if {$switch_start < 0 || $start < 0} {error "OceanBase Oracle adapter: missing timed monitor branch"}
        set branch {}
        foreach line [split [string range $script $start end] \n] {
            append branch $line \n
            if {[info complete $branch]} {break}
        }
        set branch [string trimright $branch \n]
        if {![info complete $branch]} {error "OceanBase Oracle adapter: incomplete timed monitor branch"}
        set replacement {    1 {
        ::oceanbaseoraclecommon::monitor $connect $rampup $duration $totalvirtualusers $mode
        tsv::set application abort 1
    }}
        return [string replace $script $start [expr {$start + [string length $branch] - 1}] $replacement]
    }

    proc rewrite_date_outputs {script} {
        # OBCI 2.1.1.4 allocates a short Oracle DATE buffer for an implicit
        # PL/SQL OUT result, then libobclient writes a MYSQL_TIME into it.
        # Keep the stored procedures and DATE columns intact. Convert only
        # the two client-facing DATE outputs in their anonymous call blocks.
        set lines {}
        foreach line [split $script \n] {
            if {[regexp {^\s*set (sql_py|sql_os) "BEGIN (payment|ostat)\(} $line -> variable procedure]} {
                set bind [expr {$procedure eq "payment" ? "p_c_since" : "os_entdate"}]
                set sql [string map [list :$bind hdb_date] [lindex $line 2]]
                set sql [string replace $sql 0 4 {DECLARE hdb_date DATE; BEGIN}]
                set end [string last {END;} $sql]
                if {$end < 0} {error "OceanBase Oracle adapter: incomplete $procedure call"}
                set sql [string replace $sql $end end ":$bind := TO_CHAR(hdb_date,'YYYY-MM-DD HH24:MI:SS'); END;"]
                set line [list set $variable $sql]
            }
            lappend lines $line
        }
        return [join $lines \n]
    }

    proc rewrite_refresh {script} {
        set original [procedure_definition $script mk_order_ref]
        set replacement $original
        set start [string first {    set curn_defer } $replacement]
        set last [string first {    oraclose $curn_defer} $replacement $start]
        if {$start < 0 || $last < 0} {error "OceanBase Oracle adapter: missing native refresh constraint block"}
        set replacement [string replace $replacement $start [string first \n $replacement $last] {}]
        set line_insert {            eval $statement2
            if {[ catch {oraexec $curn2} message ] } {
                puts "Error in cursor 2:$curn2 $message"
                puts [ oramsg $curn2 all ]
            }}
        set order_insert {        eval $statement
        if {[ catch {oraexec $curn1} message ] } {
            puts "Error in cursor 1:$curn1 $message"
            puts [ oramsg $curn1 all ]
        }}
        foreach marker [list $line_insert $order_insert] {
            if {[string first $marker $replacement] < 0} {error "OceanBase Oracle adapter: missing native refresh insert"}
        }
        set variables {lsdate lokey ldiscount leprice lsuppkey lquantity lrflag lpartkey lstatus ltax lcdate lrdate lsmode llcnt linstruct lcomment}
        set values {}
        foreach variable $variables {lappend values \$$variable}
        set capture "            lappend hdb_lines \[list [join $values { }]\]"
        set inserts "        eval \$statement\n        if {\[catch {oraexec \$curn1} message\]} {error \$message}\n"
        append inserts "        foreach hdb_row \$hdb_lines {\n            lassign \$hdb_row $variables\n            eval \$statement2\n            if {\[catch {oraexec \$curn2} message\]} {error \$message}\n        }"
        set replacement [string map [list {        #Lineitem Loop} "        set hdb_lines {}\n        #Lineitem Loop" \
            $line_insert $capture $order_insert $inserts] $replacement]
        return [string map [list $original $replacement] $script]
    }

    proc rewrite {script configuration workload action} {
        set native [config $configuration]
        set marker {if [catch {package require $library} message] { error "Failed to load $library - $message" }}
        if {[string first $marker $script] < 0} {error "OceanBase Oracle adapter: missing native driver load"}
        set pool [expr {$workload eq "tpcc" && $action in {test timed} && [dict get $native tpcc connect_pool] eq "true"}]
        set setup [connection_setup $configuration $pool]
        if {$pool} {
            set original {set cpool [ get_connect_xml ora ]}
            if {[string first $original $script] < 0} {error "OceanBase Oracle pool: missing native connection pool"}
            set script [string map [list $original {set cpool [::oceanbaseoraclecommon::get_pool_config]}] $script]
        }
        if {$action eq "build" && [dict get $native $workload distributed_schema] eq "true"} {
            append setup "package require oceanbaseoracleschema\n"
        }
        set script [string map [list $marker "$setup$marker"] $script]
        set script [string map [list {oralogon } {::oceanbaseoraclecommon::logon }] $script]
        if {$action eq "build"} {
            set script [rewrite_schema $script $workload]
            if {[dict get $native $workload distributed_schema] eq "true"} {
                set script [rewrite_distributed $script $workload [dict get $native $workload partition_count] [dict get $native $workload ${workload}_user]]
            }
        }
        if {$action eq "timed"} {set script [rewrite_monitor $script]}
        if {$workload eq "tpcc" && $action in {test timed}} {set script [rewrite_date_outputs $script]}
        if {$workload eq "tpch" && $action eq "test"} {set script [rewrite_refresh $script]}
        # OceanBase initializes random state for each session; the obsolete
        # Oracle INITIALIZE entry point is not required.
        set script [string map [list \
            {NLS_LANGUAGE = AMERICAN} {NLS_LANGUAGE = 'AMERICAN'} \
            {NLS_TERRITORY = AMERICA} {NLS_TERRITORY = 'AMERICA'} \
            {BEGIN DBMS_RANDOM.initialize (val => TO_NUMBER(TO_CHAR(SYSDATE,'MMSS')) * (USERENV('SESSIONID') - TRUNC(USERENV('SESSIONID'),-5))); END;} {BEGIN NULL; END;} \
            {parallel (degree $degree_of_parallel)} {parallel $degree_of_parallel}] $script]
        if {$workload eq "tpch"} {
            # Native mk_time returns YYYY-MON-DD while the INSERT mask uses
            # YYYY-MM-DD. OceanBase requires a numeric month for that mask.
            set script [string map [list {[ mk_time $d ]} {[ mk_time_bcp $d ]}] $script]
        }
        # Replace generated Tcl credential assignments/calls with list-safe
        # commands. Passwords are values, never evaluated as Tcl source.
        set c [dict get $native connection]
        set w [dict get $native $workload]
        set user [dict get $w ${workload}_user]
        set pass [::oceanbase::mysql::decode_password [dict get $w ${workload}_pass]]
        set sys [dict get $c system_user]
        set syspass [::oceanbase::mysql::decode_password [dict get $c system_password]]
        set instance hdb_ob_[string tolower $user]
        if {$action in {test timed cloud}} {
            foreach {variable value raw_user raw_password label} [list \
                    connect "$user/$pass@$instance" $user [dict get $w ${workload}_pass] [expr {$workload eq "tpcc" ? "tpc-c" : "tpc-h"}] \
                    systemconnect "$sys/$syspass@$instance" $sys [dict get $c system_password] system] {
                set pattern "\nset $variable $raw_user/[quotemeta $raw_password]@[dict get $c instance] ;# Oracle connect string for $label user"
                set start [string first $pattern $script]
                if {$start >= 0} {
                    set script [string replace $script [expr {$start+1}] [expr {$start+[string length $pattern]-1}] [list set $variable $value]]
                } elseif {[string first "\nset $variable " $script] >= 0} {
                    error "OceanBase Oracle adapter: missing native credential assignment for $variable"
                }
            }
        } else {
            if {$action eq "build"} {
                set command do_$workload
                set args [list $sys $syspass $instance [dict get $w [expr {$workload eq "tpcc" ? "count_ware" : "scale_fact"}]] $user $pass]
                if {$workload eq "tpcc"} {
                    lappend args [dict get $w tpcc_def_tab] [dict get $w tpcc_ol_tab] [dict get $w tpcc_def_temp] false false false [dict get $w num_vu]
                } else {
                    lappend args [dict get $w tpch_def_tab] [dict get $w tpch_def_temp] false [dict get $w num_tpch_threads]
                }
            } elseif {$action eq "check"} {
                set command check_$workload
                set args [list $sys $syspass $instance $user [dict get $w [expr {$workload eq "tpcc" ? "count_ware" : "scale_fact"}]]]
            } else {
                set command drop_$workload
                set args [list $sys $syspass $instance $user]
                if {$workload eq "tpcc"} {lappend args false}
            }
            set start [string last "\n$command " $script]
            if {$start < 0} {error "OceanBase Oracle adapter: missing schema entry point $command"}
            set script "[string range $script 0 $start][list $command {*}$args]\n"
        }
        return $script
    }
}
