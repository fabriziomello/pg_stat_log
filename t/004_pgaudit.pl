# Copyright (c) 2026, Fabrizio de Royes Mello

# Test counting pgaudit audit records
#
# With pg_stat_log.track_audit, the records pgaudit writes to the server log
# are counted in pg_stat_log_audit and, under PSA01 and PSA02, in
# pg_stat_log. The server log gives the expected number of records.
#
# Verifies:
# - Session records of the READ, WRITE, DDL and ROLE classes, attributed to
#   the login role
# - PSA01 and PSA02 rows in pg_stat_log
# - A forged RAISE LOG 'AUDIT: ...' is not counted
# - Object records through pgaudit.role, one record per relation with
#   pgaudit.log_relation, and a quoted object name
# - pg_stat_log.track_audit = on, command, object and off
# - Counts persist across a clean restart
# - Folding and dropping with pg_stat_log.audit_max_entries = 64
#
# Skipped when pgaudit is not installed.

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('pgaudit');

my $pkglibdir = $node->config_data('--pkglibdir');
plan skip_all => 'pgaudit is not installed'
  unless grep { -e "$pkglibdir/pgaudit$_" } ('.so', '.dylib', '.dll');

$node->init;

# log_statement would add ordinary LOG messages of the same users
$node->append_conf(
	'postgresql.conf', q{
log_statement = none
shared_preload_libraries = 'pgaudit, pg_stat_log'
pg_stat_log.track_audit = on
pg_stat_log.audit_max_entries = 64
pg_stat_log.min_error_level = 'log'
});
$node->start;
$node->safe_psql(
	'postgres', q{
	CREATE EXTENSION pg_stat_log;
	CREATE EXTENSION pgaudit;
	CREATE ROLE auditor;
	CREATE ROLE regress_alice LOGIN;
	GRANT CREATE ON SCHEMA public TO regress_alice;
	ALTER ROLE regress_alice SET pgaudit.log = 'read, write, ddl';
});

# Run $sql in a session of regress_alice
sub alice_psql
{
	my ($sql) = @_;

	return $node->safe_psql('postgres', $sql,
		extra_params => [ '--username' => 'regress_alice' ]);
}

# pg_stat_log_audit rows of $user, one per line:
# "audit_type class command [object_type object_name] count"
sub audit_rows
{
	my ($user, $condition) = @_;
	$condition //= 'true';

	return $node->safe_psql(
		'postgres', qq{
		SELECT string_agg(concat_ws(' ', audit_type, class, command,
									object_type, object_name, count),
						  E'\\n' ORDER BY audit_type, class, command,
						  object_type NULLS FIRST, object_name NULLS FIRST)
		FROM pg_stat_log_audit
		WHERE user_name = '$user' AND $condition
	});
}

sub audit_total
{
	return $node->safe_psql('postgres',
		'SELECT coalesce(sum(count), 0) FROM pg_stat_log_audit');
}

# The PSA rows of pg_stat_log summed over users:
# "sqlerrcode sqlerrcode_name elevel count"
sub psa_totals
{
	return $node->safe_psql(
		'postgres', q{
		SELECT string_agg(concat_ws(' ', sqlerrcode, sqlerrcode_name, elevel, count),
						  E'\n' ORDER BY sqlerrcode)
		FROM (SELECT sqlerrcode, sqlerrcode_name, elevel, sum(count) AS count
			  FROM pg_stat_log
			  WHERE sqlerrcode LIKE 'PSA%'
			  GROUP BY sqlerrcode, sqlerrcode_name, elevel) s
	});
}

# Number of records pgaudit wrote to the server log since $offset
sub logged_records
{
	my ($offset) = @_;
	my @records = slurp_file($node->logfile, $offset) =~ /LOG:  AUDIT: /g;

	return scalar @records;
}

sub set_track_audit
{
	my ($value) = @_;

	$node->append_conf('postgresql.conf',
		"pg_stat_log.track_audit = $value\n");
	$node->reload;
	$node->poll_query_until('postgres',
		"SELECT current_setting('pg_stat_log.track_audit') = '$value'")
	  or die "timed out waiting for pg_stat_log.track_audit = $value";
}

# ---------------------------------------------------------------
# Test 1: Session records
# ---------------------------------------------------------------

is($node->safe_psql('postgres', 'SHOW pg_stat_log.track_audit'),
	'command', 'pg_stat_log.track_audit = on means command');

my $log_offset = -s $node->logfile;
alice_psql(
	q{
	CREATE TABLE t1 (id int);
	INSERT INTO t1 VALUES (1), (2);
	SELECT * FROM t1;
	SELECT count(*) FROM t1;
});
$node->safe_psql('postgres',
	"SET pgaudit.log = 'role'; CREATE ROLE regress_bob");

is(logged_records($log_offset), 5, 'pgaudit wrote five records');
is(audit_total(), 5, 'five records counted');

# The DDL record is written by pgaudit's security definer event trigger
is( audit_rows('regress_alice'),
	"SESSION DDL CREATE TABLE 1\nSESSION READ SELECT 2\nSESSION WRITE INSERT 1",
	'session records grouped by class and command under the login role');
is( audit_rows($node->safe_psql('postgres', 'SELECT current_user')),
	"SESSION ROLE CREATE ROLE 1",
	'ROLE record');

is( psa_totals(),
	"PSA01 audit_session LOG 5",
	'session records counted under PSA01 as LOG in pg_stat_log');

