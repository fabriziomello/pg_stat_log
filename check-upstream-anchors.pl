#!/usr/bin/perl
#
# Check the PostgreSQL source assumptions behind the connection lifecycle
# counters
#
# pg_stat_log recognizes the log_connections and log_disconnections records
# by the functions that emit them, attributes them when the startup
# transaction ends, and relies on log_disconnections keeping its startup
# value for the rest of the session. At exit, it predicts whether the
# disconnection record reaches the server log. Each check names the
# assumption it guards; a failure means pg_stat_log.c must be revisited for
# that PostgreSQL version.
#
# Usage: check-upstream-anchors.pl <postgres-source-dir>
#

use strict;
use warnings FATAL => 'all';

die "Usage: $0 <postgres-source-dir>\n" unless @ARGV == 1;

my $srcdir = $ARGV[0];
my $failures = 0;

# The first four checks must match pg_stat_log_lifecycle_origins in
# pg_stat_log.c
my @function_checks = (
	{
		file => 'src/backend/libpq/auth.c',
		function => 'set_authn_id',
		contains => [ 'ereport(LOG', 'connection authenticated: identity=' ],
		why => 'PSL01 is logged by set_authn_id()',
	},
	{
		file => 'src/backend/libpq/auth.c',
		function => 'ClientAuthentication',
		contains => [ 'ereport(LOG', 'connection authenticated: user=' ],
		why =>
		  'PSL01 without an authenticated identity is logged by ClientAuthentication()',
	},
	{
		file => 'src/backend/utils/init/postinit.c',
		function => 'PerformAuthentication',
		contains => [ 'ereport(LOG', 'connection authorized: user=' ],
		why => 'PSL02 is logged by PerformAuthentication()',
	},
	{
		file => 'src/backend/tcop/postgres.c',
		function => 'log_disconnections',
		contains => [ 'ereport(LOG', 'disconnection: session time:' ],
		why => 'PSL03 is logged by log_disconnections()',
	},
	{
		file => 'src/backend/tcop/postgres.c',
		function => 'PostgresMain',
		contains => [
			'if (IsUnderPostmaster && Log_disconnections)',
			'on_proc_exit(log_disconnections, 0);'
		],
		why =>
		  'log_disconnections() is installed under the condition pg_stat_log_startup_xact_cb() uses',
	},
	{
		file => 'src/backend/tcop/postgres.c',
		function => 'log_disconnections',
		lacks => ['Log_disconnections'],
		why => 'log_disconnections() logs unconditionally once installed',
	},
	{
		file => 'src/backend/utils/misc/guc.c',
		function => 'set_config_with_handle',
		in_order => [
			'case PGC_SU_BACKEND:',
			'case PGC_BACKEND:',
			'if (context == PGC_SIGHUP)',
			'if (IsUnderPostmaster && changeVal && !is_reload)',
			'return -1;'
		],
		why =>
		  'a configuration reload does not change PGC_SU_BACKEND settings in running backends',
	},
	{
		file => 'src/backend/utils/init/postinit.c',
		function => 'InitPostgres',
		in_order => [
			'before_shmem_exit(ShutdownPostgres, 0);',
			'StartTransactionCommand();',
			'PerformAuthentication(',
			'InitializeSessionUserId(',
			'process_startup_options(',
			'CommitTransactionCommand();'
		],
		why =>
		  'authentication runs in the startup transaction, which a FATAL aborts and a walsender commits after its startup options',
	},
	{
		file => 'src/backend/utils/init/postinit.c',
		function => 'InitPostgres',
		in_order => [
			'MyDatabaseId = ',
			'process_startup_options(',
			'CommitTransactionCommand();'
		],
		why =>
		  'the startup transaction commits after the database and the startup options are set',
	},
	{
		file => 'src/backend/utils/init/miscinit.c',
		function => 'SetAuthenticatedUserId',
		contains => ['MyProc->roleId = userid;'],
		why => 'MyProc->roleId holds the login role',
	},
	{
		file => 'src/backend/utils/error/elog.c',
		function => 'is_log_level_output',
		contains => ['if (log_min_level == LOG || log_min_level <= ERROR)'],
		why => 'pg_stat_log_log_reaches_server() mirrors the LOG output rule',
	},
);

sub slurp
{
	my ($file) = @_;
	my $path = "$srcdir/$file";

	open my $fh, '<', $path or die "$0: could not open '$path': $!\n";
	local $/;
	my $contents = <$fh>;
	close $fh;
	return $contents;
}

sub report
{
	my ($ok, $what, $why, $problem) = @_;

	if ($ok)
	{
		print "ok - $what: $why\n";
	}
	else
	{
		print "not ok - $what: $why\n";
		print "  $problem\n";
		$failures++;
	}
}

# From the definition line, which starts with the function name, to the
# first closing brace in column 1
sub function_bodies
{
	my ($file, $function) = @_;

	return slurp($file) =~ /^(\Q$function\E\(.*?^\})/msg;
}

my ($major) = slurp('configure.ac') =~ /^AC_INIT\(\[PostgreSQL\], \[(\d+)/m
  or die "$0: could not find the PostgreSQL version in configure.ac\n";

print "# PostgreSQL $major sources in $srcdir\n";

foreach my $check (@function_checks)
{
	my $what = "$check->{file}: $check->{function}()";
	my @bodies = function_bodies($check->{file}, $check->{function});

	if (@bodies != 1)
	{
		report(0, $what, $check->{why},
			"expected one definition, found " . scalar(@bodies));
		next;
	}

	my $body = $bodies[0];
	my @problems;

	if ($check->{contains})
	{
		my @missing = grep { index($body, $_) < 0 } @{ $check->{contains} };

		push @problems, "missing " . join(', ', map { "'$_'" } @missing)
		  if @missing;
	}
	elsif ($check->{in_order})
	{
		my $pos = 0;

		foreach my $text (@{ $check->{in_order} })
		{
			$pos = index($body, $text, $pos);
			if ($pos < 0)
			{
				push @problems, "missing '$text' in order";
				last;
			}
			$pos += length($text);
		}
	}

	if ($check->{lacks})
	{
		my @present = grep { index($body, $_) >= 0 } @{ $check->{lacks} };

		push @problems, "unexpected " . join(', ', map { "'$_'" } @present)
		  if @present;
	}

	report(!@problems, $what, $check->{why}, join('; ', @problems));
}

my $decl =
  $major >= 19
  ? 'extern PGDLLIMPORT int log_min_messages[];'
  : 'extern PGDLLIMPORT int log_min_messages;';

report(
	index(slurp('src/include/utils/guc.h'), $decl) >= 0,
	"src/include/utils/guc.h: log_min_messages",
	"pg_stat_log_log_reaches_server() reads log_min_messages as declared for PostgreSQL $major",
	"missing '$decl'");

my $guc_file =
  $major >= 19
  ? 'src/backend/utils/misc/guc_parameters.dat'
  : 'src/backend/utils/misc/guc_tables.c';
my $guc_definition =
  $major >= 19
  ? qr/\{ name => 'log_disconnections',[^}]*context => 'PGC_SU_BACKEND'/
  : qr/\{"log_disconnections", PGC_SU_BACKEND,/;

report(
	scalar(slurp($guc_file) =~ $guc_definition),
	"$guc_file: log_disconnections",
	'log_disconnections is PGC_SU_BACKEND, so it can only change at connection start',
	'log_disconnections is not defined as PGC_SU_BACKEND');

if ($failures)
{
	print "# $failures assumption(s) no longer hold for PostgreSQL $major\n";
	exit 1;
}

print "# all assumptions hold for PostgreSQL $major\n";
