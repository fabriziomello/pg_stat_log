/*--------------------------------------------------------------------------
 *
 * pg_stat_log.c
 *		Cumulative statistics about log messages.
 *
 * Hooks into emit_log_hook to count log messages grouped by
 * (elevel, sqlerrcode, database_oid, user_oid, backend_type).
 *
 * Uses the fixed-amount Custom Cumulative Stats API introduced in
 * PostgreSQL 18, following the same pattern as test_custom_fixed_stats.c.
 *
 * Copyright (c) 2026, PlanetScale Inc.
 *
 * IDENTIFICATION
 *		pg_stat_log/pg_stat_log.c
 *
 *--------------------------------------------------------------------------
 */

#include "postgres.h"

#include "funcapi.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "storage/proc.h"
#include "utils/builtins.h"
#include "utils/errcodes.h"
#include "utils/guc.h"
#include "utils/pgstat_internal.h"
#include "utils/timestamp.h"
#include "utils/tuplestore.h"

#include "pg_stat_log_errcodes.h"

PG_MODULE_MAGIC_EXT(
					.name = "pg_stat_log",
					.version = PG_VERSION
);

/*
 * Custom stats kind ID — registered at
 * https://wiki.postgresql.org/wiki/CustomCumulativeStats
 */
#define PGSTAT_KIND_LOG 28

/* GUC defaults and bounds */
#define PGSTAT_LOG_DEFAULT_MAX		1024
#define PGSTAT_LOG_MIN_MAX			64
#define PGSTAT_LOG_MAX_MAX			INT_MAX

/*
 * Data structures
 */
typedef struct PgStatLogSlot
{
	bool		used;
	BackendType backend_type;
	Oid			dboid;
	Oid			userid;
	int			elevel;
	int			sqlerrcode;
	PgStat_Counter count;
} PgStatLogSlot;

/*
 * Stats data block. Variable-length: header followed by entries[max].
 * Two of these exist in shared memory: stats and reset_offset.
 */
typedef struct PgStatLog
{
	int			max_entries;
	int			num_entries;
	TimestampTz stat_reset_timestamp;
	PgStatLogSlot entries[FLEXIBLE_ARRAY_MEMBER];
} PgStatLog;

/*
 * Shared memory wrapper. LWLock + changecount + data. The data area
 * holds two consecutive PgStatLog blocks (stats + reset_offset).
 */
typedef struct PgStatLogShared
{
	LWLock		lock;
	uint32		changecount;
	char		data[FLEXIBLE_ARRAY_MEMBER];
} PgStatLogShared;

/*
 * GUC variables
 */
static bool pg_stat_log_enabled = true;
static int	pg_stat_log_min_elevel = WARNING;
static int	pg_stat_log_max = PGSTAT_LOG_DEFAULT_MAX;

/*
 * Computed sizes (set in _PG_init based on pg_stat_log.max_entries)
 */
static Size stats_block_size;	/* one PgStatLog block */

/*
 * Hook state
 */
static emit_log_hook_type prev_emit_log_hook = NULL;
static bool in_emit_log_hook = false;

/*
 * Accessor helpers
 */
static inline PgStatLog *
pg_stat_log_get_stats(PgStatLogShared *shmem)
{
	return (PgStatLog *) shmem->data;
}

static inline PgStatLog *
pg_stat_log_get_reset_offset(PgStatLogShared *shmem)
{
	return (PgStatLog *) (shmem->data + stats_block_size);
}

/*
 * Errcode name lookup
 */
static const char *
pg_stat_log_errcode_name(int sqlerrcode)
{
	for (int i = 0; pg_stat_log_errcodes[i].name != NULL; i++)
	{
		if (pg_stat_log_errcodes[i].sqlerrcode == sqlerrcode)
			return pg_stat_log_errcodes[i].name;
	}
	return NULL;
}

/*
 * PgStat_KindInfo — filled dynamically in _PG_init
 */
static void pg_stat_log_init_shmem_cb(void *stats);
static void pg_stat_log_reset_all_cb(TimestampTz ts);
static void pg_stat_log_snapshot_cb(void);

static PgStat_KindInfo log_stats_kind;

/*
 * init_shmem_cb — initialize shared memory
 */
static void
pg_stat_log_init_shmem_cb(void *stats)
{
	PgStatLogShared *shmem = (PgStatLogShared *) stats;
	PgStatLog *s;

	LWLockInitialize(&shmem->lock, LWTRANCHE_PGSTATS_DATA);

	s = pg_stat_log_get_stats(shmem);
	s->max_entries = pg_stat_log_max;
	s->num_entries = 0;
}

/*
 * reset_all_cb — reset statistics
 */
