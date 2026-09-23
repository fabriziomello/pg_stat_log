#!/usr/bin/env bash
# Infinite mixed load: mostly healthy work, some log-producing errors, occasional
# failed logins. Target DB/user come from libpq env (set per compose service).
set -u

: "${PGHOST:?}"
: "${PGUSER:?}"
: "${PGPASSWORD:?}"
: "${PGDATABASE:?}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PGCONNECT_TIMEOUT=5

echo "workload loop starting: user=$PGUSER db=$PGDATABASE host=$PGHOST"

psql_ok() {
    psql -q -v ON_ERROR_STOP=0 "$@" >/dev/null 2>&1 || true
}

healthy() {
    psql_ok -f "$SCRIPT_DIR/healthy.sql"
}

error() {
    case $((RANDOM % 4)) in
        0)
            psql_ok -c "SET client_min_messages TO error; SELECT 1 / 0;"
            ;;
        1)
            psql_ok -c "SET client_min_messages TO error; INSERT INTO demo_orders (sku, note) VALUES ('FIXED', 'dup');"
            ;;
        2)
            psql_ok -c "SET client_min_messages TO error; SELECT * FROM no_such_table;"
            ;;
        *)
            psql_ok -c "SET client_min_messages TO error; DO \$\$ BEGIN RAISE WARNING 'demo warning'; END \$\$;"
            ;;
    esac
}

auth_fail() {
    PGPASSWORD='wrong-password' psql -q -c 'SELECT 1' >/dev/null 2>&1 || true
}

while true; do
    roll=$((RANDOM % 100))
    if (( roll < 80 )); then
        healthy
    elif (( roll < 95 )); then
        error
    else
        auth_fail
    fi
    # 50–200ms
    sleep "0.$(printf '%03d' $((50 + RANDOM % 151)))"
done
