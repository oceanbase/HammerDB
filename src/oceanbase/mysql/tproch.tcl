# OBMark 4.4.2 MySQL TPC-H layout, adapted for HammerDB and modern OB tablegroups.
# Source: plugins/tpch/4.4.2/create_tpch_mysql_table_part.ddl in oceanbase/obmark.
# Keep loader/query column names; inserts use explicit column lists.
namespace eval oceanbase::mysql {
    variable optimized_tproch_procedure {
proc CreateOceanBaseHTables {mysql_handler database partition_count} {
    set name [string tolower $database]
    regsub -all {[^a-z0-9_]} $name _ name
    set name [string range $name 0 43]
    set orders_group "hdb_${name}_h_orders_tg"
    set parts_group "hdb_${name}_h_parts_tg"
    foreach group [list $orders_group $parts_group] {
        mysqlexec $mysql_handler "CREATE TABLEGROUP IF NOT EXISTS $group SHARDING = 'PARTITION'"
    }
    mysqlexec $mysql_handler "CREATE TABLE LINEITEM (
    l_orderkey BIGINT NOT NULL,
    l_partkey BIGINT NOT NULL,
    l_suppkey INTEGER NOT NULL,
    l_linenumber INTEGER NOT NULL,
    l_quantity DECIMAL(15,2) NOT NULL,
    l_extendedprice DECIMAL(15,2) NOT NULL,
    l_discount DECIMAL(15,2) NOT NULL,
    l_tax DECIMAL(15,2) NOT NULL,
    l_returnflag char(1) DEFAULT NULL,
    l_linestatus char(1) DEFAULT NULL,
    l_shipdate date NOT NULL,
    l_commitdate date DEFAULT NULL,
    l_receiptdate date DEFAULT NULL,
    l_shipinstruct char(25) DEFAULT NULL,
    l_shipmode char(10) DEFAULT NULL,
    l_comment varchar(44) DEFAULT NULL,
primary key(l_shipdate, l_orderkey, l_linenumber)
)row_format = condensed
tablegroup = $orders_group
partition by key (l_orderkey) partitions $partition_count with column group(each column)"
    mysqlexec $mysql_handler "CREATE TABLE ORDERS (
    o_orderkey BIGINT NOT NULL,
    o_custkey BIGINT NOT NULL,
    o_orderstatus char(1) DEFAULT NULL,
    o_totalprice DECIMAL(15,2) DEFAULT NULL,
    o_orderdate date NOT NULL,
    o_orderpriority char(15) DEFAULT NULL,
    o_clerk char(15) DEFAULT NULL,
    o_shippriority INTEGER DEFAULT NULL,
    o_comment varchar(79) DEFAULT NULL,
PRIMARY KEY (o_orderkey, o_orderdate)
)row_format = condensed
tablegroup = $orders_group
partition by key(o_orderkey) partitions $partition_count with column group(each column)"
    mysqlexec $mysql_handler "CREATE TABLE PARTSUPP (
    ps_partkey BIGINT NOT NULL,
    ps_suppkey INTEGER NOT NULL,
    ps_availqty INTEGER DEFAULT NULL,
    ps_supplycost DECIMAL(15,2) DEFAULT NULL,
    ps_comment varchar(199) DEFAULT NULL,
    PRIMARY KEY (ps_partkey, ps_suppkey)) row_format = condensed
tablegroup $parts_group
partition by key(ps_partkey) partitions $partition_count with column group(each column)"
    mysqlexec $mysql_handler "CREATE TABLE PART (
  p_partkey BIGINT NOT NULL,
  p_name varchar(55) DEFAULT NULL,
  p_mfgr char(25) DEFAULT NULL,
  p_brand char(10) DEFAULT NULL,
  p_type varchar(25) DEFAULT NULL,
  p_size INTEGER DEFAULT NULL,
  p_container char(10) DEFAULT NULL,
  p_retailprice DECIMAL(15,2) DEFAULT NULL,
  p_comment varchar(23) DEFAULT NULL,
  PRIMARY KEY (p_partkey)) row_format = condensed
tablegroup $parts_group
partition by key(p_partkey) partitions $partition_count with column group(each column)"
    mysqlexec $mysql_handler "CREATE TABLE CUSTOMER (
  c_custkey BIGINT NOT NULL,
  c_name varchar(25) DEFAULT NULL,
  c_address varchar(40) DEFAULT NULL,
  c_nationkey INTEGER DEFAULT NULL,
  c_phone char(15) DEFAULT NULL,
  c_acctbal DECIMAL(15,2) DEFAULT NULL,
  c_mktsegment char(10) DEFAULT NULL,
  c_comment varchar(117) DEFAULT NULL,
  PRIMARY KEY (c_custkey)) row_format = condensed
partition by key(c_custkey) partitions $partition_count with column group(each column)"
    mysqlexec $mysql_handler "CREATE TABLE SUPPLIER (
  s_suppkey INTEGER NOT NULL,
  s_name char(25) DEFAULT NULL,
  s_address varchar(40) DEFAULT NULL,
  s_nationkey INTEGER DEFAULT NULL,
  s_phone char(15) DEFAULT NULL,
  s_acctbal DECIMAL(12,2) DEFAULT NULL,
  s_comment varchar(101) DEFAULT NULL,
  PRIMARY KEY (s_suppkey)
) row_format = condensed  partition by key(s_suppkey) partitions $partition_count with column group(each column)"
    mysqlexec $mysql_handler "CREATE TABLE NATION (
  n_nationkey INTEGER NOT NULL,
  n_name char(25) DEFAULT NULL,
  n_regionkey INTEGER DEFAULT NULL,
  n_comment varchar(152) DEFAULT NULL,
  PRIMARY KEY (n_nationkey)
) row_format = condensed with column group(each column)"
    mysqlexec $mysql_handler "CREATE TABLE REGION (
  r_regionkey INTEGER NOT NULL,
  r_name char(25) DEFAULT NULL,
  r_comment varchar(152) DEFAULT NULL,
  PRIMARY KEY (r_regionkey)
) row_format = condensed with column group(each column)"
}
    }

    proc rewrite_optimized_tproch {script partition_count} {
        variable optimized_tproch_procedure
        if {![string is integer -strict $partition_count] || $partition_count < 1 || $partition_count > 8192} {
            error "OceanBase TPROC-H partition count must be an integer from 1 to 8192"
        }
        set original {CreateTables $mysql_handler $mysql_tpch_storage_engine}
        set marker {proc CreateTables }
        if {[string first $original $script] < 0 || [string first $marker $script] < 0} {
            error "Cannot locate TPROC-H table creation in the generated script"
        }
        set replacement "CreateOceanBaseHTables \$mysql_handler \$db $partition_count"
        set script [string map [list $original $replacement] $script]
        return [string map [list $marker "$optimized_tproch_procedure\n$marker"] $script]
    }
}
