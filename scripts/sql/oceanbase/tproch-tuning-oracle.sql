-- OceanBase ORACLE tenant: executable HammerDB TPROC-H benchmark profile.
-- Target: OceanBase 4.4.2; check parameter availability on other versions.
-- Run the executable sections as an administrator of the BUSINESS Oracle
-- tenant used by HammerDB (SYS in that tenant, or another authorized admin).
-- SYS is a USER inside this tenant, not the cluster's sys TENANT / root@sys.
-- Do not run against the OCP metadata tenant. No statement switches tenants.
-- The optional outline section instead requires the actual benchmark user.
-- Its CREATE/DROP outline and dictionary grants are listed in README.md here.
-- Example (obclient prompts for the password; do not use --force):
-- obclient -h HOST -P PORT -u 'SYS@ORACLE_TENANT' -p --batch \
--   < scripts/sql/oceanbase/tproch-tuning-oracle.sql > tproch-oracle-tuning.log
-- For a Cloud endpoint, use its business-tenant admin name, e.g. TEST, and
-- the same SSL/CA connection arguments as the working HammerDB connection.
-- Keep the first result sets for restoration. Statements are not atomic:
-- if one fails, earlier changes remain applied. Candidates are not measured gains.

-- 1. CAPTURE BASELINE (business-tenant administrator)
SELECT BANNER FROM V$VERSION;
SELECT USER FROM DUAL;
SHOW GLOBAL VARIABLES WHERE Variable_name IN
  ('ob_compatibility_mode', 'ob_query_timeout', 'ob_trx_timeout',
   'max_allowed_packet', 'ob_sql_work_area_percentage', 'parallel_servers_target',
   'parallel_degree_policy', 'parallel_degree_limit');
SHOW SESSION VARIABLES WHERE Variable_name IN
  ('ob_query_timeout', 'ob_trx_timeout', 'ob_sql_work_area_percentage',
   'parallel_servers_target', 'parallel_degree_policy', 'parallel_degree_limit');
SHOW PARAMETERS WHERE name IN
  ('spill_compression_codec', 'default_table_store_format');

-- 2. ANALYTICAL-WORKLOAD CANDIDATES (same values as the MySQL profile)
-- OceanBase supports SET GLOBAL / SET SESSION for these variables in Oracle
-- mode too. GLOBAL initializes new connections; SESSION affects this one only.
-- Timeouts are microseconds: query = 10800 seconds, transaction = 10000 seconds.
-- A transaction can therefore expire first. These limits do not speed up work.
SET GLOBAL ob_query_timeout = 10800000000;
SET SESSION ob_query_timeout = 10800000000;
SET GLOBAL ob_trx_timeout = 10000000000;
SET SESSION ob_trx_timeout = 10000000000;
SET GLOBAL max_allowed_packet = 67108864;

-- SQL work-area cap: 50% of tenant memory shared by operators, not per query.
SET GLOBAL ob_sql_work_area_percentage = 50;
ALTER SYSTEM SET spill_compression_codec = 'LZ4';
-- PX admission/queuing target per server, not a DOP or 10000 started workers.
-- Size it for the tenant and simultaneous query streams.
SET GLOBAL parallel_servers_target = 10000;

-- Only NEW tables without an explicit override use this storage default.
-- Existing tables are not converted; restoring the default does not undo DDL.
-- Apply before a fresh build. Inspect DBMS_METADATA.GET_DDL
-- afterward rather than the MySQL SHOW CREATE TABLE command.
ALTER SYSTEM SET default_table_store_format = 'column';

-- 3. PARALLEL QUERY AND HAMMERDB SESSION SETTINGS
SET GLOBAL parallel_degree_limit = 8;
SET SESSION parallel_degree_limit = 8;
SET GLOBAL parallel_degree_policy = 'AUTO';
SET SESSION parallel_degree_policy = 'AUTO';
-- Unlike the MySQL driver, the Oracle query driver explicitly issues ALTER
-- SESSION FORCE PARALLEL QUERY with its degree_of_parallel value. With the AUTO
-- policy in this profile, Auto DOP still chooses query DOP (unless overridden by
-- SQL hints); the GUI value does not guarantee that fixed DOP. This matches the
-- MySQL profile's strategy. Auto DOP may choose serial execution.
-- For a separate MANUAL-policy experiment, set the tenant policy to MANUAL and
-- configure Driver Script Options > Degree of Parallelism, for example:
--   diset tpch degree_of_parallel 8
-- Use a lower value for smaller tenants / more VUs. The Auto DOP limit above
-- does not cap fixed DOP under MANUAL. Regenerate the driver, check the actual
-- plan and record the chosen strategy; do not mix AUTO and MANUAL comparisons.

-- HammerDB also overrides SESSION ob_query_timeout on EVERY connection. Set
-- Connection > Query timeout to 10800 seconds and regenerate the build/query
-- driver, or use BEFORE buildschema/loadscript:
--   diset connection ob_query_timeout 10800
-- Reconnect loaders/VUs after GLOBAL changes. Let statistics collection finish
-- and run Schema Check. Optional statistics retry AFTER loading, logged in as
-- the BENCHMARK USER in the same tenant (Oracle has no USE database):
-- CALL DBMS_STATS.GATHER_SCHEMA_STATS(USER);

