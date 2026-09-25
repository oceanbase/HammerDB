# OceanBase defaults are applied after XML or SQLite loading. The shared XML
# parser deliberately retains its existing handling of empty elements.
namespace eval oceanbaseconfig {
    proc normalize {configuration} {
        set defaults {connection {ob_compatibility_mode mysql ob_cluster {}}}
        set mode mysql
        if {[dict exists $configuration connection ob_compatibility_mode]} {
            set mode [string tolower [dict get $configuration connection ob_compatibility_mode]]
        }
        if {$mode eq "mysql"} {
            dict set defaults tpcc ob_pass ""
            dict set defaults tpch ob_tpch_pass ""
        }
        dict for {group values} $defaults {
            dict for {key value} $values {
                if {![dict exists $configuration $group $key]} {
                    dict set configuration $group $key $value
                }
            }
        }
        return $configuration
    }
}
package provide oceanbaseconfig 1.0
