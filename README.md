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

Counters are exposed through the `pg_stat_log` view and the underlying
`pg_stat_log_data()` function. Statistics persist across clean restarts and
are discarded after crash recovery, following standard PostgreSQL cumulative
stats semantics.

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

## Configuration

| Parameter | Type | Default | Context | Description |
|-----------|------|---------|---------|-------------|
| `pg_stat_log.enabled` | bool | `true` | SUSET | Enable or disable collection at runtime |
| `pg_stat_log.min_error_level` | enum | `warning` | SUSET | Minimum severity to track (`debug5` through `panic`) |
| `pg_stat_log.max_entries` | int | `1024` | POSTMASTER | Maximum distinct combinations to track; requires restart |

## Usage

### Viewing statistics

Query the `pg_stat_log` view:

```sql
SELECT * FROM pg_stat_log;
```

```
 backend_type   | database_oid | database_name | user_oid | user_name | elevel  | sqlerrcode | sqlerrcode_name  | count
----------------+--------------+---------------+----------+-----------+---------+------------+------------------+-------
 client backend |        16384 | mydb          |       10 | postgres  | WARNING | 01000      | warning          |    42
 client backend |        16384 | mydb          |       10 | postgres  | ERROR   | 22012      | division_by_zero |     3
 client backend |        16384 | mydb          |       10 | postgres  | ERROR   | 42P01      | undefined_table  |     7
```

### View columns

| Column | Type | Description |
|--------|------|-------------|
| `backend_type` | text | Process type (e.g. `client backend`, `autovacuum worker`) |
| `database_oid` | oid | Database OID, NULL for shared or background processes |
| `database_name` | text | Resolved database name |
| `user_oid` | oid | Role OID, NULL for background processes |
| `user_name` | text | Resolved role name |
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
   matching (backend_type, database, user, elevel, sqlerrcode) combination,
   and either increments an existing counter or creates a new entry. Uses the
   changecount protocol for atomic reads.

3. **pgstat callbacks**: three callbacks mirror the test module --
   `init_shmem_cb` initializes the LWLock and array header,
   `reset_all_cb` snapshots current counters into a reset baseline,
   `snapshot_cb` copies stats and subtracts the reset baseline for reporting.

4. **Reporting**: `pg_stat_log_data()` is a set-returning C function that reads
   from the pgstat snapshot. The `pg_stat_log` view joins its output with
   `pg_database` and `pg_roles` to resolve OIDs to names.

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

- **Parallel workers appear as a separate `backend_type`.** If an error is
  raised during a parallel query, you may see one row with
  `backend_type = 'client backend'` (the leader) plus one row per parallel
  worker that hit the error with `backend_type = 'parallel worker'`. Keep this
  in mind when aggregating so you do not double-count a single logical error.

- **`max_entries` is a hard cap.** Once the configured number of distinct
  (backend_type, database, user, elevel, sqlerrcode) combinations has been
  reached, new distinct combinations are dropped until `pg_stat_log_reset()`
  is called, which reclaims all slots. Monitor `n_dropped` via
  `pg_stat_log_info()` to detect when `max_entries` is too small. Size it to
  cover the cardinality you expect -- roughly
  `N_databases x N_roles x typical_distinct_sqlstates x backend_types` --
  and remember it is `POSTMASTER`-context, so changes require a restart.

## Files

| File | Purpose |
|------|---------|
| `pg_stat_log.c` | C implementation (hook, callbacks, SQL functions) |
| `pg_stat_log--1.0.sql` | SQL objects (functions, view) |
| `pg_stat_log.control` | Extension metadata |
| `Makefile` | PGXS build |
| `generate-errcode-names.pl` | Generates SQLSTATE-to-name lookup header from `errcodes.txt` |
| `t/001_pg_stat_log.pl` | TAP regression tests |

## License

Released under the [PostgreSQL License](https://opensource.org/licenses/PostgreSQL).
