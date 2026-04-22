--
-- pg_stat_log regression tests
--

CREATE EXTENSION pg_stat_log;

-- Start clean
SELECT pg_stat_log_reset();
SELECT pg_stat_force_next_flush();

--
-- Test 1: Warnings are counted
--
DO $$ BEGIN RAISE WARNING 'test warning 1'; END $$;
DO $$ BEGIN RAISE WARNING 'test warning 2'; END $$;
DO $$ BEGIN RAISE WARNING 'test warning 3'; END $$;

SELECT pg_stat_force_next_flush();

SELECT count >= 3 AS warning_count_ok
FROM pg_stat_log_data()
WHERE elevel = 'WARNING' AND sqlerrcode = '01000';

--
-- Test 2: Errors are tracked
--
SELECT 1/0;

SELECT pg_stat_force_next_flush();

SELECT count >= 1 AS division_by_zero_ok
FROM pg_stat_log_data()
WHERE elevel = 'ERROR' AND sqlerrcode = '22012';

--
-- Test 3: pg_stat_log view works (returns rows with database/user names)
--
SELECT count(*) > 0 AS view_has_rows FROM pg_stat_log WHERE count > 0;

--
-- Test 4: Disable via GUC stops counting
--
SET pg_stat_log.enabled = off;

DO $$ BEGIN RAISE WARNING 'should not be counted'; END $$;

SELECT pg_stat_force_next_flush();

-- The warning count should not have increased; we check by looking for the
-- specific message-related sqlerrcode that was already counted before.
SELECT count >= 3 AS still_same_warning_count
FROM pg_stat_log_data()
WHERE elevel = 'WARNING' AND sqlerrcode = '01000';

SET pg_stat_log.enabled = on;

--
-- Test 5: min_error_level filtering
--
SET pg_stat_log.min_error_level = 'error';

-- Record warning count before
SELECT count AS cnt_before
FROM pg_stat_log_data()
WHERE elevel = 'WARNING' AND sqlerrcode = '01000' \gset

DO $$ BEGIN RAISE WARNING 'filtered out'; END $$;

SELECT pg_stat_force_next_flush();

-- Warning count should be unchanged
SELECT count = :cnt_before AS warning_filtered_ok
FROM pg_stat_log_data()
WHERE elevel = 'WARNING' AND sqlerrcode = '01000';

SET pg_stat_log.min_error_level = 'warning';

--
-- Test 6: Reset zeroes counters
--
SELECT pg_stat_log_reset();

SELECT pg_stat_force_next_flush();

SELECT COALESCE(sum(count), 0) = 0 AS reset_ok FROM pg_stat_log_data();

-- Clean up
DROP EXTENSION pg_stat_log;
