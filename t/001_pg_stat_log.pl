# Copyright (c) 2026, Fabrizio de Royes Mello

# Test pg_stat_log persistence behavior
#
# These tests require server restart/crash and cannot be covered by
# regular regression tests.
#
# Verifies:
# - Stats persist across clean restart
# - Stats are lost after crash recovery

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('main');
$node->init;
$node->append_conf('postgresql.conf',
	"shared_preload_libraries = 'pg_stat_log'");
$node->append_conf('postgresql.conf',
	"pg_stat_log.min_error_level = 'warning'");
$node->start;

$node->safe_psql('postgres', q(CREATE EXTENSION pg_stat_log));

# Generate some data to persist
$node->safe_psql('postgres', q(
	DO $$ BEGIN RAISE WARNING 'persist test'; END $$;
));
$node->psql('postgres', q(SELECT 1/0));

$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

my $result = $node->safe_psql('postgres', q(
	SELECT count FROM pg_stat_log_data()
	WHERE elevel = 'ERROR' AND sqlerrcode = '22012'
));
my $error_count_pre_restart = $result;

# ---------------------------------------------------------------
# Test 1: Stats persist across clean restart
# ---------------------------------------------------------------

$node->stop;
$node->start;

$result = $node->safe_psql('postgres', q(
	SELECT count FROM pg_stat_log_data()
	WHERE elevel = 'ERROR' AND sqlerrcode = '22012'
));
is($result, $error_count_pre_restart,
	"error count persists after clean restart");

# ---------------------------------------------------------------
# Test 2: Stats lost after crash recovery
# ---------------------------------------------------------------

$node->stop('immediate');
$node->start;

$result = $node->safe_psql('postgres', q(
	SELECT COALESCE(sum(count), 0) FROM pg_stat_log_data()
));
is($result, "0", "all counts are zero after crash recovery");


# ---------------------------------------------------------------
# Test 3: pg_stat_log_info() basics
# ---------------------------------------------------------------

my $info_rows = $node->safe_psql('postgres', q(
	SELECT count(*) FROM pg_stat_log_info()
));
is($info_rows, "1", "pg_stat_log_info() returns one row");

my $max_entries = $node->safe_psql('postgres', q(
	SELECT max_entries FROM pg_stat_log_info()
));
my $guc_max = $node->safe_psql('postgres',
	q(SHOW pg_stat_log.max_entries));
is($max_entries, $guc_max,
	"pg_stat_log_info.max_entries matches GUC pg_stat_log.max_entries");

# ---------------------------------------------------------------
# Test 4: stats_reset advances on reset
# ---------------------------------------------------------------

my $reset_before = $node->safe_psql('postgres', q(
	SELECT extract(epoch FROM stats_reset)::numeric FROM pg_stat_log_info()
));
$node->safe_psql('postgres',
	q(SELECT pg_sleep(0.1); SELECT pg_stat_log_reset();));
my $reset_after = $node->safe_psql('postgres', q(
	SELECT extract(epoch FROM stats_reset)::numeric FROM pg_stat_log_info()
));
ok($reset_after > $reset_before,
	"stats_reset timestamp advances after pg_stat_log_reset()");

# ---------------------------------------------------------------
# Test 5: n_dropped increments and reset reclaims slots
# ---------------------------------------------------------------

$node->stop('immediate');
$node->append_conf('postgresql.conf', "pg_stat_log.max_entries = 64");
$node->start;

$max_entries = $node->safe_psql('postgres', q(
	SELECT max_entries FROM pg_stat_log_info()
));
is($max_entries, "64", "max_entries reflects restart-scoped GUC");

# Generate 100 distinct SQLSTATE codes to overflow the 64-slot capacity
$node->safe_psql('postgres', q{
	DO $$
	DECLARE
		i int;
		code text;
	BEGIN
		FOR i IN 1..100 LOOP
			code := 'Z' || lpad(i::text, 4, '0');
			BEGIN
				RAISE WARNING 'overflow test %', i USING ERRCODE = code;
			EXCEPTION WHEN OTHERS THEN
				NULL;
			END;
		END LOOP;
	END $$;
});
$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

my $num_entries = $node->safe_psql('postgres', q(
	SELECT num_entries FROM pg_stat_log_info()
));
is($num_entries, "64", "num_entries saturates at max_entries");

my $n_dropped = $node->safe_psql('postgres', q(
	SELECT n_dropped FROM pg_stat_log_info()
));
ok($n_dropped > 0, "n_dropped > 0 after overflowing max_entries");

# Reset should reclaim slots
$node->safe_psql('postgres', q(SELECT pg_stat_log_reset()));

$num_entries = $node->safe_psql('postgres', q(
	SELECT num_entries FROM pg_stat_log_info()
));
is($num_entries, "0", "num_entries is 0 after reset when saturated");

$n_dropped = $node->safe_psql('postgres', q(
	SELECT n_dropped FROM pg_stat_log_info()
));
is($n_dropped, "0", "n_dropped is 0 after reset");

# Generate a NEW distinct error and verify it is tracked (slot reclaimed)
$node->safe_psql('postgres', q{
	DO $$
	BEGIN
		RAISE WARNING 'post-reset' USING ERRCODE = 'Z9999';
	EXCEPTION WHEN OTHERS THEN
		NULL;
	END $$;
});
$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

my $post_reset = $node->safe_psql('postgres', q(
	SELECT count FROM pg_stat_log_data() WHERE sqlerrcode = 'Z9999'
));
is($post_reset, "1",
	"new distinct error is tracked after reset (slots reclaimed)");

done_testing();
