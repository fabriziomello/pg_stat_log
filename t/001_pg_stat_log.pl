# Copyright (c) 2026, PlanetScale Inc.

# Test pg_stat_log extension
#
# Verifies:
# - Log messages are counted correctly
# - Filtering by min_error_level works
# - Enable/disable toggle works
# - Stats persist across clean restart
# - Stats are lost after crash recovery
# - Reset zeroes the counters

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

# ---------------------------------------------------------------
# Test 1: Generate warnings and check counts
# ---------------------------------------------------------------

# Generate some warnings via DO blocks
$node->safe_psql('postgres', q(
	DO $$ BEGIN RAISE WARNING 'test warning 1'; END $$;
));
$node->safe_psql('postgres', q(
	DO $$ BEGIN RAISE WARNING 'test warning 2'; END $$;
));
$node->safe_psql('postgres', q(
	DO $$ BEGIN RAISE WARNING 'test warning 3'; END $$;
));

# Force stats flush
$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

my $result = $node->safe_psql('postgres', q(
	SELECT count FROM pg_stat_log_data()
	WHERE elevel = 'WARNING' AND sqlerrcode = '01000'
));
# Should have at least 3 warnings
ok($result >= 3, "warning count is at least 3");

# ---------------------------------------------------------------
# Test 2: Errors are tracked
# ---------------------------------------------------------------

# Generate an error (will be rolled back but still logged)
$node->psql('postgres', q(SELECT 1/0));

$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

$result = $node->safe_psql('postgres', q(
	SELECT count FROM pg_stat_log_data()
	WHERE elevel = 'ERROR' AND sqlerrcode = '22012'
));
is($result, "1", "division by zero error counted");

# ---------------------------------------------------------------
# Test 3: pg_stat_log view works (with database/user names)
# ---------------------------------------------------------------

$result = $node->safe_psql('postgres', q(
	SELECT count(*) FROM pg_stat_log WHERE count > 0
));
ok($result > 0, "pg_stat_log view returns rows");

# ---------------------------------------------------------------
# Test 4: Disable via GUC stops counting
# ---------------------------------------------------------------

$node->safe_psql('postgres', q(ALTER SYSTEM SET pg_stat_log.enabled = off));
$node->safe_psql('postgres', q(SELECT pg_reload_conf()));

# Wait briefly for reload
sleep(1);

# Record the current warning count
my $count_before = $node->safe_psql('postgres', q(
	SELECT COALESCE(sum(count), 0) FROM pg_stat_log_data()
	WHERE elevel = 'WARNING'
));

# Generate more warnings while disabled
$node->safe_psql('postgres', q(
	DO $$ BEGIN RAISE WARNING 'should not be counted'; END $$;
));

$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

my $count_after = $node->safe_psql('postgres', q(
	SELECT COALESCE(sum(count), 0) FROM pg_stat_log_data()
	WHERE elevel = 'WARNING'
));
is($count_after, $count_before, "no new counts while disabled");

# Re-enable
$node->safe_psql('postgres', q(ALTER SYSTEM SET pg_stat_log.enabled = on));
$node->safe_psql('postgres', q(SELECT pg_reload_conf()));
sleep(1);

# ---------------------------------------------------------------
# Test 5: min_error_level filtering
# ---------------------------------------------------------------

# Set min level to ERROR — warnings should be ignored
$node->safe_psql('postgres',
	q(ALTER SYSTEM SET pg_stat_log.min_error_level = 'error'));
$node->safe_psql('postgres', q(SELECT pg_reload_conf()));
sleep(1);

$count_before = $node->safe_psql('postgres', q(
	SELECT COALESCE(sum(count), 0) FROM pg_stat_log_data()
	WHERE elevel = 'WARNING'
));

$node->safe_psql('postgres', q(
	DO $$ BEGIN RAISE WARNING 'filtered out'; END $$;
));

$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

$count_after = $node->safe_psql('postgres', q(
	SELECT COALESCE(sum(count), 0) FROM pg_stat_log_data()
	WHERE elevel = 'WARNING'
));
is($count_after, $count_before,
	"warnings not counted with min_error_level = error");

# Restore default
$node->safe_psql('postgres',
	q(ALTER SYSTEM SET pg_stat_log.min_error_level = 'warning'));
$node->safe_psql('postgres', q(SELECT pg_reload_conf()));
sleep(1);

# ---------------------------------------------------------------
# Test 6: Stats persist across clean restart
# ---------------------------------------------------------------

$result = $node->safe_psql('postgres', q(
	SELECT count FROM pg_stat_log_data()
	WHERE elevel = 'ERROR' AND sqlerrcode = '22012'
));
my $error_count_pre_restart = $result;

$node->stop;
$node->start;

$result = $node->safe_psql('postgres', q(
	SELECT count FROM pg_stat_log_data()
	WHERE elevel = 'ERROR' AND sqlerrcode = '22012'
));
is($result, $error_count_pre_restart,
	"error count persists after clean restart");

# ---------------------------------------------------------------
# Test 7: Stats lost after crash recovery
# ---------------------------------------------------------------

$node->stop('immediate');
$node->start;

$result = $node->safe_psql('postgres', q(
	SELECT COALESCE(sum(count), 0) FROM pg_stat_log_data()
));
is($result, "0", "all counts are zero after crash recovery");

# ---------------------------------------------------------------
# Test 8: Reset zeroes counters
# ---------------------------------------------------------------

# Generate some data first
$node->safe_psql('postgres', q(
	DO $$ BEGIN RAISE WARNING 'after crash'; END $$;
));
$node->safe_psql('postgres', q(SELECT pg_stat_force_next_flush()));

$result = $node->safe_psql('postgres', q(
	SELECT COALESCE(sum(count), 0) FROM pg_stat_log_data()
));
ok($result > 0, "have counts before reset");

$node->safe_psql('postgres', q(SELECT pg_stat_log_reset()));

$result = $node->safe_psql('postgres', q(
	SELECT COALESCE(sum(count), 0) FROM pg_stat_log_data()
));
is($result, "0", "all counts are zero after reset");

done_testing();
