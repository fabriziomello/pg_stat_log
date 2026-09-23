#!/usr/bin/env bash
# Infinite pgbench load: random 1..50 clients per burst, weighted custom
# scripts, then a few failed logins (auth cannot run inside a connected
# pgbench session). Target DB/user come from libpq env.
set -u

: "${PGHOST:?}"
: "${PGUSER:?}"
: "${PGPASSWORD:?}"
: "${PGDATABASE:?}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PGCONNECT_TIMEOUT=5

echo "workload loop starting: user=$PGUSER db=$PGDATABASE host=$PGHOST"

while true; do
    clients=$((1 + RANDOM % 50))
    if (( clients < 8 )); then
        jobs=$clients
    else
        jobs=8
    fi

    echo "pgbench burst: clients=$clients jobs=$jobs txns=1/client"
    # One transaction per client, then start over. pgbench aborts a client on
    # SQL ERROR, so a long -T mixed burst would shed error-producing clients
    # and the mix would collapse to healthy-only.
    pgbench -n \
        -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" \
        -c "$clients" -j "$jobs" -t 1 --max-tries=1 \
        -f "$SCRIPT_DIR/healthy.sql@80" \
        -f "$SCRIPT_DIR/error_div.sql@4" \
        -f "$SCRIPT_DIR/error_unique.sql@4" \
        -f "$SCRIPT_DIR/error_undef.sql@4" \
        -f "$SCRIPT_DIR/error_warn.sql@3" \
        >/dev/null 2>&1 \
        || true

    if (( RANDOM % 8 == 0 )); then
        PGPASSWORD='wrong-password' psql -q -c 'SELECT 1' >/dev/null 2>&1 || true
    fi
done
