MODULE_big = pg_stat_log

EXTENSION = pg_stat_log
DATA = pg_stat_log--1.0.sql

OBJS = pg_stat_log.o

REGRESS_OPTS = --temp-instance=tmp_check --temp-config=pg_stat_log.conf
REGRESS = pg_stat_log

TAP_TESTS = 1

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Check for the errcodes.txt on the standard Postgres distribution
ERRCODES_TXT = $(shell $(PG_CONFIG) --sharedir)/errcodes.txt

# Generate the errcode-name lookup header from errcodes.txt.
pg_stat_log_errcodes.h: generate-errcode-names.pl
	@if [ -f "$(ERRCODES_FILE)" ]; then \
		$(PERL) $< --outfile $@ $(ERRCODES_FILE); \
	elif [ -f "$(ERRCODES_TXT)" ]; then \
		$(PERL) $< --outfile $@ $(ERRCODES_TXT); \
	else \
		echo "ERROR: cannot find errcodes.txt; set ERRCODES_FILE=/path/to/errcodes.txt" >&2; \
		exit 1; \
	fi

pg_stat_log.o: pg_stat_log_errcodes.h

format:
	@if [ "$$(uname)" = "Darwin" ]; then \
		dsymutil pg_stat_log.dylib; \
		dwarfdump pg_stat_log.dylib.dSYM | grep -A2 DW_TAG_typedef | \
		grep DW_AT_name | sed 's/.*("\(.*\)")/\1/' | sort -u > typedefs.list; \
	else \
		objdump -W pg_stat_log.so | egrep -A3 DW_TAG_typedef | \
		perl -e 'while (<>) { chomp; @flds = split; next unless (1 < @flds); \
		next if $$flds[0] ne "DW_AT_name" && $$flds[1] ne "DW_AT_name"; \
		next if $$flds[-1] =~ /^DW_FORM_str/; print $$flds[-1],"\n"; }' | \
		sort -u > typedefs.list; \
	fi
	pgindent --typedefs=typedefs.list pg_stat_log.c

clean: clean-errcodes clean-typedefs clean-dsym
clean-errcodes:
	rm -f pg_stat_log_errcodes.h
clean-typedefs:
	rm -f typedefs.list
clean-dsym:
	rm -rf pg_stat_log.dylib.dSYM
