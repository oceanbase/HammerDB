foreach name {OB_HOST OB_TENANT OB_USER OB_PASSWORD OB_DATABASE} {
    if {![info exists ::env($name)]} {
        error "Set $name in oceanbase.env before running this script"
    }
}
foreach name {OB_HOST OB_TENANT OB_USER OB_DATABASE} {
    if {$::env($name) eq ""} {
        error "$name cannot be empty in oceanbase.env"
    }
}

proc ob_env {name fallback} {
    if {[info exists ::env($name)]} {
        return $::env($name)
    }
    return $fallback
}

proc ob_require_success {phase} {
    if {![info exists ::vustatus] || [dict size $::vustatus] == 0} {
        error "$phase did not run"
    }
    dict for {vu status} $::vustatus {
        if {$status ne "FINISH SUCCESS"} {
            error "$phase failed: virtual user $vu ($status)"
        }
    }
    vudestroy
}

dbset db ob
dbset bm TPROC-C
diset connection ob_compatibility_mode mysql
diset connection ob_host $::env(OB_HOST)
diset connection ob_port [ob_env OB_PORT 2881]
diset connection ob_tenant $::env(OB_TENANT)
diset connection ob_cluster [ob_env OB_CLUSTER {}]
diset connection ob_query_timeout [ob_env OB_QUERY_TIMEOUT 300]
diset tpcc ob_user $::env(OB_USER)
diset tpcc ob_pass $::env(OB_PASSWORD)
diset tpcc ob_dbase $::env(OB_DATABASE)
diset tpcc ob_count_ware [ob_env WAREHOUSES 70]
diset tpcc ob_no_stored_procs [ob_env NO_STORED_PROCS true]
diset tpcc ob_prepared [ob_env PREPARED_STATEMENTS false]

