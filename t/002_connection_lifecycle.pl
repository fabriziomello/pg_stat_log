# Copyright (c) 2026, Fabrizio de Royes Mello

# Test counting of connection lifecycle records
#
# log_connections and log_disconnections write their records at LOG with
# SQLSTATE 00000. pg_stat_log counts them under extension-defined SQLSTATEs,
# attributed to the connected database and the login role:
#
#   PSL01  connection_authenticated
#   PSL02  connection_authorized
#   PSL03  disconnection
#
# Verifies:
# - Each record is counted once, for both authentication code paths
# - A startup failing after authorization keeps the login role
# - Physical walsenders are counted without a database
# - Other LOG records keep SQLSTATE 00000
# - A disconnection is counted only if its record reaches the server log
# - Nothing is counted while log_connections and log_disconnections are off
# - log_disconnections enabled with startup options is honored
# - A reload does not change log_disconnections for a running session

use strict;
use warnings FATAL => 'all';

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

if (!$use_unix_sockets)
{
	plan skip_all =>
	  "authentication tests cannot run without Unix-domain sockets";
}

# Streaming is needed for the walsender connection
my $node = PostgreSQL::Test::Cluster->new('lifecycle');
$node->init(allows_streaming => 1);
$node->append_conf(
	'postgresql.conf', q{
shared_preload_libraries = 'pg_stat_log'
pg_stat_log.min_error_level = 'log'
log_connections = 'authentication,authorization'
log_disconnections = on
log_statement = none
});

unlink($node->data_dir . '/pg_hba.conf');
$node->append_conf(
	'pg_hba.conf', q{
local app alice scram-sha-256
local replication all trust
local all all trust
});
$node->start;

$node->safe_psql(
	'postgres', q{
CREATE EXTENSION pg_stat_log;
SET password_encryption = 'scram-sha-256';
CREATE ROLE alice LOGIN PASSWORD 'alice-pass';
CREATE ROLE bob LOGIN;
CREATE DATABASE app;
});

my $superuser = $node->safe_psql('postgres', q(SELECT current_user));
my $alice_connstr = $node->connstr('app') . " user=alice password=alice-pass";
my $bob_connstr = $node->connstr('app') . " user=bob";

# Lifecycle counters of the pg_stat_log rows matching $filter
sub lifecycle_counts
{
	my ($filter) = @_;

	return $node->safe_psql(
		'postgres', qq{
		SELECT string_agg(concat_ws(' ', backend_type, sqlerrcode, sqlerrcode_name, count),
						  E'\\n' ORDER BY backend_type, sqlerrcode)
		FROM pg_stat_log
		WHERE sqlerrcode LIKE 'PSL%' AND $filter
	});
}

# A backend counts its disconnection while exiting, before it leaves
# pg_stat_activity
sub wait_for_backends_to_exit
{
	$node->poll_query_until(
		'postgres', q{
		SELECT count(*) = 0 FROM pg_stat_activity
		WHERE backend_type IN ('client backend', 'walsender')
		  AND pid <> pg_backend_pid()
	}) or die "timed out waiting for backends to exit";
}

# ---------------------------------------------------------------
# Test 1: Records attributed to the database and login role
# ---------------------------------------------------------------

$node->connect_ok(
	$alice_connstr,
	"alice connects with scram-sha-256",
	log_like =>
	  [qr/connection authenticated: identity="alice" method=scram-sha-256/]);
wait_for_backends_to_exit();

is( lifecycle_counts(q(database_name = 'app' AND user_name = 'alice')),
	"client backend PSL01 connection_authenticated 1
client backend PSL02 connection_authorized 1
client backend PSL03 disconnection 1",
	"scram-sha-256 session counted once per record");

# ---------------------------------------------------------------
# Test 2: Authentication without an authenticated identity
# ---------------------------------------------------------------

$node->connect_ok(
	$bob_connstr,
	"bob connects with trust",
	log_like => [qr/connection authenticated: user="bob" method=trust/]);
wait_for_backends_to_exit();

is( lifecycle_counts(q(database_name = 'app' AND user_name = 'bob')),
	"client backend PSL01 connection_authenticated 1
client backend PSL02 connection_authorized 1
client backend PSL03 disconnection 1",
	"trust session counted once per record");

# ---------------------------------------------------------------
# Test 3: Startup failing after authorization
# ---------------------------------------------------------------

$node->connect_fails(
	$node->connstr('no_such_db') . " user=alice",
	"alice cannot connect to a missing database",
	expected_stderr => qr/database "no_such_db" does not exist/);
wait_for_backends_to_exit();

is( lifecycle_counts(q(database_oid IS NULL AND user_name = 'alice')),
	"client backend PSL01 connection_authenticated 1
client backend PSL02 connection_authorized 1",
	"failed startup counted for the login role, without database or disconnection"
);

# ---------------------------------------------------------------
# Test 4: Physical walsender
# ---------------------------------------------------------------

$node->safe_psql('postgres', 'IDENTIFY_SYSTEM', replication => 'true');
wait_for_backends_to_exit();

is( lifecycle_counts(
		qq(backend_type = 'walsender' AND database_oid IS NULL AND user_name = '$superuser')
	),
	"walsender PSL01 connection_authenticated 1
walsender PSL02 connection_authorized 1
walsender PSL03 disconnection 1",
	"physical walsender counted without a database");

