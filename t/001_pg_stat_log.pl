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
# Test 1b: n_dropped and stats_reset do not persist across restart
# ---------------------------------------------------------------

my $n_dropped = $node->safe_psql('postgres', q(
	SELECT n_dropped FROM pg_stat_log_info()
));
is($n_dropped, "0",
	"n_dropped resets to 0 after clean restart");

my $reset_ts = $node->safe_psql('postgres', q(
	SELECT stats_reset FROM pg_stat_log_info()
));
ok(defined $reset_ts && $reset_ts ne '',
	"stats_reset is set to startup timestamp after clean restart");

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

$n_dropped = $node->safe_psql('postgres', q(
	SELECT n_dropped FROM pg_stat_log_info()
));
ok($n_dropped > 0, "n_dropped > 0 after overflowing max_entries");

# An already-tracked signature must keep counting even when the table is full
my $tracked_code = $node->safe_psql('postgres', q(
	SELECT sqlerrcode FROM pg_stat_log_data() LIMIT 1
));
my $count_before = $node->safe_psql('postgres',
	"SELECT count FROM pg_stat_log_data() WHERE sqlerrcode = '$tracked_code'");
$node->safe_psql('postgres',
	"DO \$\$ BEGIN RAISE WARNING 'still counts' USING ERRCODE = '$tracked_code'; END \$\$;");
$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));
my $count_after = $node->safe_psql('postgres',
	"SELECT count FROM pg_stat_log_data() WHERE sqlerrcode = '$tracked_code'");
cmp_ok($count_after, '>', $count_before,
	"tracked signature still counts when table is full");

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


# ---------------------------------------------------------------
# Test 6: Stats discarded when max_entries changes across restart
# ---------------------------------------------------------------

# Generate some stats with the current max_entries=64
$node->safe_psql('postgres', q(SELECT pg_stat_log_reset()));
$node->safe_psql('postgres', q{
	DO $$ BEGIN RAISE WARNING 'before resize'; END $$;
});
$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

$num_entries = $node->safe_psql('postgres', q(
	SELECT num_entries FROM pg_stat_log_info()
));
ok($num_entries > 0, "have entries before max_entries change");

# Clean restart with a different max_entries
$node->stop;
$node->append_conf('postgresql.conf', "pg_stat_log.max_entries = 128");
$node->start;

# Stats should have been discarded due to capacity mismatch
$max_entries = $node->safe_psql('postgres', q(
	SELECT max_entries FROM pg_stat_log_info()
));
is($max_entries, "128", "max_entries reflects new GUC after restart");

$num_entries = $node->safe_psql('postgres', q(
	SELECT num_entries FROM pg_stat_log_info()
));
is($num_entries, "0",
	"persisted stats discarded after max_entries change");

# Verify new entries can be tracked with the new capacity
$node->safe_psql('postgres', q{
	DO $$ BEGIN RAISE WARNING 'after resize'; END $$;
});
$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

$num_entries = $node->safe_psql('postgres', q(
	SELECT num_entries FROM pg_stat_log_info()
));
ok($num_entries > 0, "new entries tracked after max_entries change");

# ---------------------------------------------------------------
# Test 7: Stats discarded when max_entries is lowered across restart
# ---------------------------------------------------------------

# A different max_entries changes the length of the persisted block, so
# PostgreSQL cannot parse the stats file and resets every stats kind. The
# reset must size the block from the new max_entries, not from the header
# restored from the file, or it writes past the smaller block.
$node->safe_psql('postgres', q{
	CREATE TABLE core_stats (i int);
	INSERT INTO core_stats SELECT generate_series(1, 10);
});
$result = $node->safe_psql('postgres', q(
	SELECT n_tup_ins FROM pg_stat_user_tables WHERE relname = 'core_stats'
));
is($result, "10", "core statistics recorded before restart");

$node->stop;
$node->append_conf('postgresql.conf', "pg_stat_log.max_entries = 64");
my $log_offset = -s $node->logfile;
$node->start;

$result = $node->safe_psql('postgres', q(
	SELECT n_tup_ins FROM pg_stat_user_tables WHERE relname = 'core_stats'
));
is($result, "0", "core statistics discarded along with pg_stat_log's");

$max_entries = $node->safe_psql('postgres', q(
	SELECT max_entries FROM pg_stat_log_info()
));
is($max_entries, "64", "max_entries reflects the lowered GUC after restart");

$num_entries = $node->safe_psql('postgres', q(
	SELECT num_entries FROM pg_stat_log_info()
));
is($num_entries, "0",
	"persisted stats discarded after lowering max_entries");

ok($node->log_contains(qr/corrupted statistics file/, $log_offset),
	"stats file written with the old max_entries is discarded");
ok( !$node->log_contains(
		qr/pg_stat_log: discarding persisted stats/, $log_offset),
	"reset sized the block from the new max_entries");

$node->safe_psql('postgres', q{
	DO $$ BEGIN RAISE WARNING 'after shrink'; END $$;
});
$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

$num_entries = $node->safe_psql('postgres', q(
	SELECT num_entries FROM pg_stat_log_info()
));
ok($num_entries > 0, "new entries tracked after lowering max_entries");

done_testing();
