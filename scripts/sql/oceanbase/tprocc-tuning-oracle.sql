-- OceanBase ORACLE tenant: executable HammerDB TPROC-C benchmark tuning.
-- Target: OceanBase 4.4.2; check parameter availability on other versions.
-- Run the executable sections as an administrator of the BUSINESS Oracle
-- tenant used by HammerDB (SYS in that tenant, or another authorized admin).
-- SYS is a USER inside this tenant, not the cluster's sys TENANT / root@sys.
-- Do not run against the OCP metadata tenant. No statement switches tenants.
-- The optional outline section instead requires the actual benchmark user.
-- Its CREATE/DROP outline and dictionary grants are listed in README.md here.
-- Example (obclient prompts for the password; do not use --force):
-- obclient -h HOST -P PORT -u 'SYS@ORACLE_TENANT' -p --batch \
--   < scripts/sql/oceanbase/tprocc-tuning-oracle.sql > tprocc-oracle-tuning.log
-- For a Cloud endpoint, use its business-tenant admin name, e.g. TEST, and
-- the same SSL/CA connection arguments as the working HammerDB connection.
-- Keep the first result sets for restoration. Statements are not atomic:
-- if one fails, earlier changes remain applied. Candidates are not measured gains.

-- 1. CAPTURE BASELINE (business-tenant administrator)
SELECT BANNER FROM V$VERSION;
SELECT USER FROM DUAL;
SHOW GLOBAL VARIABLES WHERE Variable_name IN
  ('ob_compatibility_mode', 'ob_query_timeout', 'ob_trx_timeout',
   'max_allowed_packet', 'ob_sql_work_area_percentage', 'parallel_servers_target');
SHOW SESSION VARIABLES WHERE Variable_name = 'ob_query_timeout';
SHOW PARAMETERS WHERE name IN
  ('freeze_trigger_percentage', 'cpu_quota_concurrency',
   'workers_per_cpu_quota', 'enable_early_lock_release',
   'writing_throttling_trigger_percentage');

-- 2. BUILD / STATISTICS COLLECTION
-- These values match the MySQL profile. OceanBase also supports SET GLOBAL /
-- SET SESSION for these variables in Oracle mode. GLOBAL initializes new
-- connections; SESSION affects only this SQL connection.
-- HammerDB overrides ob_query_timeout on EVERY connection. Also set Connection
-- > Query timeout to 600 seconds and regenerate the build driver, or use:
--   diset connection ob_query_timeout 600
SET GLOBAL ob_query_timeout = 600000000;
SET SESSION ob_query_timeout = 600000000;
SET GLOBAL max_allowed_packet = 67108864;
-- Query timeout does not extend an already-open transaction. Extend transaction
-- timeout only if a single transaction needs it:
-- SET GLOBAL ob_trx_timeout = 600000000;
-- SET SESSION ob_trx_timeout = 600000000;

-- Optional statistics retry, AFTER all loaders finish, logged in as the
-- BENCHMARK USER in this same tenant. Oracle uses schemas, not USE database.
-- This matches the Oracle builder's statistics collection:
-- CALL DBMS_STATS.GATHER_SCHEMA_STATS(USER);
-- Then run HammerDB Schema Check before starting a timed benchmark.

-- 3. MEASUREMENT PROFILE (business-tenant administrator)
-- Apply between runs and reconnect VUs. Match warehouses, driver, duration and
-- topology to the baseline. No workload SQL or commit boundaries are changed.
ALTER SYSTEM SET freeze_trigger_percentage = 50;
-- Keep workers_per_cpu_quota greater than this concurrency candidate.
ALTER SYSTEM SET cpu_quota_concurrency = 2;
ALTER SYSTEM SET enable_early_lock_release = false;

-- The MySQL profile's default_auto_increment_mode / auto_increment_cache_size
-- settings are omitted: HammerDB's Oracle schema does not use AUTO_INCREMENT.
-- They are not Oracle SEQUENCE settings and do not tune district.d_next_o_id.
-- As in the MySQL profile, write-throttling changes are optional, not applied:
-- ALTER SYSTEM SET writing_throttling_trigger_percentage = 100;
-- Work-area/PX sizing, diagnostic disabling, private parameters, durability,
-- locality and replica changes are not included in this TPROC-C profile.

-- 4. VERIFY / RESTORE (business-tenant administrator)
SHOW GLOBAL VARIABLES WHERE Variable_name IN
  ('ob_query_timeout', 'max_allowed_packet');
SHOW SESSION VARIABLES WHERE Variable_name = 'ob_query_timeout';
SHOW PARAMETERS WHERE name IN
  ('freeze_trigger_percentage', 'cpu_quota_concurrency',
   'enable_early_lock_release');
-- Restore the FIRST recorded values with the SAME SET GLOBAL / SET SESSION /
-- ALTER SYSTEM scope. Reconnect loaders/VUs, restore HammerDB's connection
-- timeout and regenerate its driver. Record the settings with the Job ID.

