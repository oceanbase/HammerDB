# OceanBase MySQL tenants

Select **OceanBase** in Benchmark Options, or use `dbset db ob` in
the CLI. This category reuses HammerDB's MySQL TPROC-C and TPROC-H workloads.
The existing OceanBase option under MySQL remains available for compatibility.
Oracle-compatible tenants are not supported by this category yet.

## Connection

Use the business tenant's credentials. Set `ob_user` (TPROC-C) or `ob_tpch_user`
(TPROC-H) to the unqualified user, and set the connection fields separately:

```tcl
dbset db ob
dbset bm TPROC-C
diset connection ob_compatibility_mode mysql
diset connection ob_host 127.0.0.1
diset connection ob_port 2881
diset connection ob_tenant hammerdb
diset connection ob_cluster {}
diset connection ob_query_timeout 120
diset tpcc ob_user root
diset tpcc ob_pass $::env(OB_PASSWORD)
diset tpcc ob_dbase tpcc_ob
```

Direct connections use `user@tenant`. For OBProxy, set its port (normally 2883)
and `ob_cluster`; the login becomes `user@tenant#cluster`. A sys tenant account,
shared administrative password, SQL extension, and cluster parameter changes
are not required. TLS settings are available in the connection configuration
on Linux and Windows; enabling OceanBase does not disable TLS.

`ob_query_timeout` is in seconds and only changes the current database session.
The default is 120 seconds, including schema statistics collection. It does not
change the tenant's global timeout or SQL mode.

## Workloads and results

TPROC-C supports schema creation/checking/deletion, stored procedure test and
timed drivers, prepared procedure calls, and the shared non-stored-procedure
driver. The optional MySQL connection pool, asynchronous client scaling,
invisible history primary key, and HeatWave features are not exposed by the
OceanBase category. `ob_partition` uses the existing MySQL order_line hash
partition strategy (enabled at 200 warehouses); distributed OB-specific schema
layouts require separate validation.

TPROC-H uses abbreviated-month parsing consistently for load and refresh data,
case-insensitive table discovery, and regular MySQL `ANALYZE TABLE`. Its single
user refresh driver runs RF1, the 22 queries, then RF2. Keep verbose result output
off for ordinary validation; some queries return many values.

Timed TPROC-C and its transaction chart both read the business tenant's
`trans commit count` and `trans rollback count` from `oceanbase.GV$SYSSTAT`, summed
across the tenant's OBServers. The user needs permission to read this view.
These are OceanBase server transaction counters, not MySQL `Com_*` statement
counters. NOPM continues to use the change in `district.d_next_o_id`; the report
identifies TPM as OceanBase. Do not silently substitute a missing counter with
zero or assume that a different database's TPM has identical accounting. Other
activity in the same tenant, including monitoring, can contribute to these counters.

The H transaction chart uses the tenant's cumulative `sql select count`, excluding
its own polling requests from the delta. It is a tenant SQL activity indicator,
not the number of completed benchmark query sets. SQL Audit/ASH database metrics
are not exposed by this category yet; generic host CPU metrics remain available.

## Reproducible CLI runs

Set `OB_HOST`, `OB_TENANT`, `OB_USER`, `OB_PASSWORD`, and a **new** `OB_DATABASE` in
the environment, then run either script:

```sh
./hammerdbcli auto scripts/tcl/oceanbase/mysql/tprocc.tcl
./hammerdbcli auto scripts/tcl/oceanbase/mysql/tproch.tcl
```

On Windows use `hammerdbcli.bat` from a source/development installation (or the
packaged `hammerdbcli.exe`). The Tcl scripts use platform-neutral paths.
Optional environment settings include `OB_PORT`, `OB_CLUSTER`, `OB_QUERY_TIMEOUT`,
`OB_BUILD_USERS`, and the workload's `OB_WAREHOUSES`, `OB_USERS`, `OB_RAMPUP`,
`OB_DURATION`, or `OB_SCALE_FACTOR`. The scripts fail when a virtual user fails,
check data before and after execution, and retain the test database.

Runtime helper tests can be run with Tcl 8.6 or newer:

