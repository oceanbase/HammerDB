source [file join [file dirname [info script]] config.tcl]

diset tpcc ob_num_vu [ob_env BUILD_VU 8]
diset tpcc ob_storage_engine innodb
diset tpcc ob_partition false

puts "Building the OceanBase TPROC-C schema"
buildschema
ob_require_success Build

puts "Checking the OceanBase TPROC-C schema"
checkschema
ob_require_success Check
puts "Schema build and check completed successfully"