static void
pg_stat_log_reset_all_cb(TimestampTz ts)
{
	PgStatLogShared *shmem;
	PgStatLog *s;
	PgStatLog *reset;

	shmem = (PgStatLogShared *)
		pgstat_get_custom_shmem_data(PGSTAT_KIND_LOG);
	s = pg_stat_log_get_stats(shmem);
	reset = pg_stat_log_get_reset_offset(shmem);

	LWLockAcquire(&shmem->lock, LW_EXCLUSIVE);
	pgstat_copy_changecounted_stats(reset, s, stats_block_size,
									&shmem->changecount);
	s->stat_reset_timestamp = ts;
	LWLockRelease(&shmem->lock);
}

/*
 * snapshot_cb — build snapshot for reads
 */
static void
pg_stat_log_snapshot_cb(void)
{
	PgStatLogShared *shmem;
	PgStatLog *snap;
	PgStatLog *reset;
	PgStatLog *reset_local;
	int				i;

	shmem = (PgStatLogShared *)
		pgstat_get_custom_shmem_data(PGSTAT_KIND_LOG);
	snap = (PgStatLog *)
		pgstat_get_custom_snapshot_data(PGSTAT_KIND_LOG);

	/* Copy current stats via changecount protocol */
	pgstat_copy_changecounted_stats(snap, pg_stat_log_get_stats(shmem),
									stats_block_size, &shmem->changecount);

	/* Read reset_offset under shared lock */
	reset = pg_stat_log_get_reset_offset(shmem);
	reset_local = (PgStatLog *) palloc(stats_block_size);

	LWLockAcquire(&shmem->lock, LW_SHARED);
	memcpy(reset_local, reset, stats_block_size);
	LWLockRelease(&shmem->lock);

	/* Apply reset offsets — same as FIXED_COMP in test module */
	for (i = 0; i < snap->num_entries; i++)
	{
		if (snap->entries[i].used && i < reset_local->num_entries &&
			reset_local->entries[i].used)
			snap->entries[i].count -= reset_local->entries[i].count;
	}

	pfree(reset_local);
}

/*
 * emit_log_hook — count log messages
 */
static void
pg_stat_log_emit_hook(ErrorData *edata)
{
	PgStatLogShared *shmem;
	PgStatLog  *s;
	Oid			dboid;
	Oid			userid;
	bool		lock_held = false;
	int			i;

	if (prev_emit_log_hook)
		prev_emit_log_hook(edata);

	if (!pg_stat_log_enabled)
		return;

	if (edata->elevel < pg_stat_log_min_elevel)
		return;

	if (in_emit_log_hook)
		return;

	/*
	 * pgstat shared memory might not be set up yet during early startup or
	 * in auxiliary processes before attachment.
	 */
	if ((!IsUnderPostmaster && IsPostmasterEnvironment) || !MyProc)
		return;

	in_emit_log_hook = true;
	PG_TRY();
	{
		shmem = (PgStatLogShared *)
			pgstat_get_custom_shmem_data(PGSTAT_KIND_LOG);

		dboid = MyDatabaseId;

		{
			int		sec_context;

			GetUserIdAndSecContext(&userid, &sec_context);
		}

		LWLockAcquire(&shmem->lock, LW_EXCLUSIVE);
		lock_held = true;

		s = pg_stat_log_get_stats(shmem);

		/* Scan existing entries for a match */
		for (i = 0; i < s->num_entries; i++)
		{
			if (s->entries[i].used &&
				s->entries[i].elevel == edata->elevel &&
				s->entries[i].sqlerrcode == edata->sqlerrcode &&
				s->entries[i].dboid == dboid &&
				s->entries[i].userid == userid &&
				s->entries[i].backend_type == MyBackendType)
			{
				pgstat_begin_changecount_write(&shmem->changecount);
				s->entries[i].count++;
				pgstat_end_changecount_write(&shmem->changecount);
				break;
			}
		}

		/* Not found — create new entry if space available */
		if (i == s->num_entries && s->num_entries < s->max_entries)
		{
			pgstat_begin_changecount_write(&shmem->changecount);
			s->entries[s->num_entries].used = true;
			s->entries[s->num_entries].elevel = edata->elevel;
			s->entries[s->num_entries].sqlerrcode = edata->sqlerrcode;
			s->entries[s->num_entries].dboid = dboid;
			s->entries[s->num_entries].userid = userid;
			s->entries[s->num_entries].backend_type = MyBackendType;
			s->entries[s->num_entries].count = 1;
			s->num_entries++;
			pgstat_end_changecount_write(&shmem->changecount);
		}
		/* else: silently drop when full */
	}
	PG_FINALLY();
	{
		if (lock_held)
			LWLockRelease(&shmem->lock);
		in_emit_log_hook = false;
	}
	PG_END_TRY();
}

