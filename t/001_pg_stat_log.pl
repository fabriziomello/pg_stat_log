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

done_testing();