-- 4. VERIFY / RESTORE (business-tenant administrator)
SHOW GLOBAL VARIABLES WHERE Variable_name IN
  ('ob_query_timeout', 'ob_trx_timeout', 'max_allowed_packet',
   'ob_sql_work_area_percentage', 'parallel_servers_target',
   'parallel_degree_policy', 'parallel_degree_limit');
SHOW SESSION VARIABLES WHERE Variable_name IN
  ('ob_query_timeout', 'ob_trx_timeout', 'parallel_degree_policy',
   'parallel_degree_limit');
SHOW PARAMETERS WHERE name IN
  ('spill_compression_codec', 'default_table_store_format');
-- Restore the FIRST recorded values with the SAME SET GLOBAL / SET SESSION /
-- ALTER SYSTEM scope. Reconnect VUs, restore HammerDB timeout/DOP and regenerate
-- its driver. Record SF, storage, VUs, actual DOP, topology and Job ID.

-- 5. OPTIONAL Q7 DATE-INDEX OUTLINE (DISABLED BY DEFAULT)
-- Execute ONLY the selected statements below as the BENCHMARK USER, in the
-- SAME Oracle business tenant. Reconnect as that user; changing CURRENT_SCHEMA
-- on an admin connection is not a substitute for the correct user context.
-- First build a Distributed schema with HDB_LINEITEM_SHIPDATE_COVER_IDX, run
-- the ORIGINAL Q7 once and compare the index/default paths on identical inputs.
-- Do not source the whole tuning file merely to apply an outline.
-- Sourcing this file creates no outline. Keep explanatory prose commented.
--
-- SELECT USER FROM DUAL;
-- SELECT INDEX_NAME, COLUMN_POSITION, COLUMN_NAME
-- FROM USER_IND_COLUMNS
-- WHERE TABLE_NAME = 'LINEITEM'
--   AND INDEX_NAME = 'HDB_LINEITEM_SHIPDATE_COVER_IDX'
-- ORDER BY COLUMN_POSITION;
-- SELECT p.SVR_IP, p.PLAN_ID, p.SQL_ID, p.STATEMENT
-- FROM SYS.GV$OB_PLAN_CACHE_PLAN_STAT p
-- WHERE p.DB_ID IN (SELECT DB_ID FROM SYS.GV$OB_SQL_AUDIT WHERE DB_NAME = USER)
--   AND LOWER(p.STATEMENT) LIKE
--       'select supp_nation, cust_nation, l_year, sum(volume) as revenue%';
-- STATEMENT is a CLOB in Oracle mode, so do not SELECT DISTINCT it.
-- Inspect existing outlines before binding; do not replace one blindly.
-- SELECT OUTLINE_NAME, SQL_ID, OUTLINE_ID
-- FROM SYS.DBA_OB_OUTLINES WHERE DATABASE_NAME = USER;
-- Replace <Q7_SQL_ID> with the SQL_ID observed in THIS Oracle schema. Do not
-- copy the MySQL example ID: the native drivers have different SQL text/casing.
-- The INDEX hint syntax is shared; SEL$2 targets Q7's inner LINEITEM block.
-- SQL_ID outlines override existing SQL hints; recheck the entire resulting plan.
-- CREATE OUTLINE hdb_tpch_q7_shipdate_idx
--   ON '<Q7_SQL_ID>'
--   USING HINT /*+ INDEX(@SEL$2 LINEITEM HDB_LINEITEM_SHIPDATE_COVER_IDX) */;
--
-- Reconnect as the same user and rerun ORIGINAL Q7, without adding an INDEX hint
-- to the query. Verify OUTLINE_ID and the actual covering-index access path:
-- SELECT p.SVR_IP, p.PLAN_ID, p.SQL_ID, p.OUTLINE_ID, p.OUTLINE_DATA
-- FROM SYS.GV$OB_PLAN_CACHE_PLAN_STAT p
-- JOIN SYS.DBA_OB_OUTLINES o
--   ON p.TENANT_ID = o.TENANT_ID AND p.DB_ID = o.DATABASE_ID
--  AND p.OUTLINE_ID = o.OUTLINE_ID
-- WHERE o.DATABASE_NAME = USER
--   AND o.OUTLINE_NAME = 'HDB_TPCH_Q7_SHIPDATE_IDX';
-- Inspect those PLAN_IDs in SYS.GV$OB_PLAN_CACHE_PLAN_EXPLAIN and compare actual
-- executions in SYS.GV$OB_SQL_AUDIT. EXPLAIN alone does not prove binding.
-- Rollback ONLY this optional outline, reconnect and recheck the original Q7:
-- DROP OUTLINE hdb_tpch_q7_shipdate_idx;
-- References:
-- https://docs.oceanbase.com/oceanbase-database/V4.4.2-create-outline-oracle-compatible-mode
-- https://docs.oceanbase.com/oceanbase-database/V4.4.2-system-management-set-variables
-- Diagnostics, internal parameters, OBProxy, durability, replicas, resource
-- pools and existing table DDL are not changed by this profile.