#if PG_VERSION_NUM < 190000
static const struct config_enum_entry server_message_level_options[] = {
	{"debug5", DEBUG5, false},
	{"debug4", DEBUG4, false},
	{"debug3", DEBUG3, false},
	{"debug2", DEBUG2, false},
	{"debug1", DEBUG1, false},
	{"debug", DEBUG2, true},
	{"info", INFO, false},
	{"notice", NOTICE, false},
	{"warning", WARNING, false},
	{"error", ERROR, false},
	{"log", LOG, false},
	{"fatal", FATAL, false},
	{"panic", PANIC, false},
	{NULL, 0, false}
};
#endif

/*
 * Module initialization
 */
void
_PG_init(void)
{
	Size		shared_size;

	if (!process_shared_preload_libraries_in_progress)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("pg_stat_log must be loaded via "
						"shared_preload_libraries")));

	/* Define GUCs before computing sizes */
	DefineCustomBoolVariable("pg_stat_log.enabled",
							 "Enable collection of log statistics.",
							 NULL,
							 &pg_stat_log_enabled,
							 true,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomEnumVariable("pg_stat_log.min_error_level",
							 "Minimum error level to track.",
							 NULL,
							 &pg_stat_log_min_elevel,
							 WARNING,
							 server_message_level_options,
							 PGC_SUSET,
							 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("pg_stat_log.max_entries",
							"Maximum number of distinct log entry "
							"combinations to track.",
							NULL,
							&pg_stat_log_max,
							PGSTAT_LOG_DEFAULT_MAX,
							PGSTAT_LOG_MIN_MAX,
							PGSTAT_LOG_MAX_MAX,
							PGC_POSTMASTER,
							0,
							NULL, NULL, NULL);

	MarkGUCPrefixReserved("pg_stat_log");

	/* Compute sizes based on pg_stat_log.max_entries */
	stats_block_size = offsetof(PgStatLog, entries) +
		(Size) pg_stat_log_max * sizeof(PgStatLogSlot);

	shared_size = offsetof(PgStatLogShared, data) +
		2 * stats_block_size;

	/* Fill in the KindInfo struct — use memcpy because .name is const */
	{
		PgStat_KindInfo tmp = {
			.name = "pg_stat_log",
			.fixed_amount = true,
			.write_to_file = true,
			.shared_size = shared_size,
			.shared_data_off = offsetof(PgStatLogShared, data),
			.shared_data_len = stats_block_size,
			.init_shmem_cb = pg_stat_log_init_shmem_cb,
			.reset_all_cb = pg_stat_log_reset_all_cb,
			.snapshot_cb = pg_stat_log_snapshot_cb,
		};

		memcpy(&log_stats_kind, &tmp, sizeof(PgStat_KindInfo));
	}

	pgstat_register_kind(PGSTAT_KIND_LOG, &log_stats_kind);

	/* Install emit_log_hook */
	prev_emit_log_hook = emit_log_hook;
	emit_log_hook = pg_stat_log_emit_hook;
}

/*
 * SQL-callable functions
 */
PG_FUNCTION_INFO_V1(pg_stat_log_data);

/*
 * pg_stat_log_data()
 *		Return all tracked log statistics as a set of rows.
 */
Datum
pg_stat_log_data(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	PgStatLog *snap;
	int			i;

	pgstat_snapshot_fixed(PGSTAT_KIND_LOG);
	snap = (PgStatLog *)
		pgstat_get_custom_snapshot_data(PGSTAT_KIND_LOG);

	InitMaterializedSRF(fcinfo, 0);

	for (i = 0; i < snap->num_entries; i++)
	{
		Datum		values[7];
		bool		nulls[7] = {0};
		PgStatLogSlot *slot = &snap->entries[i];
		const char *errname;

		if (!slot->used)
			continue;

		/* Skip entries whose count went to zero after reset subtraction */
		if (slot->count <= 0)
			continue;

		values[0] = CStringGetTextDatum(
			GetBackendTypeDesc(slot->backend_type));

		if (OidIsValid(slot->dboid))
			values[1] = ObjectIdGetDatum(slot->dboid);
		else
			nulls[1] = true;

		if (OidIsValid(slot->userid))
			values[2] = ObjectIdGetDatum(slot->userid);
		else
			nulls[2] = true;

		values[3] = CStringGetTextDatum(error_severity(slot->elevel));
		values[4] = CStringGetTextDatum(unpack_sql_state(slot->sqlerrcode));

		errname = pg_stat_log_errcode_name(slot->sqlerrcode);
		if (errname)
			values[5] = CStringGetTextDatum(errname);
		else
			nulls[5] = true;

		values[6] = Int64GetDatum(slot->count);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc,
							values, nulls);
	}

	return (Datum) 0;
}

PG_FUNCTION_INFO_V1(pg_stat_log_reset);

/*
 * pg_stat_log_reset()
 *		Reset all tracked log statistics.
 */
Datum
pg_stat_log_reset(PG_FUNCTION_ARGS)
{
	pgstat_reset_of_kind(PGSTAT_KIND_LOG);

	PG_RETURN_VOID();
}
