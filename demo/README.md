# Hands-on demo: live error rates from `pg_stat_log`

Self-contained Docker Compose stack: PostgreSQL 18 with `pg_stat_log` built
from this checkout, two infinite mixed workloads, Prometheus, and
Grafana. Counters in `pg_stat_log` are **cumulative**; the dashboard uses
`rate()` / `increase()`. Do not graph `sum(count)` as a rate without those
functions.

```
app_shop \                  postgres_exporter
app_analytics  -->  Postgres 18 + pg_stat_log  -->  Prometheus --> Grafana :3000
```

## Start

Needs Docker Compose and a network for the image build. A build stage installs
a compiler and the PostgreSQL server headers (apt) and compiles `pg_stat_log`
from the repository root; the image gets only the installed extension. From
this directory:

```bash
docker compose up --build
```

Run it again after changing the extension's source: `--build` recompiles
`pg_stat_log`.

Open **http://127.0.0.1:3000** (anonymous admin). The provisioned dashboard is
`pg_stat_log`. Collection uses `pg_stat_log.min_error_level=log` so LOG and
above are counted. `log_min_messages` stays at **warning**: in PostgreSQL,
`log_min_messages=log` is a special rank that *drops* WARNING and ERROR from
the server log (only LOG/FATAL/PANIC remain), so the hook would never see
the workload errors. LOG messages such as checkpoints still reach the hook
when `log_min_messages` is warning. The error-rate graphs still filter
`ERROR|FATAL|PANIC`; **All log messages** is the unfiltered group-by
(`backend_type`, `elevel`, SQLSTATE), matching:

```sql
SELECT backend_type, elevel, sqlerrcode, sqlerrcode_name, sum(count)
FROM pg_stat_log
GROUP BY 1, 2, 3, 4;
```

The stack also sets `pg_stat_log.compute_query_id=on`, so each message is
counted under the query identifier of the statement that logged it, and
preloads `pg_stat_statements`, which supplies the statement text. The three
panels at the bottom of the dashboard show messages per query (step 5 of the
session); the other panels add the statements up.

First start initializes the data volume. Later starts reuse it; to wipe
counters and data:

```bash
docker compose down -v
docker compose up --build
```

The volume also keeps the extension's SQL objects; the `initdb/` scripts run
only on the first start. A volume created with an older version, such as
PGDG's release 0.2, keeps SQL version 0.1 and works without the `query_id`
column (see [Upgrading from 0.1 or 0.2](../README.md#upgrading-from-01-or-02)),
but it may lack `pg_stat_statements`. Until you update the extension and
create `pg_stat_statements`, the per-query panels stay empty, and the
exporter's per-query query fails on every scrape, which the dashboard shows
as `demo_monitor` errors. Run this, or start over with
`docker compose down -v`:

```bash
docker compose exec postgres psql -U postgres \
  -c 'ALTER EXTENSION pg_stat_log UPDATE;' \
  -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements;'
```

If Postgres exits complaining about data in `/var/lib/postgresql/data`
("unused mount/volume"), you have a volume from an older layout: `postgres:18`
expects a single mount at `/var/lib/postgresql`. Run `docker compose down -v`
and start again.

## Session (~30 minutes)

1. Grafana: both `shop` and `analytics` series should move (error rate by
   database and by user).
2. Isolate a tenant: `docker compose stop app_analytics` — shop keeps
   rising, analytics goes quiet.
3. Bring it back: `docker compose start app_analytics`.
4. Same numbers in SQL (no log file):

```bash
docker compose exec postgres psql -U postgres -c \
  "SELECT elevel, sqlerrcode, sqlerrcode_name, database_name, user_name, count
   FROM pg_stat_log ORDER BY count DESC;"
```

5. Per query: **Messages by query** splits the messages by statement, labeled
   with the normalized text from `pg_stat_statements`, such as
   `SELECT $1 / $2`. `42P01` (undefined table) fails during parse analysis,
   before the statement gets a query identifier, and failed logins (`28P01`)
   and checkpoints run no statement, so they count under **without query
   id**. The same join in SQL:

```bash
docker compose exec postgres psql -U postgres -c \
  "SELECT l.database_name, l.sqlerrcode_name, l.count, s.query
   FROM pg_stat_log l
   LEFT JOIN pg_stat_statements s
          ON s.queryid = l.query_id
         AND s.dbid = l.database_oid
         AND s.userid = l.user_oid
         AND s.toplevel
   WHERE l.query_id IS NOT NULL
   ORDER BY l.count DESC;"
```

Optional reset during the talk:

```bash
docker compose exec postgres psql -U postgres -c 'SELECT pg_stat_log_reset();'
```

## What is running

| Service | Role |
|---------|------|
| `postgres` | Official `postgres:18` + `pg_stat_log` built from this checkout, `min_error_level=log`, `compute_query_id=on`, `pg_stat_statements`, `max_connections=300` |
| `app_shop` | pgbench bursts as role `app_shop` / database `shop` (random `-c` 1..50) |
| `app_analytics` | Same for `app_analytics` / `analytics` |
| `postgres_exporter` | Scrapes `pg_stat_log` (`count` as a COUNTER, summed over `query_id`), per-query counts with the text from `pg_stat_statements`, and `pg_stat_log_info` |
| `prometheus` | 5s scrape |
| `grafana` | Dashboard on port 3000 |

Each workload is an infinite loop of **pgbench bursts**. Every burst picks
`-c` uniformly in 1..50 and runs **one transaction per client** (pgbench
aborts a client on SQL ERROR, so a long mixed `-T` run would collapse to
healthy-only). Script weights are 72 healthy, 8 each for `22012` and `23505`,
4 for `42P01` and 3 for `RAISE WARNING` (no `EXCEPTION` handler). The `22012`
and `23505` scripts fail on half of their runs, so `pg_stat_statements` sees
them complete and records their text; overall about 15% of transactions log
an error or a warning. Failed logins
are occasional `psql` attempts between bursts (FATAL; names often NULL),
because pgbench cannot authenticate as the wrong user mid-session.

`max_connections=300` leaves room for two tenants at 50 clients plus exporter
and `psql`.

Ports on the host: Postgres `5432`, Grafana `3000`, Prometheus `9090`,
exporter `9187`. Demo passwords: `postgres` / `shop` / `analytics` /
`demo_monitor`=`monitor`. Do not reuse this compose file in production.

## Files

| Path | Role |
|------|------|
| `Dockerfile` | Builds `pg_stat_log` from the repository root and installs it on `postgres:18` |
| `initdb/` | `CREATE EXTENSION`, tenants, seed row |
| `docker-compose.yml` | Full stack |
| `workload/loop.sh` | Infinite pgbench bursts, random `-c` 1..50, then failed logins |
| `workload/healthy.sql` | Non-error pgbench script (`@72`) |
| `workload/error_*.sql` | Log-producing pgbench scripts |
| `grafana/` | Exporter queries, Prometheus, provisioned dashboard |
