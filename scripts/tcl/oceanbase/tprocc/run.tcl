source [file join [file dirname [info script]] config.tcl]

diset tpcc ob_driver timed
diset tpcc ob_rampup [ob_env RAMPUP_MINUTES 2]
diset tpcc ob_duration [ob_env DURATION_MINUTES 5]
diset tpcc ob_total_iterations [ob_env TOTAL_ITERATIONS 10000000]
diset tpcc ob_allwarehouse [ob_env ALL_WAREHOUSES true]
diset tpcc ob_timeprofile [ob_env TIME_PROFILE true]
diset tpcc ob_raiseerror true
diset tpcc ob_keyandthink false

loadscript
vuset vu [ob_env RUN_VU 8]
vuset logtotemp 1
vucreate

set run_result [vurun]
puts $run_result
if {![regexp {jobid=([0-9A-F]+)} $run_result -> job_id]} {
    error "Could not extract the benchmark job ID from: $run_result"
}
ob_require_success Run

jobs $job_id result
if {[ob_env TIME_PROFILE true]} {
    jobs $job_id timing
}
jobs $job_id save
puts "Result artifact: [file join $::env(TMP) hdb_${job_id}.json]"

