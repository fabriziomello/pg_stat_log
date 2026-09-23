# Hands-on demo: live error rates from `pg_stat_log`

Self-contained Docker Compose stack: PostgreSQL 18 with `pg_stat_log` from
PGDG (`postgresql-18-stat-log`), two infinite mixed workloads, Prometheus, and
Grafana. Counters in `pg_stat_log` are **cumulative**; the dashboard uses
`rate()` / `increase()`. Do not graph `sum(count)` as a rate without those
functions.

```
workload_shop \                  postgres_exporter
workload_analytics  -->  Postgres 18 + pg_stat_log  -->  Prometheus --> Grafana :3000
```

## Start

Needs Docker Compose and a network for the image build (apt). From this
directory:

```bash
docker compose up --build
```

Open **http://127.0.0.1:3000** (anonymous admin). The provisioned dashboard is
`pg_stat_log`.

First start initializes the data volume. Later starts reuse it; to wipe
counters and data:

```bash
docker compose down -v
docker compose up --build
```

If Postgres exits complaining about data in `/var/lib/postgresql/data`
("unused mount/volume"), you have a volume from an older layout: `postgres:18`
expects a single mount at `/var/lib/postgresql`. Run `docker compose down -v`
and start again.

## Session (~30 minutes)

1. Grafana: both `shop` and `analytics` series should move (error rate by
   database and by user).
2. Isolate a tenant: `docker compose stop workload_analytics` — shop keeps
   rising, analytics goes quiet.
3. Bring it back: `docker compose start workload_analytics`.
4. Same numbers in SQL (no log file):

```bash
docker compose exec postgres psql -U postgres -c \
  "SELECT elevel, sqlerrcode, sqlerrcode_name, database_name, user_name, count
   FROM pg_stat_log ORDER BY count DESC;"
```

Optional reset during the talk:

```bash
docker compose exec postgres psql -U postgres -c 'SELECT pg_stat_log_reset();'
```

## What is running

| Service | Role |
|---------|------|
| `postgres` | Official `postgres:18` + `apt install postgresql-18-stat-log`, `shared_preload_libraries=pg_stat_log` |
| `workload_shop` | Infinite loop as `app_shop` / `shop` |
| `workload_analytics` | Same for `app_analytics` / `analytics` |
| `postgres_exporter` | Scrapes `pg_stat_log` (`count` as a COUNTER) and `pg_stat_log_info` |
| `prometheus` | 5s scrape |
| `grafana` | Dashboard on port 3000 |

Each workload iteration is roughly:

- 80% healthy `SELECT`/`INSERT` (should not log WARNING/ERROR)
- 15% a real failure: `22012`, `23505`, `42P01`, or `RAISE WARNING` (no
  `EXCEPTION` handler — caught errors never reach `emit_log_hook`)
- 5% failed login (FATAL; `database_name` / `user_name` often NULL)

Ports on the host: Postgres `5432`, Grafana `3000`, Prometheus `9090`,
exporter `9187`. Demo passwords: `postgres` / `shop` / `analytics` /
`demo_monitor`=`monitor`. Do not reuse this compose file in production.

## Files

| Path | Role |
|------|------|
| `Dockerfile` | `postgres:18` + PGDG `postgresql-18-stat-log` |
| `initdb/` | `CREATE EXTENSION`, tenants, seed row |
| `docker-compose.yml` | Full stack |
| `workload/loop.sh` | Infinite mixed load |
| `workload/healthy.sql` | Non-error statements |
| `grafana/` | Exporter queries, Prometheus, provisioned dashboard |