-- 5. OPTIONAL STOCK-LEVEL OUTLINE (DISABLED BY DEFAULT)
-- Execute ONLY the selected statements below as the BENCHMARK USER, in the
-- SAME Oracle business tenant. Reconnect as that user; changing CURRENT_SCHEMA
-- on an admin connection is not a substitute for the correct user context.
-- Do not source the whole tuning file merely to apply an outline.
-- Oracle SLEV joins DISTRICT, ORDER_LINE and STOCK; the MySQL SLEV SQL_ID,
-- two-table join hint and PRIMARY index names must not be copied to this mode.
-- This is a candidate access path; compare identical inputs/results before use.
-- Sourcing this file creates no outline. Keep explanatory prose commented.
--
-- SELECT USER FROM DUAL;
-- SELECT i.TABLE_NAME, i.INDEX_NAME, c.COLUMN_POSITION, c.COLUMN_NAME
-- FROM USER_INDEXES i JOIN USER_IND_COLUMNS c ON i.INDEX_NAME = c.INDEX_NAME
-- WHERE i.TABLE_NAME IN ('DISTRICT', 'ORDER_LINE', 'STOCK')
-- ORDER BY i.TABLE_NAME, i.INDEX_NAME, c.COLUMN_POSITION;
-- Ordinary schema: DISTRICT_I1, IORDL, STOCK_I1.
-- Distributed schema: HDB_DISTRICT_PK, IORDL, HDB_STOCK_PK.
-- Verify actual names and key columns; replace the names in the hint if needed.
-- Run an unmodified SLEV call once to populate the cache. This PL/SQL block
-- works in obclient; the slash terminates the block, not a HammerDB command.
-- DECLARE
--   stock_count NUMBER;
-- BEGIN
--   SLEV(1, 1, 10, stock_count);
-- END;
-- /
-- SELECT p.SVR_IP, p.PLAN_ID, p.SQL_ID, p.STATEMENT
-- FROM SYS.GV$OB_PLAN_CACHE_PLAN_STAT p
-- WHERE p.DB_ID IN (SELECT DB_ID FROM SYS.GV$OB_SQL_AUDIT WHERE DB_NAME = USER)
--   AND LOWER(p.STATEMENT) LIKE '%count(distinct%'
--   AND LOWER(p.STATEMENT) LIKE '%order_line%'
--   AND LOWER(p.STATEMENT) LIKE '%stock%'
--   AND LOWER(p.STATEMENT) LIKE '%district%';
-- Inspect the INTERNAL SELECT and use its SQL_ID, not the outer PL/SQL block's
-- ID. STATEMENT is a CLOB in Oracle mode, so do not SELECT DISTINCT it.
-- Inspect existing outlines before binding; do not replace one blindly.
-- SELECT OUTLINE_NAME, SQL_ID, OUTLINE_ID
-- FROM SYS.DBA_OB_OUTLINES WHERE DATABASE_NAME = USER;
-- Replace <SLEV_SQL_ID> below with the ID from this Oracle schema. The hint
-- below uses ordinary-schema index names; adapt them using the lookup above.
-- CREATE OUTLINE hdb_tpcc_slev_plan
--   ON '<SLEV_SQL_ID>'
--   USING HINT /*+ LEADING(district order_line stock) USE_NL(order_line stock)
--                  INDEX(district DISTRICT_I1) INDEX(order_line IORDL)
--                  INDEX(stock STOCK_I1) */;
--
-- Reconnect as the same benchmark user and rerun the original SLEV call.
-- Verify the internal SELECT's OUTLINE_ID and actual index/join paths:
-- SELECT p.SVR_IP, p.PLAN_ID, p.SQL_ID, p.PLAN_HASH,
--        p.OUTLINE_ID, p.OUTLINE_DATA, p.HINTS_ALL_WORKED
-- FROM SYS.GV$OB_PLAN_CACHE_PLAN_STAT p
-- JOIN SYS.DBA_OB_OUTLINES o
--   ON p.TENANT_ID = o.TENANT_ID AND p.DB_ID = o.DATABASE_ID
--  AND p.OUTLINE_ID = o.OUTLINE_ID
-- WHERE o.DATABASE_NAME = USER
--   AND o.OUTLINE_NAME = 'HDB_TPCC_SLEV_PLAN';
-- Use these PLAN_IDs in SYS.GV$OB_PLAN_CACHE_PLAN_EXPLAIN and compare actual
-- executions in SYS.GV$OB_SQL_AUDIT. EXPLAIN alone does not prove binding.
-- Rollback ONLY this optional outline, reconnect and recheck the original call:
-- DROP OUTLINE hdb_tpcc_slev_plan;
-- References:
-- https://docs.oceanbase.com/oceanbase-database/V4.4.2-create-outline-oracle-compatible-mode
-- https://docs.oceanbase.com/oceanbase-database/V4.4.2-system-management-set-variables
