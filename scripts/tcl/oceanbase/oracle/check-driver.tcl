# Run with hammerdbcli auto scripts/tcl/oceanbase/oracle/check-driver.tcl
package require oceanbaseoraclecommon
set library /u01/obclient/lib/libobci.so
if {[info exists ::env(OBCI_LIBRARY)]} {set library $::env(OBCI_LIBRARY)}
puts "OceanBase Oracle driver: Oratcl [oceanbaseoraclecommon::load_driver $library] / OBCI"
exit
