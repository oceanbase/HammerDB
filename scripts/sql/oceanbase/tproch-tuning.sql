-- OceanBase MySQL tenant: executable HammerDB TPROC-H benchmark profile.
-- Target: OceanBase 4.4.2; check availability before using other versions.
-- Reference: obmark plugins/tpch/4.4.2/optimize.py delegates to the AP profile
-- in plugins/oceanbase/4.4.2/optimize.py; packet size also appears in
-- plugins/tpch/4.4.2/run_test.py. Local source revision:
-- 26d44a0488cf91e8ca64e1c956f84f991bcd1150.
-- These are benchmark candidates, not production defaults or measured gains.
-- Apply to a dedicated BUSINESS MySQL tenant as its administrator, not root@sys
-- or the OCP metadata tenant. Apply before schema creation and between runs.
-- Example (obclient prompts for the password; do not use --force):
-- obclient -h HOST -P PORT -u 'root@TENANT' -p --batch \
--   < scripts/sql/oceanbase/tproch-tuning.sql > tproch-tuning.log
-- The first result sets capture your baseline; keep the log for restoration.
-- Statements are not atomic: if one fails, earlier changes remain applied.

-- 1. CAPTURE BASELINE
SELECT VERSION(), CURRENT_USER();
SHOW GLOBAL VARIABLES WHERE Variable_name IN
  ('ob_query_timeout', 'ob_trx_timeout', 'max_allowed_packet',
   'ob_sql_work_area_percentage', 'parallel_servers_target',
   'parallel_degree_policy', 'parallel_degree_limit');
SHOW SESSION VARIABLES WHERE Variable_name IN
  ('ob_query_timeout', 'ob_trx_timeout', 'ob_sql_work_area_percentage',
   'parallel_servers_target', 'parallel_degree_policy', 'parallel_degree_limit');
SHOW PARAMETERS WHERE name IN
  ('spill_compression_codec', 'default_table_store_format');

-- 2. OBMARK AP VALUES
-- Timeouts are microseconds: query = 10800 seconds (3 hours), transaction =
-- 10000 seconds. These are the distinct obmark values; a transaction can expire
-- before the query timeout. Long limits permit long work, not faster work.
SET GLOBAL ob_query_timeout = 10800000000;
SET SESSION ob_query_timeout = 10800000000;
SET GLOBAL ob_trx_timeout = 10000000000;
SET SESSION ob_trx_timeout = 10000000000;
SET GLOBAL max_allowed_packet = 67108864;

-- Work-area cap is 50% of tenant memory, shared by SQL operators, not 50% per
-- query. Check memory pressure and spill activity, especially with multiple VUs.
SET GLOBAL ob_sql_work_area_percentage = 50;
SET SESSION ob_sql_work_area_percentage = 50;
ALTER SYSTEM SET spill_compression_codec = 'LZ4';

-- obmark's benchmark PX queuing target. This is a worker admission/queuing
-- threshold per server, NOT a DOP or a command to start 10000 workers. It can
-- substantially relax queuing; size it down for concurrent query streams.
SET GLOBAL parallel_servers_target = 10000;
SET SESSION parallel_servers_target = 10000;

-- Applies to NEW tables without an explicit storage-format override. Existing
-- TPROC-H tables are not converted. For a column-store comparison, apply before
-- building a fresh schema and verify SHOW CREATE TABLE afterward. Restoring this
-- parameter does not convert tables back. Do not mix row/column results silently.
ALTER SYSTEM SET default_table_store_format = 'column';

-- 3. HAMMERDB PARALLEL-QUERY ADAPTATION (not an obmark optimizer value)
-- The independent OceanBase category reuses MySQL query text, so the PX target
-- alone does not enable parallel queries. Use public Auto DOP rather than private
-- _force_parallel_query_dop. Start with an explicit DOP ceiling of 8; lower it
-- for smaller tenants / many simultaneous VUs, and test higher values separately.
-- Auto DOP may choose less than 8, including serial execution. Check EXPLAIN for
-- representative queries; query hints can override this policy. Reconnect VUs.
SET GLOBAL parallel_degree_limit = 8;
SET SESSION parallel_degree_limit = 8;
SET GLOBAL parallel_degree_policy = 'AUTO';
SET SESSION parallel_degree_policy = 'AUTO';

-- HammerDB overrides SESSION ob_query_timeout on EVERY connection. Also set
-- Connection > Query timeout to 10800 seconds, then regenerate the build/query
-- driver. CLI equivalent BEFORE buildschema/loadscript:
--   diset connection ob_query_timeout 10800
-- GLOBAL changes only initialize new connections; reconnect loaders and VUs.
-- After loading, let statistics collection finish and run Schema Check before
-- measurement. For an existing schema, an optional statistics retry is:
-- USE tpch; -- replace with your configured database
-- ANALYZE TABLE orders, partsupp, customer, part, supplier, nation, region, lineitem;

-- 4. VERIFY APPLIED VALUES / RESTORE
SHOW GLOBAL VARIABLES WHERE Variable_name IN
  ('ob_query_timeout', 'ob_trx_timeout', 'max_allowed_packet',
   'ob_sql_work_area_percentage', 'parallel_servers_target',
   'parallel_degree_policy', 'parallel_degree_limit');
SHOW PARAMETERS WHERE name IN
  ('spill_compression_codec', 'default_table_store_format');
-- Restore each changed value from the FIRST result sets in tproch-tuning.log,
-- using the same SET GLOBAL / SET SESSION / ALTER SYSTEM scope. Reconnect VUs,
-- restore HammerDB's connection timeout, and regenerate its driver as well.
-- Changing storage defaults back only affects subsequent table creation.
-- Record SF, storage format, VUs, DOP/policy, topology, query times and Job ID.
-- Keep them fixed for baseline comparisons; vary one knob at a time afterward.

-- Preserve SQL Audit, performance events and trace diagnostics for analysis.
-- obmark also disables diagnostics, changes internal underscore parameters,
-- collations and plan-baseline capture/use. Those are not applied here, nor are
-- OBProxy, durability, replica topology, resource pools or existing table DDL.
-- Public parameter references:
-- https://www.oceanbase.com/docs/common-oceanbase-database-cn-1000000005285836
-- https://www.oceanbase.com/docs/common-oceanbase-database-cn-1000000005282373
-- https://www.oceanbase.com/docs/common-oceanbase-database-cn-1000000003979524
