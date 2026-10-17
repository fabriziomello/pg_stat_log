#!/usr/bin/perl
#
# Check the pgaudit source assumptions behind the audit record counters
#
# pg_stat_log recognizes a pgaudit audit record by the function and file
# that write it and by its "AUDIT: " prefix, then reads its CSV fields up to
# OBJECT_NAME (see pg_stat_log_audit.c). Each check names the assumption it
# guards; a failure means pg_stat_log_audit.c must be revisited for that
# pgaudit version.
#
# Usage: check-pgaudit-anchors.pl <pgaudit-source-dir>
#

use strict;
use warnings FATAL => 'all';

die "Usage: $0 <pgaudit-source-dir>\n" unless @ARGV == 1;

my $srcdir = $ARGV[0];
my $failures = 0;

# Must match PGAUDIT_FILENAME, PGAUDIT_FUNCNAME and PGAUDIT_PREFIX in
# pg_stat_log_audit.c
my $audit_file = 'pgaudit.c';
my $audit_function = 'log_audit_event';
my $audit_prefix = 'AUDIT: ';

# Must match pg_stat_log_audit_types and pg_stat_log_audit_classes in
# pg_stat_log_audit.c
my %audit_types = (
	AUDIT_TYPE_SESSION => 'SESSION',
	AUDIT_TYPE_OBJECT => 'OBJECT',);
my %audit_classes = (
	CLASS_READ => 'READ',
	CLASS_WRITE => 'WRITE',
	CLASS_FUNCTION => 'FUNCTION',
	CLASS_ROLE => 'ROLE',
	CLASS_DDL => 'DDL',
	CLASS_MISC => 'MISC',);

my @function_checks = (
	{
		function => $audit_function,
		in_order => [
			'ereport(',
			'errmsg("AUDIT: %s," INT64_FORMAT "," INT64_FORMAT ",%s,%s",',
			'AUDIT_TYPE_OBJECT : AUDIT_TYPE_SESSION,',
			'className,',
			'auditStr.data)'
		],
		why =>
		  'a record is AUDIT_TYPE, STATEMENT_ID, SUBSTATEMENT_ID and CLASS, then the fields in auditStr',
	},
	{
		function => $audit_function,
		sequence => [
			'initStringInfo(&auditStr);',
			'append_valid_csv(&auditStr, GetCommandTagName(stackItem->auditEvent.command));',
			q{appendStringInfoCharMacro(&auditStr, ',');},
			'append_valid_csv(&auditStr, stackItem->auditEvent.objectType);',
			q{appendStringInfoCharMacro(&auditStr, ',');},
			'append_valid_csv(&auditStr, stackItem->auditEvent.objectName);'
		],
		why => 'auditStr starts with COMMAND, OBJECT_TYPE and OBJECT_NAME',
	},
	{
		function => 'append_valid_csv',
		in_order => [
			'if (appendStr == NULL)',
			'return;',
			q{if (strpbrk(appendStr, ",\"\n\r"))},
			q{appendStringInfoCharMacro(buffer, '"');},
			q{if (*pChar == '"')},
			'appendStringInfoCharMacro(buffer, *pChar);',
			'appendStringInfoCharMacro(buffer, *pChar);',
			q{appendStringInfoCharMacro(buffer, '"');}
		],
		why =>
		  'a NULL field is empty, and a field is quoted only when it holds a comma, a double quote, CR or LF, with embedded double quotes doubled',
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
	my ($function) = @_;

	return slurp($audit_file) =~ /^(\Q$function\E\(.*?^\})/msg;
}

# Each name must be #defined to its value
sub check_defines
{
	my ($kind, $names) = @_;
	my $source = slurp($audit_file);
	my @missing =
	  grep { $source !~ /^#define\s+\Q$_\E\s+"\Q$names->{$_}\E"/m }
	  sort keys %$names;

	report(
		!@missing,
		"$audit_file: ${kind}_*",
		"the $kind names pg_stat_log_audit.c reads",
		join('; ', map { "missing '#define $_ \"$names->{$_}\"'" } @missing));
}

my ($version) = slurp('pgaudit.control') =~ /^default_version = '([^']+)'/m
  or die "$0: could not find the pgaudit version in pgaudit.control\n";

print "# pgaudit $version sources in $srcdir\n";

foreach my $check (@function_checks)
{
	my $what = "$audit_file: $check->{function}()";
	my @bodies = function_bodies($check->{function});

	if (@bodies != 1)
	{
		report(0, $what, $check->{why},
			"expected one definition, found " . scalar(@bodies));
		next;
	}

	my $body = $bodies[0];
	my @problems;

	if ($check->{in_order})
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
	elsif ($check->{sequence})
	{
		my $pattern = join('\s*', map { quotemeta } @{ $check->{sequence} });

		push @problems,
		  "missing, with nothing between them: "
		  . join(' ', map { "'$_'" } @{ $check->{sequence} })
		  unless $body =~ /$pattern/;
	}

	report(!@problems, $what, $check->{why}, join('; ', @problems));
}

# Any other "AUDIT: " message, in pgaudit.c or elsewhere, would be one
# pg_stat_log does not recognize
my @sites;
opendir my $dh, $srcdir or die "$0: could not open '$srcdir': $!\n";
foreach my $file (sort grep { /\.c$/ } readdir $dh)
{
	my $contents = slurp($file);

	push @sites, map { $file } $contents =~ /\Q"$audit_prefix\E/g;
}
closedir $dh;

my ($log_audit_event) = function_bodies($audit_function);
my $sites_problem =
  "found \"$audit_prefix\" in: " . (@sites ? join(', ', @sites) : 'no file');

$sites_problem .= ", and no $audit_function()"
  unless defined $log_audit_event;

report(
	@sites == 1
	  && $sites[0] eq $audit_file
	  && defined $log_audit_event
	  && index($log_audit_event, "\"$audit_prefix") >= 0,
	"$audit_file: \"$audit_prefix\"",
	"records are written only by $audit_function()",
	$sites_problem);

check_defines('AUDIT_TYPE', \%audit_types);
check_defines('CLASS', \%audit_classes);

# The CLASS values a record can carry are those log_audit_event() assigns
my @assigned = ($log_audit_event // '') =~ /\bclassName = (CLASS_\w+);/g;
my %unknown = map { $_ => 1 } grep { !exists $audit_classes{$_} } @assigned;

report(
	@assigned && !%unknown,
	"$audit_file: $audit_function() className",
	'every CLASS a record can carry is one pg_stat_log_audit.c reads',
	@assigned
	? 'unknown ' . join(', ', sort keys %unknown)
	: 'no className assignment found');

if ($failures)
{
	print "# $failures assumption(s) no longer hold for pgaudit $version\n";
	exit 1;
}

print "# all assumptions hold for pgaudit $version\n";