# ---------------------------------------------------------------
# Test 5: Other LOG records keep SQLSTATE 00000
# ---------------------------------------------------------------

$node->safe_psql('app',
	q(DO $$ BEGIN RAISE LOG 'not a connection record'; END $$));

my $result = $node->safe_psql(
	'postgres', q{
	SELECT string_agg(concat_ws(' ', sqlerrcode, sqlerrcode_name, count), E'\n')
	FROM pg_stat_log
	WHERE elevel = 'LOG' AND sqlerrcode NOT LIKE 'PSL%' AND database_name = 'app'
});
is($result, "00000 successful_completion 1",
	"RAISE LOG still counted as successful_completion");

$result = $node->safe_psql(
	'postgres', q{
	SELECT count(*) FROM pg_stat_log
	WHERE backend_type IN ('client backend', 'walsender') AND elevel = 'LOG'
	  AND database_oid IS NULL AND user_oid IS NULL
});
is($result, "0", "connection records are not counted without attribution");

# ---------------------------------------------------------------
# Test 6: Disconnection record not reaching the server log
# ---------------------------------------------------------------

# Authentication and authorization are logged before startup options apply
$node->safe_psql('postgres',
	q(GRANT SET ON PARAMETER log_min_messages TO bob));
$node->connect_ok(
	$bob_connstr . " options='-c log_min_messages=fatal'",
	"bob connects with log_min_messages = fatal");
wait_for_backends_to_exit();

is( lifecycle_counts(q(database_name = 'app' AND user_name = 'bob')),
	"client backend PSL01 connection_authenticated 2
client backend PSL02 connection_authorized 2
client backend PSL03 disconnection 1",
	"disconnection not counted when LOG does not reach the server log");

# ---------------------------------------------------------------
# Test 7: log_connections and log_disconnections off
# ---------------------------------------------------------------

$node->append_conf(
	'postgresql.conf', q{
log_connections = off
log_disconnections = off
});
$node->reload;
$node->poll_query_until(
	'postgres', q{
	SELECT current_setting('log_connections') = 'off'
	   AND current_setting('log_disconnections') = 'off'
}) or die "timed out waiting for the configuration reload";

$node->connect_ok($alice_connstr,
	"alice connects with log_connections and log_disconnections off");
wait_for_backends_to_exit();

is( lifecycle_counts(q(database_name = 'app' AND user_name = 'alice')),
	"client backend PSL01 connection_authenticated 1
client backend PSL02 connection_authorized 1
client backend PSL03 disconnection 1",
	"nothing counted while log_connections and log_disconnections are off");

# ---------------------------------------------------------------
# Test 8: log_disconnections enabled with startup options
# ---------------------------------------------------------------

$node->safe_psql('postgres',
	q(GRANT SET ON PARAMETER log_disconnections TO alice));
$node->connect_ok(
	$alice_connstr . " options='-c log_disconnections=on'",
	"alice enables log_disconnections at connection start",
	sql => 'SHOW log_disconnections',
	expected_stdout => qr/^on$/);
wait_for_backends_to_exit();

is( lifecycle_counts(q(database_name = 'app' AND user_name = 'alice')),
	"client backend PSL01 connection_authenticated 1
client backend PSL02 connection_authorized 1
client backend PSL03 disconnection 2",
	"disconnection counted when log_disconnections is set at connection start"
);

# ---------------------------------------------------------------
# Test 9: Reload in a running session
# ---------------------------------------------------------------

# PostgreSQL ignores reloaded PGC_SU_BACKEND settings in running backends, so
# the session still logs its disconnection
$node->safe_psql(
	'postgres', q{
CREATE DATABASE reload_db;
ALTER SYSTEM SET log_disconnections = on;
SELECT pg_reload_conf();
});
$node->poll_query_until('postgres',
	q(SELECT current_setting('log_disconnections') = 'on'))
  or die "timed out waiting for the configuration reload";

my $log_offset = -s $node->logfile;
my $session = $node->background_psql('reload_db');
is($session->query_safe('SHOW log_disconnections'),
	'on', "session starts with log_disconnections on");

$session->query_safe(q(ALTER SYSTEM SET log_disconnections = off));
$session->query_safe(q(ALTER SYSTEM SET work_mem = '7MB'));
$session->query_safe(q(SELECT pg_reload_conf()));
$node->poll_query_until('postgres',
	q(SELECT current_setting('log_disconnections') = 'off'))
  or die "timed out waiting for the configuration reload";

is($session->query_safe('SHOW work_mem'),
	'7MB', "session applied the reloaded configuration");
is($session->query_safe('SHOW log_disconnections'),
	'on', "session keeps log_disconnections on after the reload");

$session->quit;
$node->wait_for_log(qr/disconnection: session time: .* database=reload_db/,
	$log_offset);
wait_for_backends_to_exit();

is( lifecycle_counts(q(database_name = 'reload_db')),
	"client backend PSL03 disconnection 1",
	"disconnection logged after the reload is counted");

$node->connect_ok(
	$node->connstr('reload_db'),
	"session started after the reload has log_disconnections off",
	sql => 'SHOW log_disconnections',
	expected_stdout => qr/^off$/);
wait_for_backends_to_exit();

is( lifecycle_counts(q(database_name = 'reload_db')),
	"client backend PSL03 disconnection 1",
	"sessions started after the reload are not counted");

done_testing();
