/* pg_stat_log/pg_stat_log--0.1--0.3.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pg_stat_log UPDATE TO '0.3'" to load this file. \quit

-- First remove the objects whose columns change from the extension
ALTER EXTENSION pg_stat_log DROP VIEW pg_stat_log;
ALTER EXTENSION pg_stat_log DROP FUNCTION pg_stat_log_data();

-- Then drop them
DROP VIEW pg_stat_log;
DROP FUNCTION pg_stat_log_data();

-- Now redefine them with the query_id column
CREATE FUNCTION pg_stat_log_data(
    OUT backend_type text,
    OUT database_oid oid,
    OUT user_oid oid,
    OUT query_id bigint,
    OUT elevel text,
    OUT sqlerrcode text,
    OUT sqlerrcode_name text,
    OUT count bigint
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'pg_stat_log_data_0_3'
LANGUAGE C STRICT PARALLEL UNSAFE;

CREATE VIEW pg_stat_log AS
SELECT s.backend_type,
       s.database_oid,
       d.datname AS database_name,
       s.user_oid,
       u.rolname AS user_name,
       s.query_id,
       s.elevel,
       s.sqlerrcode,
       s.sqlerrcode_name,
       s.count
FROM pg_stat_log_data() s
LEFT JOIN pg_database d ON d.oid = s.database_oid
LEFT JOIN pg_roles u ON u.oid = s.user_oid;

REVOKE ALL ON FUNCTION pg_stat_log_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pg_stat_log_data() TO pg_read_all_stats;

REVOKE ALL ON pg_stat_log FROM PUBLIC;
GRANT SELECT ON pg_stat_log TO pg_read_all_stats;
