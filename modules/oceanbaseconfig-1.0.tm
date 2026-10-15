# OceanBase defaults are applied after XML or SQLite loading. The shared XML
# parser deliberately retains its existing handling of empty elements.
namespace eval oceanbaseconfig {
    proc oracle_options {configuration} {
        # Keep Oracle options inside the OceanBase category, independently of
        # both its MySQL options and the native Oracle category.
        set defaults {
            connection {instance {} system_user sys system_password {} obci_library /u01/obclient/lib/libobci.so
                ob_ssl false ob_ssl_two_way false ob_ssl_linux_capath /etc/mysql/certs
                ob_ssl_windows_capath C:\mysql\certs ob_ssl_ca ca-cert.pem ob_ssl_cert client-cert.pem
                ob_ssl_key client-key.pem ob_ssl_cipher server}
            tpcc {tpcc_user tpcc tpcc_pass {} tpcc_def_tab users tpcc_ol_tab users tpcc_def_temp temp
                count_ware 1 num_vu 1 distributed_schema false partition_count 24 partition false hash_clusters false tpcc_tt_compat false
                total_iterations 10000000 raiseerror true keyandthink false checkpoint false
                ora_driver timed rampup 2 duration 5 allwarehouse false ora_timeprofile false
                async_scale false async_client 10 async_verbose false async_delay 1000 connect_pool false}
            tpch {tpch_user tpch tpch_pass {} tpch_def_tab users tpch_def_temp temp num_tpch_threads 1
                tpch_tt_compat false distributed_schema false partition_count 24 scale_fact 1 total_querysets 1 raise_query_error true verbose false
                degree_of_parallel 2 refresh_on false update_sets 1 trickle_refresh 1000
                refresh_verbose false cloud_query false}
        }
        if {[info exists ::env(OBCI_LIBRARY)] && $::env(OBCI_LIBRARY) ne ""} {
            dict set defaults connection obci_library $::env(OBCI_LIBRARY)
        }
        foreach {key value} {ob_host 127.0.0.1 ob_port 2881 ob_tenant {} ob_cluster {} ob_query_timeout 120} {
            if {[dict exists $configuration connection $key]} {set value [dict get $configuration connection $key]}
            dict set defaults connection $key $value
        }
        if {[dict exists $configuration connection ob_oracle_options]} {
            dict for {group values} [dict get $configuration connection ob_oracle_options] {
                if {$group ni {connection tpcc tpch}} {error "Unknown OceanBase Oracle options group: $group"}
                dict set defaults $group [dict merge [dict get $defaults $group] $values]
            }
        }
        return $defaults
    }

    proc merge_registry {saved defaults} {
        # Keep saved categories intact; add only categories introduced by XML.
        set defaults [regsub -all {(TP)(RO)(C-[CH])} $defaults {\1\3}]
        set missing {}
        dict for {name values} $defaults {
            if {![dict exists $saved $name]} {
                dict set missing $name $values
            }
        }
        if {[dict size $missing]} {
            package require sqlite3
            sqlite3 ::oceanbaseconfig::registrydb [CheckSQLiteDB database]
            try {
                registrydb timeout 30000
                registrydb transaction {
                    dict for {name values} $missing {
                        if {![regexp {^[a-z][a-z0-9_]*$} $name]} {error "Invalid database category: $name"}
                        registrydb eval "CREATE TABLE IF NOT EXISTS ${name}(key TEXT, val TEXT)"
                        dict for {key value} $values {
                            registrydb eval "INSERT INTO ${name}(key,val) VALUES(\$key,\$value)"
                        }
                    }
                }
            } finally {
                registrydb close
            }
        }
        return [dict merge $saved $missing]
    }

    proc save {configuration {counter {}}} {
        package require sqlite3
        sqlite3 ::oceanbaseconfig::savedb [CheckSQLiteDB oceanbase]
        try {
            savedb timeout 30000
            if {[dict size $counter]} {
                set generic_file [CheckSQLiteDB generic]
                savedb eval {ATTACH DATABASE $generic_file AS generic_config}
            }
            savedb transaction {
                dict for {group values} $configuration {
                    if {$group ni {connection tpcc tpch}} {error "Unknown OceanBase configuration group: $group"}
                    savedb eval "CREATE TABLE IF NOT EXISTS ${group}(key TEXT, val TEXT)"
                    savedb eval "DELETE FROM ${group}"
                    dict for {key value} $values {
                        savedb eval "INSERT INTO ${group}(key,val) VALUES(\$key,\$value)"
                    }
                }
                dict for {key value} $counter {
                    if {$key ni {tc_refresh_rate tc_log_to_temp tc_unique_log_name tc_log_timestamps} || ![string is integer -strict $value]} {
                        error "Invalid transaction counter option: $key"
                    }
                    savedb eval {UPDATE generic_config.transaction_counter SET val=$value WHERE key=$key}
                    if {[savedb changes] == 0} {savedb eval {INSERT INTO generic_config.transaction_counter(key,val) VALUES($key,$value)}}
                }
            }
        } finally {
            savedb close
        }
    }

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
        set defaults {connection {ob_compatibility_mode mysql ob_cluster {} ob_oracle_options {}}}
        set mode mysql
        if {[dict exists $configuration connection ob_compatibility_mode]} {
            set mode [string tolower [dict get $configuration connection ob_compatibility_mode]]
        }
        if {$mode eq "mysql"} {
            dict set defaults tpcc ob_pass ""
            dict set defaults tpcc ob_distributed_schema false
            dict set defaults tpcc ob_partition_count 24
            foreach {key value} {ob_history_pk false ob_async_scale false ob_async_client 10 ob_async_verbose false ob_async_delay 1000 ob_connect_pool false} {
                dict set defaults tpcc $key $value
            }
            dict set defaults tpch ob_tpch_pass ""
            dict set defaults tpch ob_tpch_optimized_schema false
            dict set defaults tpch ob_tpch_partition_count 24
            dict set defaults tpch ob_cloud_query false
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
