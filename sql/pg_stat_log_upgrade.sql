--
-- pg_stat_log upgrade from 0.1 to 0.2
--

--
-- Test 1: The 0.1 objects keep working with the 0.2 library
--
CREATE EXTENSION pg_stat_log VERSION '0.1';
SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_log';

SELECT pg_stat_log_reset();
DO $$ BEGIN RAISE WARNING 'counted before the update'; END $$;

SELECT pg_get_function_arguments('pg_stat_log_data()'::regprocedure);

SELECT backend_type, elevel, sqlerrcode, sqlerrcode_name, count
FROM pg_stat_log_data()
WHERE sqlerrcode = '01000';

SELECT backend_type, database_name = current_database() AS current_database,
       elevel, sqlerrcode, count
FROM pg_stat_log
WHERE sqlerrcode = '01000';

--
-- Test 2: ALTER EXTENSION UPDATE adds query_id
--
ALTER EXTENSION pg_stat_log UPDATE;
SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_log';

SELECT pg_get_function_arguments('pg_stat_log_data()'::regprocedure);

SELECT attname
FROM pg_attribute
WHERE attrelid = 'pg_stat_log'::regclass AND attnum > 0
ORDER BY attnum;

-- The recreated view and function are members of the extension
SELECT pg_describe_object(classid, objid, objsubid) AS member
FROM pg_depend
WHERE refclassid = 'pg_extension'::regclass
  AND refobjid = (SELECT oid FROM pg_extension WHERE extname = 'pg_stat_log')
  AND deptype = 'e'
  AND classid IN ('pg_proc'::regclass, 'pg_class'::regclass)
ORDER BY member;

-- Counts recorded before the update are kept. query_id is NULL because
-- pg_stat_log.compute_query_id is off.
SELECT backend_type, query_id, elevel, sqlerrcode, count
FROM pg_stat_log
WHERE sqlerrcode = '01000';

--
-- Test 3: The recreated objects keep the 0.1 privileges
--
SELECT has_function_privilege('pg_read_all_stats', 'pg_stat_log_data()', 'EXECUTE') AS read_all_stats_execute,
       has_function_privilege('public', 'pg_stat_log_data()', 'EXECUTE') AS public_execute,
       has_table_privilege('pg_read_all_stats', 'pg_stat_log', 'SELECT') AS read_all_stats_select,
       has_table_privilege('public', 'pg_stat_log', 'SELECT') AS public_select;

--
-- Test 4: A definition whose columns do not match its entry point fails
--
CREATE FUNCTION pg_stat_log_data_mismatch(OUT backend_type text, OUT count bigint)
RETURNS SETOF record
AS '$libdir/pg_stat_log', 'pg_stat_log_data_0_2'
LANGUAGE C STRICT;
SELECT * FROM pg_stat_log_data_mismatch();
DROP FUNCTION pg_stat_log_data_mismatch();

-- Clean up
DROP EXTENSION pg_stat_log;
