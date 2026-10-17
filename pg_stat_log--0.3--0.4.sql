/* pg_stat_log/pg_stat_log--0.3--0.4.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_stat_log UPDATE TO '0.4'" to load this file. \quit

CREATE FUNCTION pg_stat_log_audit_data(
    OUT backend_type text,
    OUT database_oid oid,
    OUT user_oid oid,
    OUT query_id bigint,
    OUT audit_type text,
    OUT class text,
    OUT command text,
    OUT object_type text,
    OUT object_name text,
    OUT count bigint
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stat_log_audit_data'
LANGUAGE C STRICT PARALLEL UNSAFE;

CREATE FUNCTION pg_stat_log_audit_reset()
RETURNS void
AS 'MODULE_PATHNAME', 'pg_stat_log_audit_reset'
LANGUAGE C STRICT PARALLEL UNSAFE;

CREATE VIEW pg_stat_log_audit AS
SELECT s.backend_type,
       s.database_oid,
       d.datname AS database_name,
       s.user_oid,
       u.rolname AS user_name,
       s.query_id,
       s.audit_type,
       s.class,
       s.command,
       s.object_type,
       s.object_name,
       s.count
FROM pg_stat_log_audit_data() s
LEFT JOIN pg_database d ON d.oid = s.database_oid
LEFT JOIN pg_roles u ON u.oid = s.user_oid;

REVOKE ALL ON FUNCTION pg_stat_log_audit_reset() FROM PUBLIC;

REVOKE ALL ON FUNCTION pg_stat_log_audit_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_stat_log_audit_data() TO pg_read_all_stats;

REVOKE ALL ON pg_stat_log_audit FROM PUBLIC;
GRANT SELECT ON pg_stat_log_audit TO pg_read_all_stats;

CREATE FUNCTION pg_stat_log_audit_info(
    OUT max_entries int,
    OUT num_entries int,
    OUT n_folded bigint,
    OUT n_dropped bigint,
    OUT stats_reset timestamp with time zone
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stat_log_audit_info'
LANGUAGE C STRICT PARALLEL UNSAFE;

REVOKE ALL ON FUNCTION pg_stat_log_audit_info() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_stat_log_audit_info() TO pg_read_all_stats;
