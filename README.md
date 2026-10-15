# pg_stat_log

[![CI](https://github.com/fabriziomello/pg_stat_log/actions/workflows/installcheck.yml/badge.svg)](https://github.com/fabriziomello/pg_stat_log/actions/workflows/installcheck.yml)

Cumulative statistics about PostgreSQL log messages, built on the
[Custom Cumulative Stats](https://wiki.postgresql.org/wiki/CustomCumulativeStats)
API introduced in PostgreSQL 18.

## Overview

`pg_stat_log` hooks into PostgreSQL's `emit_log_hook` to count log messages
grouped by:

- **backend type** -- client backend, autovacuum worker, checkpointer, etc.
- **database** -- which database the message originated from
- **user** -- which role was active
- **error level** -- WARNING, ERROR, FATAL, PANIC, etc.
- **SQLSTATE code** -- the 5-character error code and its human-readable name
- **query identifier** -- optionally, the statement that logged the message;
  see [Query identifiers](#query-identifiers)

Counters are exposed through the `pg_stat_log` view and the underlying
`pg_stat_log_data()` function. Statistics persist across clean restarts and
are discarded after crash recovery, following standard PostgreSQL cumulative
stats semantics.

The records written by `log_connections` and `log_disconnections` are counted
under their own SQLSTATEs; see
[Connection lifecycle records](#connection-lifecycle-records).

The extension uses custom stats kind ID **28**, registered on the
[PostgreSQL wiki](https://wiki.postgresql.org/wiki/CustomCumulativeStats).

## Requirements

- PostgreSQL 18 or later
- Must be loaded via `shared_preload_libraries`

## Installation

Build and install using PGXS:

```bash
make
make install
```

If the build cannot locate `errcodes.txt` automatically, point it to the
PostgreSQL source tree:

```bash
make ERRCODES_FILE=/path/to/postgresql/src/backend/utils/errcodes.txt
```

Then configure PostgreSQL to load the extension:

```
# postgresql.conf
shared_preload_libraries = 'pg_stat_log'
```

Restart the server and create the extension:

```sql
CREATE EXTENSION pg_stat_log;
```

## Upgrading from 0.1

Version 0.2 adds the `query_id` column and counts
[connection lifecycle records](#connection-lifecycle-records) under their own
SQLSTATEs. Install the new version, restart the server so it loads the new
library, then update the extension in each database where it is installed:

```sql
ALTER EXTENSION pg_stat_log UPDATE;
```

- **The first start with the new library discards all cumulative
  statistics**, not only pg_stat_log's. Version 0.2 stores a query identifier
  in every entry, so PostgreSQL cannot read the statistics file written with
  0.1: it logs a `could not read ...` warning and `corrupted statistics file`,
  and starts over with every cumulative statistic reset. Later clean restarts
  keep statistics as usual.
- **Until the update, the 0.1 view and function keep working** with the new
  library, without the `query_id` column.
- **The update recreates the `pg_stat_log` view and the `pg_stat_log_data()`
  function.** Drop your own views that depend on them before the update and
  create them again afterwards. Privileges you granted on them must be granted
  again; the default grants to `pg_read_all_stats` are restored.

## Configuration

| Parameter | Type | Default | Context | Description |
|-----------|------|---------|---------|-------------|
| `pg_stat_log.enabled` | bool | `true` | SUSET | Enable or disable collection at runtime |
| `pg_stat_log.min_error_level` | enum | `warning` | SUSET | Minimum severity to track (`debug5` through `panic`) |
| `pg_stat_log.max_entries` | int | `1024` | POSTMASTER | Maximum distinct combinations to track; requires restart |
| `pg_stat_log.compute_query_id` | bool | `off` | POSTMASTER | Also group by query identifier; see [Query identifiers](#query-identifiers) |

## Usage

### Viewing statistics

Query the `pg_stat_log` view:

```sql
SELECT * FROM pg_stat_log;
```

```
 backend_type   | database_oid | database_name | user_oid | user_name | query_id | elevel  | sqlerrcode | sqlerrcode_name  | count
----------------+--------------+---------------+----------+-----------+----------+---------+------------+------------------+-------
 client backend |        16384 | mydb          |       10 | postgres  |          | WARNING | 01000      | warning          |    42
 client backend |        16384 | mydb          |       10 | postgres  |          | ERROR   | 22012      | division_by_zero |     3
 client backend |        16384 | mydb          |       10 | postgres  |          | ERROR   | 42P01      | undefined_table  |     7
```

### View columns

| Column | Type | Description |
|--------|------|-------------|
| `backend_type` | text | Process type (e.g. `client backend`, `autovacuum worker`) |
| `database_oid` | oid | Database OID, NULL for shared or background processes |
| `database_name` | text | Resolved database name |
| `user_oid` | oid | Role OID, NULL for background processes |
| `user_name` | text | Resolved role name |
| `query_id` | bigint | Query identifier, NULL unless `pg_stat_log.compute_query_id` is on; see [Query identifiers](#query-identifiers) |
| `elevel` | text | Error severity (WARNING, ERROR, FATAL, PANIC, ...) |
| `sqlerrcode` | text | 5-character SQLSTATE code |
| `sqlerrcode_name` | text | Condition name (e.g. `division_by_zero`) |
| `count` | bigint | Cumulative message count |

### Example queries

Top 10 most frequent errors:

```sql
SELECT elevel, sqlerrcode, sqlerrcode_name, sum(count) AS total
FROM pg_stat_log
WHERE elevel = 'ERROR'
GROUP BY elevel, sqlerrcode, sqlerrcode_name
ORDER BY total DESC
LIMIT 10;
```

Errors by database:

```sql
SELECT database_name, elevel, count
FROM pg_stat_log
WHERE database_name IS NOT NULL
ORDER BY count DESC;
```

Errors from background processes:

```sql
SELECT backend_type, elevel, sqlerrcode_name, count
FROM pg_stat_log
WHERE backend_type <> 'client backend'
ORDER BY count DESC;
```

### Connection lifecycle records

PostgreSQL writes the `log_connections` and `log_disconnections` records at
`LOG` level with SQLSTATE `00000`. `pg_stat_log` counts them under
extension-defined SQLSTATEs instead, attributed to the connected database and
the login role:

| SQLSTATE | `sqlerrcode_name` | Record | Logged when |
|----------|-------------------|--------|-------------|
| `PSL01` | `connection_authenticated` | `connection authenticated: ...` | `log_connections` includes `authentication` |
| `PSL02` | `connection_authorized` | `connection authorized: ...`, `replication connection authorized: ...` | `log_connections` includes `authorization` |
| `PSL03` | `disconnection` | `disconnection: session time: ...` | `log_disconnections = on` |

A record is counted only if it reaches the server log, and only if
`pg_stat_log.min_error_level` is `log` or lower:

```
# postgresql.conf
pg_stat_log.min_error_level = 'log'
log_connections = 'authentication,authorization'    # or 'on', 'all'
log_disconnections = on
```

Connections and disconnections per database and user:

```sql
SELECT database_name, user_name, backend_type, sqlerrcode_name, count
FROM pg_stat_log
WHERE sqlerrcode LIKE 'PSL%'
ORDER BY database_name, user_name, backend_type, sqlerrcode;
```

- **The user is the login role**, the role that connected, even if the
  session later runs `SET ROLE` or `SET SESSION AUTHORIZATION`.
- **Physical replication connections** are counted with
  `backend_type = 'walsender'` and a NULL database.
- **A startup that fails after authentication** counts the records logged so
  far with the attribution known at that point. For example, a connection to a
  database that does not exist counts `PSL01` and `PSL02` with a NULL
  database, and no `PSL03`, since its disconnection is not logged.
- **Counting is not simultaneous with logging.** `PSL01` and `PSL02` are
  counted when backend startup completes or fails; `PSL03` is counted as the
  session exits, just before its record is written.
- **Per-session settings only apply at connection start.** Superusers and
  roles granted `SET` on `log_disconnections` can change it for a session
  with startup options, such as `PGOPTIONS='-c log_disconnections=on'` or the
  `options` connection parameter. `ALTER ROLE ... SET` and
  `ALTER DATABASE ... SET` cannot set it. A configuration reload does not
  change it for running sessions, so PostgreSQL still logs, and pg_stat_log
  still counts, the disconnection of a session that started with
  `log_disconnections = on`. Startup options for `log_connections` come too
  late for `PSL01` and `PSL02`: PostgreSQL logs those records before it
  applies the options.
- **The other `log_connections` records are not mapped.** `receipt`
  (`connection received: ...`) is logged before the backend has a `PGPROC` and
  is never counted; `setup_durations` (`connection ready: ...`) is counted as
  an ordinary `LOG` record with SQLSTATE `00000`.
- **Each (backend type, database, user) combination** that connects can use up
  to three entries; account for them when sizing `pg_stat_log.max_entries`.

In version 0.1, the authenticated and authorized records were counted as
`00000` (`successful_completion`) with a NULL database and user, and
disconnections were not counted.

### Query identifiers

With `pg_stat_log.compute_query_id = on`, messages are also grouped by the
query identifier of the statement that logged them, so the same error raised
by different statements is counted in separate rows:

```
# postgresql.conf
pg_stat_log.compute_query_id = on
compute_query_id = auto    # the default; 'on' also works
```

`query_id` is the identifier that `%Q` prints in `log_line_prefix`, the same
one shown by `pg_stat_activity.query_id` and `pg_stat_statements.queryid`.
Errors per statement, with the statement text from `pg_stat_statements`:

```sql
SELECT l.sqlerrcode_name, l.count, s.query
FROM pg_stat_log l
LEFT JOIN pg_stat_statements s
       ON s.queryid = l.query_id
      AND s.dbid = l.database_oid
      AND s.userid = l.user_oid
      AND s.toplevel
WHERE l.query_id IS NOT NULL
ORDER BY l.count DESC;
```

`pg_stat_statements` lists a statement only after it has completed once, so
`query` is NULL for statements that always fail.

- **`compute_query_id` must not be `off`.** Under `auto`, pg_stat_log has
  PostgreSQL compute query identifiers, as `pg_stat_statements` does; it
  decides this at server start, so `pg_stat_log.compute_query_id` requires a
  restart. While `compute_query_id` is `off`, in the server configuration or
  in a session, messages are counted with a NULL `query_id`.
- **Some messages have no query identifier** and are counted with a NULL
  `query_id`: messages logged outside any statement, for example by the
  checkpointer or during connection startup; errors raised before parse
  analysis completes, such as syntax errors and references to tables that do
  not exist; the connection lifecycle records; and every message while
  `track_activities` is off.
- **Statements that differ only in constants share an identifier**, such as
  `SELECT 1/0` and `SELECT 2/0`.
- **Messages from nested statements**, such as an error raised inside a
  function, are counted under the identifier of the top-level statement.
- **An idle session keeps its last statement's identifier.** A message logged
  between statements, such as an `idle_session_timeout` FATAL, is counted
  under the identifier of the session's most recent statement.

### Resetting statistics

```sql
SELECT pg_stat_log_reset();
```


Resetting also reclaims the tracked-combination slots, so new distinct
combinations can be tracked after a reset even if `max_entries` had been
reached previously.

### Inspecting capacity and drops

`pg_stat_log_info()` exposes metadata about the tracking state:

```sql
SELECT * FROM pg_stat_log_info();
```

```
 max_entries | num_entries | n_dropped |          stats_reset
-------------+-------------+-----------+-------------------------------
        1024 |          37 |         0 | 2026-04-22 16:40:39.124+00
```

| Column | Type | Description |
|--------|------|-------------|
| `max_entries` | int | Configured `pg_stat_log.max_entries` capacity |
| `num_entries` | int | Distinct combinations currently tracked |
| `n_dropped` | bigint | Log messages that could not be tracked because `max_entries` was full |
| `stats_reset` | timestamptz | Timestamp of the last reset (or shared-memory init) |

Monitor `n_dropped` to detect when `max_entries` is too small for your
workload: if it grows over time, increase `pg_stat_log.max_entries` (and
restart) so every distinct combination fits. `stats_reset` advances
whenever `pg_stat_log_reset()` is called.

## How it works

`pg_stat_log` uses the fixed-amount Custom Cumulative Stats API, following the
same pattern as PostgreSQL's in-tree `test_custom_fixed_stats` test module.

1. **Startup** (`_PG_init`): registers custom stats kind 28, defines GUCs,
   and installs the `emit_log_hook`.

2. **Hook** (`emit_log_hook`): on each log message at or above the configured
   minimum level, acquires a shared-memory LWLock, scans the entry array for a
   matching (backend_type, database, user, query_id, elevel, sqlerrcode)
   combination, and either increments an existing counter or creates a new
   entry. `query_id` is 0, shown as NULL, unless
   `pg_stat_log.compute_query_id` is on. Uses the changecount protocol for
   atomic reads.

3. **pgstat callbacks**: three callbacks mirror the test module --
   `init_shmem_cb` initializes the LWLock and array header,
   `reset_all_cb` zeroes counters and reclaims slots,
   `snapshot_cb` copies stats for reporting.

4. **Reporting**: `pg_stat_log_data()` is a set-returning C function that reads
   from the pgstat snapshot. The `pg_stat_log` view joins its output with
   `pg_database` and `pg_roles` to resolve OIDs to names.

5. **Connection lifecycle records**: the hook recognizes the
   `log_connections` and `log_disconnections` records by the source file and
   function that emit them. Authentication and authorization are logged before
   the session has a database and login role, so they are held in
   backend-local counters and counted when the startup transaction commits or
   aborts. The disconnection record is logged after the backend has released
   its `PGPROC`, when shared memory can no longer be locked, so a
   `before_shmem_exit` callback counts it just before, under the same
   conditions that decide whether the record reaches the server log.
   `check-upstream-anchors.pl` verifies in CI that the PostgreSQL sources still
   match these assumptions.

### Design notes: why a custom hash table

The entries live in an index-based separate-chaining hash table built directly
inside the stats block, rather than in one of PostgreSQL's standard hash
tables. The reason is a hard constraint of the fixed-amount custom stats API:
the block is snapshotted with a raw `memcpy` and persisted/restored verbatim
(`fwrite`/`fread`) with no serialize callbacks, so every structure inside it
must be position-independent (no raw pointers) and fully self-contained.

None of the standard tables meet that bar. `dynahash` chains its entries,
segment directory, and freelists with absolute pointers, which become garbage
in a memcpy'd snapshot or after a restart (this is why `pg_stat_statements`
serializes its dynahash logically at shutdown instead of dumping it raw --
an option fixed-amount stats kinds do not have). `simplehash` is process-local
and grows by reallocation, so it cannot live in shared memory at all. `dshash`
would require abandoning the fixed-amount API for variable-amount stats, which
brings a 64-bit key limit (pg_stat_log's signature needs ~212 bits), unbounded
DSA memory growth, no extension-visible API to enumerate entries for
reporting, and memory allocation inside `emit_log_hook` -- which runs in every
process type, including the postmaster.

The index-chained design sidesteps all of this: chain links are array indices
instead of pointers, so the block survives snapshots and restarts unchanged;
the footprint is a hard cap of ~1.15x the raw entry data, fixed at startup;
and lookups, inserts, and drops stay O(1) expected even at 100% load.

## Caveats

A few things to keep in mind when interpreting the counters:

- **`emit_log_hook` only fires for messages that actually reach the server
  log.** Lowering `pg_stat_log.min_error_level` on its own is not enough --
  `log_min_messages` acts as a floor on what the hook ever sees. For example,
  `pg_stat_log.min_error_level = 'notice'` requires `log_min_messages = 'notice'`
  (or lower, e.g. `info`, `debug1`) to have any effect. With the default
  `log_min_messages = 'warning'`, NOTICE and INFO messages are filtered out
  before the hook runs and will not be counted.

- **NULL `database_name` / `user_name` rows are expected.** A log message can
  be emitted before a backend has bound to a database or role, so the database
  and user OIDs may be unset. Typical cases include authentication failures
  (e.g. FATAL with SQLSTATE `28P01`), early startup messages, and messages
  logged in the postmaster context. This is not a bug -- those rows record
  real events that simply have no database/user to attribute them to.
  Connection lifecycle records of a failed startup follow the same rule; see
  [Connection lifecycle records](#connection-lifecycle-records).

- **Parallel workers appear as a separate `backend_type`.** If an error is
  raised during a parallel query, you may see one row with
  `backend_type = 'client backend'` (the leader) plus one row per parallel
  worker that hit the error with `backend_type = 'parallel worker'`. Keep this
  in mind when aggregating so you do not double-count a single logical error.

- **`max_entries` is a hard cap.** Once the configured number of distinct
  (backend_type, database, user, query_id, elevel, sqlerrcode) combinations
  has been reached, new distinct combinations are dropped until
  `pg_stat_log_reset()` is called, which reclaims all slots. Monitor
  `n_dropped` via `pg_stat_log_info()` to detect when `max_entries` is too
  small. Size it to cover the cardinality you expect -- roughly
  `N_databases x N_roles x typical_distinct_sqlstates x backend_types` --
  and remember it is `POSTMASTER`-context, so changes require a restart.
  With `pg_stat_log.compute_query_id = on`, multiply that by the number of
  distinct statements that log messages.

- **Changing `max_entries` discards all cumulative statistics.** The
  persisted block changes length, so at the next start PostgreSQL cannot
  read the statistics file: it logs a `could not read ...` warning and
  `corrupted statistics file`, and starts over with every cumulative
  statistic reset, not only pg_stat_log's.

- **`n_dropped` and `stats_reset` do not persist across restarts.** These
  metadata fields are reinitialized at server startup. The per-combination
  counters persist across clean restarts, but `n_dropped` resets to zero
  and `stats_reset` is set to the startup timestamp. This is by design --
  drop telemetry measures pressure since the last startup or reset.

- **Caught PL/pgSQL exceptions are not counted.** If a `RAISE` inside a
  `BEGIN ... EXCEPTION WHEN OTHERS` block is caught by the exception handler,
  the message never reaches the server log and `emit_log_hook` does not fire.
  Only messages that actually make it to the log are tracked.

## Files

| File | Purpose |
|------|---------|
| `pg_stat_log.c` | C implementation (hook, callbacks, SQL functions) |
| `pg_stat_log--0.1.sql` | SQL objects (functions, view) |
| `pg_stat_log--0.1--0.2.sql` | Update to 0.2, adding the `query_id` column |
| `pg_stat_log.control` | Extension metadata |
| `Makefile` | PGXS build |
| `generate-errcode-names.pl` | Generates SQLSTATE-to-name lookup header from `errcodes.txt` |
| `check-upstream-anchors.pl` | Checks the PostgreSQL source assumptions behind the connection lifecycle counters and query identifiers |
| `t/001_pg_stat_log.pl` | TAP regression tests |
| `t/002_connection_lifecycle.pl` | TAP tests for the connection lifecycle counters |
| `t/003_query_id.pl` | TAP tests for the query identifiers |

## License

Released under the [PostgreSQL License](https://opensource.org/licenses/PostgreSQL).
