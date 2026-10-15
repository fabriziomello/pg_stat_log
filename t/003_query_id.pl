# Copyright (c) 2026, Fabrizio de Royes Mello

# Test counting per query identifier
#
# With pg_stat_log.compute_query_id, messages are also grouped by the query
# identifier that %Q prints in log_line_prefix. The server log, written with
# log_line_prefix = 'qid=%Q ', gives the expected query_id values.
#
# Verifies:
# - pg_stat_log.compute_query_id has query identifiers computed under
#   compute_query_id = auto
# - Statements differing only in constants share a query_id
# - Messages logged without a query identifier have a NULL query_id
# - Connection lifecycle records have a NULL query_id
# - query_id persists across a clean restart
# - Nothing is tracked with pg_stat_log.compute_query_id or
#   compute_query_id off

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('query_id');
$node->init;
$node->append_conf(
	'postgresql.conf', q{
shared_preload_libraries = 'pg_stat_log'
pg_stat_log.compute_query_id = on
pg_stat_log.min_error_level = 'log'
log_connections = 'authentication,authorization'
log_disconnections = on
log_line_prefix = 'qid=%Q '
});
$node->start;
$node->safe_psql('postgres', 'CREATE EXTENSION pg_stat_log');

# query_id and count of the pg_stat_log rows for $sqlerrcode, most frequent
# first
sub query_id_counts
{
	my ($sqlerrcode) = @_;

	return $node->safe_psql(
		'postgres', qq{
		SELECT string_agg(concat_ws(' ', coalesce(query_id::text, 'NULL'), count),
						  E'\\n' ORDER BY count DESC, query_id)
		FROM pg_stat_log
		WHERE sqlerrcode = '$sqlerrcode'
	});
}

# Query identifiers that %Q printed for ERROR $message since $offset
sub logged_query_ids
{
	my ($offset, $message) = @_;
	my $log = slurp_file($node->logfile, $offset);

	return $log =~ /^qid=(-?\d+) ERROR:  \Q$message\E/mg;
}

# ---------------------------------------------------------------
# Test 1: query_id matches %Q
# ---------------------------------------------------------------

my $result = $node->safe_psql(
	'postgres', q{
	SELECT current_setting('compute_query_id'), context
	FROM pg_settings WHERE name = 'pg_stat_log.compute_query_id'
});
is($result, "auto|postmaster",
	"compute_query_id is auto and pg_stat_log.compute_query_id needs a restart"
);

my $log_offset = -s $node->logfile;
$node->psql('postgres', 'SELECT 1/0');
$node->psql('postgres', 'SELECT 2/0');
$node->psql('postgres', 'SELECT 1 % 0');

my @qids = logged_query_ids($log_offset, 'division by zero');
is(scalar @qids, 3, "three division by zero errors logged");
my ($qid_div, $qid_div2, $qid_mod) = @qids;
like($qid_div, qr/^-?[1-9][0-9]*$/,
	"query identifiers computed under compute_query_id = auto");
is($qid_div2, $qid_div,
	"statements differing only in constants share a query identifier");
isnt($qid_mod, $qid_div,
	"a different statement has its own query identifier");

is(query_id_counts('22012'), "$qid_div 2\n$qid_mod 1", "query_id matches %Q");

# ---------------------------------------------------------------
# Test 2: Messages logged without a query identifier
# ---------------------------------------------------------------

$log_offset = -s $node->logfile;
$node->psql('postgres', 'SET compute_query_id = off; SELECT 3/0');
is(join(' ', logged_query_ids($log_offset, 'division by zero')),
	"0", "no query identifier with compute_query_id set off in the session");
is( query_id_counts('22012'),
	"$qid_div 2\n$qid_mod 1\nNULL 1",
	"query_id is NULL with compute_query_id set off in the session");

$log_offset = -s $node->logfile;
$node->psql('postgres', 'SELECT FROM WHERE');
is(join(' ', logged_query_ids($log_offset, 'syntax error')),
	"0", "no query identifier for a syntax error");
is(query_id_counts('42601'), "NULL 1", "query_id is NULL for a syntax error");

# ---------------------------------------------------------------
# Test 3: Connection lifecycle records
# ---------------------------------------------------------------

# The backend still has its last statement's query identifier while exiting
$log_offset = -s $node->logfile;
$node->safe_psql('postgres', 'SELECT 1');
$node->wait_for_log(qr/disconnection: session time:/, $log_offset);

my @lifecycle_qids = slurp_file($node->logfile) =~
  /^qid=(-?\d+) LOG:  (?:connection authenticated|connection authorized|disconnection):/mg;
cmp_ok(scalar @lifecycle_qids, '>=', 3,
	"connection lifecycle records logged");
is(join(' ', grep { $_ ne '0' } @lifecycle_qids),
	'', "no query identifier logged for connection lifecycle records");

$result = $node->safe_psql(
	'postgres', q{
	SELECT string_agg(concat_ws(' ', sqlerrcode, coalesce(query_id::text, 'NULL')),
					  E'\n' ORDER BY sqlerrcode)
	FROM pg_stat_log
	WHERE sqlerrcode LIKE 'PSL%'
});
is( $result,
	"PSL01 NULL\nPSL02 NULL\nPSL03 NULL",
	"query_id is NULL for connection lifecycle records");

# ---------------------------------------------------------------
# Test 4: query_id persists across a clean restart
# ---------------------------------------------------------------

$node->restart;
is( query_id_counts('22012'),
	"$qid_div 2\n$qid_mod 1\nNULL 1",
	"query_id persists across a clean restart");

$node->psql('postgres', 'SELECT 4/0');
is( query_id_counts('22012'),
	"$qid_div 3\n$qid_mod 1\nNULL 1",
	"statement after the restart counted under the persisted query_id");

# ---------------------------------------------------------------
# Test 5: pg_stat_log.compute_query_id off
# ---------------------------------------------------------------

$node->append_conf(
	'postgresql.conf', q{
pg_stat_log.compute_query_id = off
compute_query_id = on
});
$node->restart;
$node->safe_psql('postgres', 'SELECT pg_stat_log_reset()');

$log_offset = -s $node->logfile;
$node->psql('postgres', 'SELECT 1/0');
is(join(' ', logged_query_ids($log_offset, 'division by zero')),
	$qid_div, "compute_query_id = on computes the query identifier");
is(query_id_counts('22012'),
	"NULL 1", "query_id is NULL with pg_stat_log.compute_query_id off");

# ---------------------------------------------------------------
# Test 6: compute_query_id off
# ---------------------------------------------------------------

$node->append_conf(
	'postgresql.conf', q{
pg_stat_log.compute_query_id = on
compute_query_id = off
});
$node->restart;
$node->safe_psql('postgres', 'SELECT pg_stat_log_reset()');

$log_offset = -s $node->logfile;
$node->psql('postgres', 'SELECT 1/0');
is(join(' ', logged_query_ids($log_offset, 'division by zero')),
	"0", "compute_query_id = off computes no query identifier");
is(query_id_counts('22012'),
	"NULL 1", "query_id is NULL with compute_query_id off");

done_testing();
