# OceanBase defaults are applied after XML or SQLite loading. The shared XML
# parser deliberately retains its existing handling of empty elements.
namespace eval oceanbaseconfig {
    proc initialize {configuration} {
        set normalized [normalize $configuration]
        if {$normalized ne $configuration} {
            package require sqlite3
            sqlite3 ::oceanbaseconfig::defaultsdb [CheckSQLiteDB oceanbase]
            try {
                defaultsdb transaction {
                    dict for {group values} $normalized {
                        dict for {key value} $values {
                            if {![dict exists $configuration $group $key]} {
                                # Groups are the fixed connection/tpcc/tpch defaults.
                                defaultsdb eval "CREATE TABLE IF NOT EXISTS ${group}(key TEXT, val TEXT)"
                                defaultsdb eval "INSERT INTO ${group}(key,val) VALUES(\$key,\$value)"
                            }
                        }
                    }
                }
            } finally {
                defaultsdb close
            }
        }
        return $normalized
    }

    proc normalize {configuration} {
        set defaults {connection {ob_compatibility_mode mysql ob_cluster {}}}
        set mode mysql
        if {[dict exists $configuration connection ob_compatibility_mode]} {
            set mode [string tolower [dict get $configuration connection ob_compatibility_mode]]
        }
        if {$mode eq "mysql"} {
            dict set defaults tpcc ob_pass ""
            dict set defaults tpcc ob_distributed_schema false
            dict set defaults tpcc ob_partition_count 24
            dict set defaults tpch ob_tpch_pass ""
            dict set defaults tpch ob_tpch_optimized_schema false
            dict set defaults tpch ob_tpch_partition_count 24
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