is( $node->safe_psql(
		'postgres', q{
		SELECT count(*) FROM pg_stat_log
		WHERE user_name = 'regress_alice' AND sqlerrcode = '00000'
	}),
	'0',
	'audit records are not counted as 00000 with track_audit on');

# ---------------------------------------------------------------
# Test 2: A forged record is not counted
# ---------------------------------------------------------------

$log_offset = -s $node->logfile;
$node->safe_psql('postgres',
	q{DO $$ BEGIN RAISE LOG 'AUDIT: SESSION,1,1,READ,SELECT,,,forged,<none>'; END $$}
);
like(
	slurp_file($node->logfile, $log_offset),
	qr/LOG:  AUDIT: SESSION,1,1,READ,SELECT,,,forged/,
	'forged record written to the server log');
is(audit_total(), 5, 'forged record not counted in pg_stat_log_audit');
is( psa_totals(),
	"PSA01 audit_session LOG 5",
	'forged record not counted under PSA01');

# ---------------------------------------------------------------
# Test 3: Object fields
# ---------------------------------------------------------------

set_track_audit('object');
$node->safe_psql('postgres',
	'ALTER ROLE regress_alice SET pgaudit.log_relation = on');

$log_offset = -s $node->logfile;
alice_psql(
	q{
	CREATE TABLE "a,b" (x int);
	SELECT * FROM t1 JOIN "a,b" ON true;
});
is(logged_records($log_offset),
	3, 'pgaudit wrote one DDL record and one SELECT record per relation');
is( audit_rows('regress_alice', 'object_name IS NOT NULL'),
	qq{SESSION DDL CREATE TABLE TABLE public."a,b" 1
SESSION READ SELECT TABLE public."a,b" 1
SESSION READ SELECT TABLE public.t1 1},
	'object type and unquoted object name counted');

$node->safe_psql(
	'postgres', q{
	GRANT SELECT ON t1 TO auditor;
	SET pgaudit.role = 'auditor';
	SELECT * FROM t1;
});
is( audit_rows(
		$node->safe_psql('postgres', 'SELECT current_user'),
		"audit_type = 'OBJECT'"),
	'OBJECT READ SELECT TABLE public.t1 1',
	'object record through pgaudit.role');
is( psa_totals(),
	"PSA01 audit_session LOG 8\nPSA02 audit_object LOG 1",
	'object record counted under PSA02');

# ---------------------------------------------------------------
# Test 4: track_audit = off
# ---------------------------------------------------------------

set_track_audit('off');

$log_offset = -s $node->logfile;
alice_psql('SELECT * FROM t1');
is(logged_records($log_offset), 1, 'pgaudit wrote a record');
is(audit_total(), 9, 'record not counted in pg_stat_log_audit');
is( psa_totals(),
	"PSA01 audit_session LOG 8\nPSA02 audit_object LOG 1",
	'record not counted under PSA01');
is( $node->safe_psql(
		'postgres', q{
		SELECT concat_ws(' ', elevel, sqlerrcode, count) FROM pg_stat_log
		WHERE user_name = 'regress_alice' AND sqlerrcode = '00000'
	}),
	'LOG 00000 1',
	'record counted as an ordinary LOG message, as before 0.4');

# ---------------------------------------------------------------
# Test 5: Counts persist across a clean restart
# ---------------------------------------------------------------

my $before = audit_rows('regress_alice');
$node->restart;
is(audit_rows('regress_alice'),
	$before, 'pg_stat_log_audit persists across a clean restart');
is(audit_total(), 9, 'total persists across a clean restart');

# ---------------------------------------------------------------
# Test 6: Folding and dropping
# ---------------------------------------------------------------

set_track_audit('object');
$node->safe_psql(
	'postgres', q{
	SELECT pg_stat_log_audit_reset();
	SELECT format('CREATE TABLE f%s (x int)', i) FROM generate_series(1, 70) i \gexec
});

# One command-level row, then 63 object-level rows fill the 64 entries and
# the last 7 tables fold into the command-level row
my $sql =
	"SET pgaudit.log = 'read';\nSELECT 1;\n"
  . "SET pgaudit.log_relation = on;\n"
  . join('', map { "SELECT * FROM f$_;\n" } 1 .. 70);

# Neither INSERT has a command-level row to fold into
$sql .=
	"SET pgaudit.log = 'write';\nINSERT INTO f1 VALUES (1);\n"
  . "SET pgaudit.log_relation = off;\nINSERT INTO f2 VALUES (1);\n";

$log_offset = -s $node->logfile;
$node->safe_psql('postgres', $sql);
is(logged_records($log_offset), 73, 'pgaudit wrote 73 records');

is( $node->safe_psql(
		'postgres',
		'SELECT max_entries, num_entries, n_folded, n_dropped FROM pg_stat_log_audit_info()'
	),
	'64|64|7|2',
	'7 records folded and 2 dropped once the table is full');
is( audit_rows(
		$node->safe_psql('postgres', 'SELECT current_user'),
		'object_name IS NULL'),
	'SESSION READ SELECT 8',
	'folded records counted in the command-level row');
is( $node->safe_psql(
		'postgres', q{
		SELECT count(*) FROM pg_stat_log_audit
		WHERE object_name IN ('public.f63', 'public.f64')
	}),
	'1',
	'the last table with a row of its own is f63');

done_testing();
