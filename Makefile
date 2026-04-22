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

clean: clean-errcodes
clean-errcodes:
	rm -f pg_stat_log_errcodes.h
