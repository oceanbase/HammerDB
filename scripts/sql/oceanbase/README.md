# OceanBase benchmark tuning scripts

Choose the file for the **business tenant's compatibility mode**. These files
run in `obclient`, not the HammerDB Tcl console. They do not switch tenants,
create a tenant or run a benchmark. Applying a profile changes settings; it is
not a read-only compatibility check.

| Workload | MySQL tenant | Oracle tenant |
| --- | --- | --- |
| TPROC-C | [tprocc-tuning-mysql.sql](tprocc-tuning-mysql.sql) | [tprocc-tuning-oracle.sql](tprocc-tuning-oracle.sql) |
| TPROC-H | [tproch-tuning-mysql.sql](tproch-tuning-mysql.sql) | [tproch-tuning-oracle.sql](tproch-tuning-oracle.sql) |

## Where to run each section

| Section | Tenant | Login and database/schema | Scope |
| --- | --- | --- | --- |
| Executable baseline, parameter/variable changes, verification | The **business tenant used by HammerDB** | Its administrator: e.g. `root@TENANT` for MySQL; `SYS@TENANT` or another authorized administrator for Oracle | `SET GLOBAL` initializes subsequent connections throughout this tenant; `ALTER SYSTEM SET` changes tenant parameters; `SET SESSION` affects this SQL connection only. |
| Commented statistics retry | The same business tenant | MySQL: select the benchmark database with `USE`; Oracle: log in as the benchmark schema's user | Only that benchmark database/schema. |
| Commented outline lookup/create/verify/drop | The same business tenant | The actual benchmark user. MySQL: also `USE` the benchmark database. Oracle: log in as the benchmark user, rather than only changing an admin connection's `CURRENT_SCHEMA`. | The corresponding database/schema's SQL. Install separately for each configured benchmark database/schema. |

**Do not execute these files in the cluster's `sys` tenant (`root@sys`) or the
OCP metadata tenant.** An Oracle tenant's `SYS` **user** belongs to that Oracle
business tenant; it is not the cluster's `sys` tenant. A Cloud endpoint may use
a bare administrator name, such as `TEST`, because the endpoint selects the
tenant. The administrator needs permission to change the listed tenant
settings; a benchmark user may separately need permission to read diagnostic
views and create outlines.

For Oracle's optional outline examples, have the business-tenant administrator
authorize the benchmark user first (replace `HDB_BENCH_USER`):

```sql
GRANT CREATE ANY OUTLINE TO HDB_BENCH_USER;
GRANT DROP ANY OUTLINE TO HDB_BENCH_USER;
GRANT SELECT ON SYS.DBA_OB_OUTLINES TO HDB_BENCH_USER;
```

Creation and rollback require separate privileges. These grants are not part of
the executable tuning profiles. The normal schema builder does not grant
outline-management privileges. Reconnect as the benchmark
user to create the outline in its schema; use the administrator for any grants
or later privilege removal.

From the repository/release directory, choose one file, for example:

```sh
# MySQL business-tenant administrator
obclient -h HOST -P PORT -u 'root@TENANT' -p --batch \
  < scripts/sql/oceanbase/tproch-tuning-mysql.sql > tproch-tuning.log

# Oracle business-tenant administrator
obclient -h HOST -P PORT -u 'SYS@TENANT' -p --batch \
  < scripts/sql/oceanbase/tproch-tuning-oracle.sql > tproch-oracle-tuning.log
```

Use the correct endpoint, tenant/cluster-qualified login and SSL/CA arguments
for your environment. Keep the initial baseline output; the scripts are not
atomic, and an error does not undo earlier statements. Do not use `--force`.
Reconnect HammerDB VUs after global changes, set its connection query timeout
to the documented value, and regenerate its driver. Restore recorded values
at the same scope after the experiment.

## Why the modes have separate files

The shared parameters keep the same candidate values. The files differ where
SQL, schema or driver behavior differs:

| Area | MySQL | Oracle |
| --- | --- | --- |
| Identity/version | `SELECT VERSION(), CURRENT_USER()` | `SELECT BANNER FROM V$VERSION`; `SELECT USER FROM DUAL` |
| Statistics/database selection | `USE`; `ANALYZE TABLE` | Log in as the schema user; `DBMS_STATS.GATHER_SCHEMA_STATS` |
| Diagnostic views/text | `oceanbase.*`; statement text supports the existing `DISTINCT` lookup | `SYS.*`; `STATEMENT` is a CLOB, so its lookup does not use `DISTINCT` |
| Stock-Level outline | Native MySQL SLEV's two-table SELECT, MySQL SQL_ID and `PRIMARY` index names | Native Oracle SLEV's three-table SELECT including DISTRICT; discover its own SQL_ID and actual index names, including distributed-schema differences |
| Q7 outline | MySQL query text/SQL_ID | Oracle query text/SQL_ID; the query-block `INDEX` hint syntax is shared |
| Auto-increment settings | Retained from the existing profile | Omitted: the Oracle HammerDB schema does not use MySQL `AUTO_INCREMENT`; these are not sequence settings |
| TPROC-H parallel query | Auto DOP policy plus its limit | The profile keeps the same Auto DOP strategy. The Oracle driver also sets session DOP, but its GUI value supplies fixed DOP under `MANUAL`, not a fixed DOP guarantee under `AUTO`. |

All outline SQL remains **commented and opt-in**. Replace the Oracle SQL_ID
placeholders with IDs from actual unmodified workload executions. Verify the
bound `OUTLINE_ID` and actual access path after execution, then use the provided
`DROP OUTLINE` to undo it. Syntax support does not establish a performance gain.

Compatibility was checked on an OceanBase **4.4.2.2 Oracle tenant**: baseline
queries, variable/parameter-setting syntax, statistics collection, and SLEV/Q7
outline creation, actual binding and removal. Q7 used the covering index and
kept identical results in the small disposable schema. Global-variable and
tenant-parameter syntax checks reapplied their current values, rather than
installing the candidate tuning profile. The existing MySQL executable SQL is
unchanged. These checks do not measure performance.