```sh
tclsh tests/oceanbase.tcl
```

Generated-driver regression tests run inside the v6.0 CLI:

```sh
./hammerdbcli auto tests/oceanbase-generated.tcl
```

## Validation status (2026-09-14)

Validated on Linux x86-64 against OceanBase Enterprise 4.3.5.6, a MySQL tenant,
and OBProxy 4.4.1.0: two-warehouse C build/check, direct and proxy procedure calls,
prepared calls, non-procedure calls, timed results, and post-run consistency;
H SF1 build/check, all 22 queries, RF1/queries/RF2 through the proxy, and final
consistency. Counter polling, rejected credentials, existing configuration
migration, and 29 helper/generated-driver assertions passed. The original
MySQL installation and earlier test databases were retained.

This is compatibility validation, not a performance result or certification.
Windows execution, TLS connections, native MySQL server regression, large or
multi-node schemas, and complete GUI startup remain unverified. The Linux GUI
smoke test was blocked by the repackaged test runtime's embedded console
initialization. The bundled Linux MySQL client also emitted a non-fatal
character-set 45 warning during statistics collection; schema checks still passed.

## Tenant-mode extension boundary

`ob_compatibility_mode` selects a registered backend. Missing mode fields in old
OceanBase configurations are migrated to `mysql`. Only `mysql` is currently
registered; `oracle` and unknown values fail before workload generation or
connection, rather than falling back to MySQL.

The category entry points in `src/oceanbase/oboltp.tcl`, `obolap.tcl`, and
`obotc.tcl` dispatch semantic operations. They do not name MySQL generators.
`src/oceanbase/mysql/adapter.tcl` owns MySQL configuration mapping, username
construction, TLS options, schema/workload generation, session initialization,
and counter integration. `mysqlcommon` is used only by this MySQL path.

To implement Oracle tenants, add and explicitly register a separate backend
(e.g. `src/oceanbase/oracle/adapter.tcl`, namespace `oceanbase::oracle`) with:

- `generate workload action`: C build/test/timed/check/delete; H build/test/check/delete.
- `counter benchmark interval masterthread`: the Oracle connection/library and OB statistics implementation.
- `options group option` and `validate configuration`: Oracle-specific configuration, validation and UI.
- `data_format workload`: the format used by offline C/H data-file generation (`mysql` for the MySQL backend).

The Oracle backend can reuse the existing Oracle generators with isolated
configuration, as the MySQL backend does for MySQL. It must own Oracle login
rules, tablespaces/schema fields, SQL and driver initialization; it must not
route through the MySQL configuration mapper or expose MySQL engine/TLS fields.
Preserve each mode's settings when introducing Oracle-specific config groups;
the existing MySQL `ob_*` fields remain the compatibility contract. Register the
Oracle backend only after its implementation and tests are available. The
registry is an internal extension boundary, not a user-loadable plugin system.

After introducing the mode dispatcher, Linux regression also passed 4,000
non-procedure C calls, all 22 H queries, C/H counter polling, migration of a
configuration missing the mode field, and rejection of `oracle` through the
actual CLI. A test-only second backend verified that generation, counters,
options and validation dispatch independently of the MySQL implementation.

Empty optional values are supplied by `oceanbaseconfig::normalize` after loading
OceanBase XML or saved SQLite configuration. Existing values, including explicit
empty strings, are preserved. The shared XML parser is unchanged. MySQL password
defaults are only applied to the MySQL tenant mode.

Offline data generation resolves native database formats in one shared helper.
Additional categories supply a `<prefix>_data_generation_format` callback;
OceanBase delegates this to its selected backend's `data_format` operation.
Unsupported tenant modes fail before creating data-generation virtual users or
files. Adding an Oracle backend does not require changing the C/H data generators.

Offline generation was also validated on AWS Linux: one C warehouse produced all
nine files, and H SF1 produced all eight files with the expected fixed table
cardinalities and approximately six million line items. Customer timestamps in
the C files use the MySQL date-time format. Fresh and persisted OceanBase
configuration defaults and rejection of Oracle data generation passed as well.
