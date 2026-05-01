/* pg_stat_log/pg_stat_log--1.0.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pg_stat_log" to load this file. \quit

CREATE FUNCTION pg_stat_log_data(
    OUT backend_type text,
    OUT database_oid oid,
    OUT user_oid oid,
    OUT elevel text,
    OUT sqlerrcode text,
    OUT sqlerrcode_name text,
    OUT count bigint
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stat_log_data'
LANGUAGE C STRICT PARALLEL UNSAFE;

CREATE FUNCTION pg_stat_log_reset()
RETURNS void
AS 'MODULE_PATHNAME', 'pg_stat_log_reset'
LANGUAGE C STRICT PARALLEL UNSAFE;

CREATE VIEW pg_stat_log AS
SELECT s.backend_type,
       s.database_oid,
       d.datname AS database_name,
       s.user_oid,
       u.rolname AS user_name,
       s.elevel,
       s.sqlerrcode,
       s.sqlerrcode_name,
       s.count
FROM pg_stat_log_data() s
LEFT JOIN pg_database d ON d.oid = s.database_oid
LEFT JOIN pg_roles u ON u.oid = s.user_oid;

REVOKE ALL ON FUNCTION pg_stat_log_reset() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_stat_log_reset() TO pg_monitor;

REVOKE ALL ON FUNCTION pg_stat_log_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_stat_log_data() TO pg_read_all_stats;

REVOKE ALL ON pg_stat_log FROM PUBLIC;
GRANT SELECT ON pg_stat_log TO pg_read_all_stats;

CREATE FUNCTION pg_stat_log_info(
    OUT max_entries int,
    OUT num_entries int,
    OUT n_dropped bigint,
    OUT stats_reset timestamp with time zone
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stat_log_info'
LANGUAGE C STRICT PARALLEL UNSAFE;

REVOKE ALL ON FUNCTION pg_stat_log_info() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_stat_log_info() TO pg_read_all_stats;
