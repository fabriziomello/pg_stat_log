/*--------------------------------------------------------------------------
 *
 * pg_stat_log.c
 *		Cumulative statistics about log messages.
 *
 * Hooks into emit_log_hook to count log messages grouped by
 * (elevel, sqlerrcode, database_oid, user_oid, backend_type, query_id).
 * The query identifier is tracked only with pg_stat_log.compute_query_id.
 *
 * Connection lifecycle records written by log_connections and
 * log_disconnections are counted under extension-defined SQLSTATEs
 * (PSL01-PSL03), attributed to the connected database and login role.
 *
 * With pg_stat_log.track_audit, pgaudit audit records are counted in their
 * own stats kind (see pg_stat_log_audit.c) and, here, under PSA01-PSA02.
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
#include "access/xact.h"
#include "common/hashfn.h"
#include "nodes/queryjumble.h"
#include "storage/ipc.h"
#include "storage/proc.h"
#include "tcop/tcopprot.h"
#include "utils/builtins.h"
#include "utils/errcodes.h"
#include "utils/guc.h"
#include "utils/pgstat_internal.h"
#include "utils/timestamp.h"
#include "utils/tuplestore.h"

#include "pg_stat_log_audit.h"
#include "pg_stat_log_errcodes.h"

#define PGSTAT_LOG_MODULE_NAME  "pg_stat_log"
#define PGSTAT_LOG_VERSION      "0.4" /* default_version in pg_stat_log.control */
#define PGSTAT_LOG_TRANCHE_NAME PGSTAT_LOG_MODULE_NAME

PG_MODULE_MAGIC_EXT(.name = PGSTAT_LOG_MODULE_NAME, .version = PGSTAT_LOG_VERSION);

/*
 * Custom stats kind ID — registered at
 * https://wiki.postgresql.org/wiki/CustomCumulativeStats
 */
#define PGSTAT_KIND_LOG 28

/* GUC defaults and bounds */
#define PGSTAT_LOG_MAX_DEFAULT 1024
#define PGSTAT_LOG_MIN_ENTRIES 64
#define PGSTAT_LOG_MAX_ENTRIES (PGSTAT_LOG_MAX_DEFAULT * PGSTAT_LOG_MAX_DEFAULT)

/*
 * Extension-defined SQLSTATEs for connection lifecycle records, which
 * PostgreSQL logs as 00000. Class "PS" is unused by core errcodes.txt.
 */
#define PGSTAT_LOG_ERRCODE_CONNECTION_AUTHENTICATED MAKE_SQLSTATE('P', 'S', 'L', '0', '1')
#define PGSTAT_LOG_ERRCODE_CONNECTION_AUTHORIZED    MAKE_SQLSTATE('P', 'S', 'L', '0', '2')
#define PGSTAT_LOG_ERRCODE_DISCONNECTION            MAKE_SQLSTATE('P', 'S', 'L', '0', '3')

/*
 * Extension-defined SQLSTATEs for pgaudit records, which pgaudit logs
 * without an errcode, counted with pg_stat_log.track_audit
 */
#define PGSTAT_LOG_ERRCODE_AUDIT_SESSION MAKE_SQLSTATE('P', 'S', 'A', '0', '1')
#define PGSTAT_LOG_ERRCODE_AUDIT_OBJECT  MAKE_SQLSTATE('P', 'S', 'A', '0', '2')

/* Extension versions whose pg_stat_log_data() returns different columns */
typedef enum PgStatLogApiVersion
{
    PGSTAT_LOG_V0_1,
    PGSTAT_LOG_V0_3,
} PgStatLogApiVersion;

#define PGSTAT_LOG_DATA_COLS_V0_1 7
#define PGSTAT_LOG_DATA_COLS_V0_3 8
#define PGSTAT_LOG_DATA_COLS      8 /* maximum of above */

/*
 * Data structures
 */
typedef struct PgStatLogSlot
{
    int32          next; /* next slot index in bucket chain, or -1 */
    BackendType    backend_type;
    Oid            dboid;
    Oid            userid;
    int            elevel;
    int            sqlerrcode;
    int64          queryid; /* 0 if not tracked */
    PgStat_Counter count;
} PgStatLogSlot;

/*
 * Stats data block. Variable-length: a header followed by a payload laid out
 * as (entries first to keep 8-byte alignment without padding):
 *
 *   PgStatLogSlot entries[max_entries]   insertion-ordered slots
 *   int32         heads[max_entries]     bucket chain heads (-1 = empty)
 *
 * The slots form an index-based separate-chaining hash table: heads[bucket]
 * points to the first slot of a chain and each slot's "next" links the rest.
 * Slots are allocated sequentially (slot i is live iff i < num_entries) and
 * never evicted, so lookups, inserts, and drops walk only one bucket chain
 * (average length = load factor) and stay O(1) expected even at full load.
 * Links are array indices (not pointers), so the block is snapshot- and
 * persistence-safe.  Use the accessors below to reach each sub-array.
 *
 * Why not a standard PostgreSQL hash table?  The fixed-amount custom stats
 * API snapshots this block with a raw memcpy and persists/restores it
 * verbatim (fwrite/fread) with no serialize callbacks, so everything in the
 * block must be position-independent and self-contained.  dynahash chains
 * entries with raw pointers, simplehash is process-local and grows by
 * reallocation, and dshash would require switching to variable-amount stats
 * (64-bit key limit, unbounded DSA growth, no extension-visible enumeration,
 * and allocation inside emit_log_hook).  See "Design notes" in README.md.
 */
typedef struct PgStatLog
{
    int  max_entries;
    int  num_entries;
    char data[FLEXIBLE_ARRAY_MEMBER];
} PgStatLog;

/*
 * Shared memory wrapper. LWLock + changecount + metadata + data. Metadata
 * fields (stat_reset_timestamp, n_dropped) live outside the copied stats
 * block so they can be read directly under the LWLock without the
 * changecount protocol. The data area holds one PgStatLog block.
 */
typedef struct PgStatLogShared
{
    LWLock      lock;
    uint32      changecount;
    TimestampTz stat_reset_timestamp;
    uint64      n_dropped;
    char        data[FLEXIBLE_ARRAY_MEMBER];
} PgStatLogShared;

/*
 * Connection lifecycle records. PostgreSQL logs them at LOG without an
 * errcode, so they are recognized by the function that emits them.
 */
typedef enum PgStatLogLifecycleEvent
{
    PGSTAT_LOG_EVENT_AUTHENTICATED,
    PGSTAT_LOG_EVENT_AUTHORIZED,
    PGSTAT_LOG_EVENT_DISCONNECTION,
    PGSTAT_LOG_NUM_EVENTS
} PgStatLogLifecycleEvent;

typedef struct PgStatLogLifecycleOrigin
{
    const char             *filename;
    const char             *funcname;
    PgStatLogLifecycleEvent event;
} PgStatLogLifecycleOrigin;

/* Keep in sync with check-upstream-anchors.pl */
static const PgStatLogLifecycleOrigin pg_stat_log_lifecycle_origins[] = {
    {"auth.c",     "set_authn_id",          PGSTAT_LOG_EVENT_AUTHENTICATED},
    {"auth.c",     "ClientAuthentication",  PGSTAT_LOG_EVENT_AUTHENTICATED},
    {"postinit.c", "PerformAuthentication", PGSTAT_LOG_EVENT_AUTHORIZED   },
    {"postgres.c", "log_disconnections",    PGSTAT_LOG_EVENT_DISCONNECTION},
};

/* Indexed by PgStatLogLifecycleEvent */
static const PgStatLogErrCode pg_stat_log_lifecycle_codes[] = {
    {PGSTAT_LOG_ERRCODE_CONNECTION_AUTHENTICATED, "connection_authenticated"},
    {PGSTAT_LOG_ERRCODE_CONNECTION_AUTHORIZED,    "connection_authorized"   },
    {PGSTAT_LOG_ERRCODE_DISCONNECTION,            "disconnection"           },
};

StaticAssertDecl(lengthof(pg_stat_log_lifecycle_codes) == PGSTAT_LOG_NUM_EVENTS,
                 "pg_stat_log_lifecycle_codes must match PgStatLogLifecycleEvent");

static const PgStatLogErrCode pg_stat_log_audit_codes[] = {
    {PGSTAT_LOG_ERRCODE_AUDIT_SESSION, "audit_session"},
    {PGSTAT_LOG_ERRCODE_AUDIT_OBJECT,  "audit_object" },
};

/*
 * GUC variables
 */
static bool pg_stat_log_enabled          = true;
static int  pg_stat_log_min_elevel       = WARNING;
static int  pg_stat_log_max              = PGSTAT_LOG_MAX_DEFAULT;
static bool pg_stat_log_compute_query_id = false;
static int  pg_stat_log_track_audit      = PGSTAT_LOG_TRACK_AUDIT_OFF;
int         pg_stat_log_audit_max        = PGSTAT_LOG_AUDIT_MAX_DEFAULT;

static const struct config_enum_entry track_audit_options[] = {
    {"off",     PGSTAT_LOG_TRACK_AUDIT_OFF,     false},
    {"command", PGSTAT_LOG_TRACK_AUDIT_COMMAND, false},
    {"object",  PGSTAT_LOG_TRACK_AUDIT_OBJECT,  false},
    {"on",      PGSTAT_LOG_TRACK_AUDIT_COMMAND, true },
    {NULL,      0,                              false}
};

/*
 * Computed sizes (set in _PG_init based on pg_stat_log.max_entries)
 */
static Size stats_block_size; /* one PgStatLog block */

/*
 * Hook state
 */
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;
static emit_log_hook_type      prev_emit_log_hook      = NULL;
static bool                    in_emit_log_hook        = false;

/*
 * Connection events logged before the session's database and login role are
 * known; counted at the end of the startup transaction.
 */
static int pending_connection_events[PGSTAT_LOG_NUM_EVENTS];

/*
 * Accessor helpers
 */
static inline PgStatLog *
pg_stat_log_get_stats(PgStatLogShared *shmem)
{
    return (PgStatLog *) shmem->data;
}

static inline PgStatLogSlot *
pg_stat_log_entries(PgStatLog *s)
{
    return (PgStatLogSlot *) s->data;
}

static inline int32 *
pg_stat_log_heads(PgStatLog *s)
{
    return (int32 *) (s->data + sizeof(PgStatLogSlot) * (Size) s->max_entries);
}

/*
 * Errcode name lookup
 */
static const char *
pg_stat_log_errcode_name(int sqlerrcode)
{
    for (int i = 0; i < PGSTAT_LOG_NUM_EVENTS; i++)
    {
        if (pg_stat_log_lifecycle_codes[i].sqlerrcode == sqlerrcode)
            return pg_stat_log_lifecycle_codes[i].name;
    }
    for (int i = 0; i < lengthof(pg_stat_log_audit_codes); i++)
    {
        if (pg_stat_log_audit_codes[i].sqlerrcode == sqlerrcode)
            return pg_stat_log_audit_codes[i].name;
    }
    for (int i = 0; pg_stat_log_errcodes[i].name != NULL; i++)
    {
        if (pg_stat_log_errcodes[i].sqlerrcode == sqlerrcode)
            return pg_stat_log_errcodes[i].name;
    }
    return NULL;
}

/*
 * Hash function for slot lookup — combines all key fields into a uint32
 * used to pick a chain bucket (hash % max_entries).
 */
static inline uint32
pg_stat_log_hash_key(BackendType backend_type, Oid dboid, Oid userid, int elevel, int sqlerrcode,
                     int64 queryid)
{
    uint32 h;

    h = murmurhash32((uint32) backend_type);
    h = hash_combine(h, murmurhash32((uint32) dboid));
    h = hash_combine(h, murmurhash32((uint32) userid));
    h = hash_combine(h, murmurhash32((uint32) elevel));
    h = hash_combine(h, murmurhash32((uint32) sqlerrcode));
    h = hash_combine(h, (uint32) murmurhash64((uint64) queryid));
    return h;
}

/*
 * PgStat_KindInfo — filled dynamically in _PG_init
 */
static void pg_stat_log_init_backend_cb(void);
static void pg_stat_log_init_shmem_cb(void *stats);
static void pg_stat_log_reset_all_cb(TimestampTz ts);
static void pg_stat_log_snapshot_cb(void);

static PgStat_KindInfo log_stats_kind;

/*
 * init_backend_cb — per-backend initialization
 *
 * Runs in every backend after the stats file has been loaded by the
 * startup process. Validates that persisted max_entries matches the
 * current GUC. A changed pg_stat_log.max_entries changes the length of the
 * persisted block, so PostgreSQL cannot parse the stats file, discards it
 * and calls reset_all_cb, which rebuilds the block. This check is a safety
 * net against a restored block with a stale layout.
 */
static void
pg_stat_log_init_backend_cb(void)
{
    PgStatLogShared *shmem;
    PgStatLog       *s;

    shmem = (PgStatLogShared *) pgstat_get_custom_shmem_data(PGSTAT_KIND_LOG);
    s     = pg_stat_log_get_stats(shmem);

    if (s->max_entries != pg_stat_log_max)
    {
        elog(LOG,
             "pg_stat_log: discarding persisted stats "
             "(max_entries changed from %d to %d)",
             s->max_entries,
             pg_stat_log_max);

        LWLockAcquire(&shmem->lock, LW_EXCLUSIVE);

        pgstat_begin_changecount_write(&shmem->changecount);
        s->max_entries = pg_stat_log_max;
        s->num_entries = 0;
        memset(pg_stat_log_heads(s), 0xFF, sizeof(int32) * (Size) s->max_entries);
        pgstat_end_changecount_write(&shmem->changecount);

        shmem->stat_reset_timestamp = GetCurrentTimestamp();
        shmem->n_dropped            = 0;

        LWLockRelease(&shmem->lock);
    }
}

/*
 * init_shmem_cb — initialize shared memory
 *
 * Only runs in the postmaster (see StatsShmemInit), after the main LWLock
 * array has been set up. This is the first place it is safe to call
 * LWLockNewTrancheId(), which needs shared memory to exist.
 */
static void
pg_stat_log_init_shmem_cb(void *stats)
{
    PgStatLogShared *shmem = (PgStatLogShared *) stats;
    PgStatLog       *s;

#if PG_VERSION_NUM < 190000
    LWLockInitialize(&shmem->lock, LWLockNewTrancheId());
#else
    LWLockInitialize(&shmem->lock, LWLockNewTrancheId(PGSTAT_LOG_TRANCHE_NAME));
#endif
    shmem->stat_reset_timestamp = GetCurrentTimestamp();
    shmem->n_dropped            = 0;

    s              = pg_stat_log_get_stats(shmem);
    s->max_entries = pg_stat_log_max;
    s->num_entries = 0;
    memset(pg_stat_log_heads(s), 0xFF, sizeof(int32) * (Size) s->max_entries);
}

/*
 * shmem_startup_hook — register the tranche name in every process.
 *
 * On fork-based platforms backends inherit the tranche ID and the
 * registration from the postmaster, but under EXEC_BACKEND each child has
 * to re-register, so do it unconditionally here. The tranche ID is read
 * from shared memory (initialized by the init_shmem_cb above).
 */
static void
pg_stat_log_shmem_startup(void)
{
    if (prev_shmem_startup_hook)
        prev_shmem_startup_hook();

#if PG_VERSION_NUM < 190000
    {
        PgStatLogShared *shmem = (PgStatLogShared *) pgstat_get_custom_shmem_data(PGSTAT_KIND_LOG);
        LWLockRegisterTranche(shmem->lock.tranche, PGSTAT_LOG_TRANCHE_NAME);
    }
#endif

    pg_stat_log_audit_shmem_startup();
}

/*
 * reset_all_cb — reset statistics
 *
 * Empty all bucket chains and reset num_entries so slots are reclaimed for
 * reuse. Otherwise, once max_entries is reached, a reset would not free
 * capacity for new distinct combinations.
 */
static void
pg_stat_log_reset_all_cb(TimestampTz ts)
{
    PgStatLogShared *shmem;
    PgStatLog       *s;

    shmem = (PgStatLogShared *) pgstat_get_custom_shmem_data(PGSTAT_KIND_LOG);
    s     = pg_stat_log_get_stats(shmem);

    LWLockAcquire(&shmem->lock, LW_EXCLUSIVE);

    /*
     * After a stats file fails to load, the header holds whatever was read
     * from the file, so size the block from the GUC instead.
     */
    pgstat_begin_changecount_write(&shmem->changecount);
    s->max_entries = pg_stat_log_max;
    s->num_entries = 0;
    memset(pg_stat_log_heads(s), 0xFF, sizeof(int32) * (Size) s->max_entries);
    pgstat_end_changecount_write(&shmem->changecount);

    shmem->stat_reset_timestamp = ts;
    shmem->n_dropped            = 0;

    LWLockRelease(&shmem->lock);
}

/*
 * snapshot_cb — build snapshot for reads
 */
static void
pg_stat_log_snapshot_cb(void)
{
    PgStatLogShared *shmem;
    PgStatLog       *snap;

    shmem = (PgStatLogShared *) pgstat_get_custom_shmem_data(PGSTAT_KIND_LOG);
    snap  = (PgStatLog *) pgstat_get_custom_snapshot_data(PGSTAT_KIND_LOG);

    /* Copy current stats via changecount protocol */
    pgstat_copy_changecounted_stats(snap,
                                    pg_stat_log_get_stats(shmem),
                                    stats_block_size,
                                    &shmem->changecount);
}

/*
 * pg_stat_log_count — record one log message in shared memory
 *
 * Acquires the LWLock, walks the hash bucket chain to find or create the
 * entry, increments the counter, and releases the lock. The chain walk is
 * O(1) expected (average chain length = load factor) for all of lookup,
 * insert, and drop, even when the table is full.
 */
static void
pg_stat_log_count(BackendType backend_type, Oid dboid, Oid userid, int elevel, int sqlerrcode,
                  int64 queryid)
{
    PgStatLogShared *shmem;
    PgStatLog       *s;
    PgStatLogSlot   *entries;
    int32           *heads;
    uint32           hash;
    uint32           bucket;
    int32            idx;
    bool             found;

    shmem = (PgStatLogShared *) pgstat_get_custom_shmem_data(PGSTAT_KIND_LOG);

    LWLockAcquire(&shmem->lock, LW_EXCLUSIVE);

    s       = pg_stat_log_get_stats(shmem);
    entries = pg_stat_log_entries(s);
    heads   = pg_stat_log_heads(s);

    hash   = pg_stat_log_hash_key(backend_type, dboid, userid, elevel, sqlerrcode, queryid);
    bucket = hash % s->max_entries;

    found = false;
    for (idx = heads[bucket]; idx != -1; idx = entries[idx].next)
    {
        PgStatLogSlot *slot = &entries[idx];

        if (slot->backend_type == backend_type && slot->dboid == dboid && slot->userid == userid &&
            slot->elevel == elevel && slot->sqlerrcode == sqlerrcode && slot->queryid == queryid)
        {
            pgstat_begin_changecount_write(&shmem->changecount);
            slot->count++;
            pgstat_end_changecount_write(&shmem->changecount);
            found = true;
            break;
        }
    }

    if (!found)
    {
        if (s->num_entries < s->max_entries)
        {
            int32          newidx = s->num_entries;
            PgStatLogSlot *slot   = &entries[newidx];

            pgstat_begin_changecount_write(&shmem->changecount);
            slot->backend_type = backend_type;
            slot->dboid        = dboid;
            slot->userid       = userid;
            slot->elevel       = elevel;
            slot->sqlerrcode   = sqlerrcode;
            slot->queryid      = queryid;
            slot->count        = 1;
            slot->next         = heads[bucket];
            heads[bucket]      = newidx;
            s->num_entries++;
            pgstat_end_changecount_write(&shmem->changecount);
        }
        else
        {
            shmem->n_dropped++;
        }
    }

    LWLockRelease(&shmem->lock);
}

/*
 * pg_stat_log_classify_lifecycle — recognize connection lifecycle records
 *
 * elog.c has already reduced edata->filename to its base name.
 */
static bool
pg_stat_log_classify_lifecycle(const ErrorData *edata, PgStatLogLifecycleEvent *event)
{
    if (edata->elevel != LOG || edata->sqlerrcode != ERRCODE_SUCCESSFUL_COMPLETION ||
        edata->filename == NULL || edata->funcname == NULL)
        return false;

    for (int i = 0; i < lengthof(pg_stat_log_lifecycle_origins); i++)
    {
        const PgStatLogLifecycleOrigin *origin = &pg_stat_log_lifecycle_origins[i];

        if (strcmp(edata->funcname, origin->funcname) == 0 &&
            strcmp(edata->filename, origin->filename) == 0)
        {
            *event = origin->event;
            return true;
        }
    }

    return false;
}

/*
 * pg_stat_log_record_message — count one message that reached the server log
 *
 * The connection authenticated/authorized records are logged before the
 * session's database and login role are known, so they are held until
 * pg_stat_log_startup_xact_cb. The disconnection record is logged after
 * ProcKill, when shared memory can no longer be locked, so
 * pg_stat_log_disconnect_cb counts it ahead of time instead.
 *
 * The query identifier is the one log_line_prefix's %Q prints: the current
 * top-level statement's, or the session's most recent one while idle.
 */
static void
pg_stat_log_record_message(ErrorData *edata)
{
    PgStatLogLifecycleEvent event;
    Oid                     userid;
    int                     sec_context;
    int64                   queryid = 0;

    if (pg_stat_log_classify_lifecycle(edata, &event))
    {
        if (event != PGSTAT_LOG_EVENT_DISCONNECTION)
            pending_connection_events[event]++;
        return;
    }

    if (pg_stat_log_compute_query_id && IsQueryIdEnabled())
        queryid = pgstat_get_my_query_id();

    GetUserIdAndSecContext(&userid, &sec_context);
    pg_stat_log_count(MyBackendType,
                      MyDatabaseId,
                      userid,
                      edata->elevel,
                      edata->sqlerrcode,
                      queryid);
}

/*
 * pg_stat_log_record_audit — count one pgaudit record
 *
 * pg_stat_log_audit groups records by login role, which log_line_prefix's
 * %u prints next to them, and by the query identifier. pg_stat_log counts
 * them like any other LOG message, under PSA01 or PSA02 and without a query
 * identifier, whatever level pgaudit used.
 */
static void
pg_stat_log_record_audit(const PgStatLogAuditRecord *record)
{
    Oid   userid;
    int   sec_context;
    int64 queryid = 0;

    if (pg_stat_log_compute_query_id && IsQueryIdEnabled())
        queryid = pgstat_get_my_query_id();

    pg_stat_log_audit_count(record, MyBackendType, MyDatabaseId, MyProc->roleId, queryid);

    if (LOG < pg_stat_log_min_elevel)
        return;

    GetUserIdAndSecContext(&userid, &sec_context);
    pg_stat_log_count(MyBackendType,
                      MyDatabaseId,
                      userid,
                      LOG,
                      record->audit_type == PGSTAT_LOG_AUDIT_TYPE_OBJECT ?
                          PGSTAT_LOG_ERRCODE_AUDIT_OBJECT :
                          PGSTAT_LOG_ERRCODE_AUDIT_SESSION,
                      0);
}

/*
 * pg_stat_log_log_reaches_server — would a LOG record reach the server log?
 *
 * Mirrors is_log_level_output() in elog.c; check-upstream-anchors.pl
 * verifies in CI that the rule is unchanged.
 */
static bool
pg_stat_log_log_reaches_server(void)
{
#if PG_VERSION_NUM >= 190000
    int min_level = log_min_messages[MyBackendType];
#else
    int min_level = log_min_messages;
#endif

    return min_level == LOG || min_level <= ERROR;
}

/*
 * pg_stat_log_disconnect_cb — before_shmem_exit callback that counts the
 * disconnection record
 *
 * Runs before ShutdownPostgres, pgstat_shutdown_hook and ProcKill, while the
 * process still has its PGPROC, and applies the same conditions that decide
 * whether log_disconnections' record reaches the server log.
 */
static void
pg_stat_log_disconnect_cb(int code, Datum arg)
{
    /* PostgresMain installs log_disconnections only after InitPostgres() */
    if (!IsNormalProcessingMode())
        return;

    if (!pg_stat_log_enabled || LOG < pg_stat_log_min_elevel || !pg_stat_log_log_reaches_server())
        return;

    /* The record is written after MyBEEntry is cleared, so its %Q is 0 */
    pg_stat_log_count(MyBackendType,
                      MyDatabaseId,
                      MyProc->roleId,
                      LOG,
                      PGSTAT_LOG_ERRCODE_DISCONNECTION,
                      0);
}

/*
 * pg_stat_log_startup_xact_cb — attribute connection lifecycle events
 *
 * The first transaction a client backend or walsender ends is the startup
 * transaction of InitPostgres(). It commits once the login role, the database
 * and the startup options are all set, or aborts when startup fails with a
 * FATAL error, in which case only part of the attribution may be known.
 * MyProc->roleId is the login role; it is set before the remaining login
 * checks can fail.
 */
static void
pg_stat_log_startup_xact_cb(XactEvent event, void *arg)
{
    if (event != XACT_EVENT_PRE_COMMIT && event != XACT_EVENT_ABORT)
        return;

    UnregisterXactCallback(pg_stat_log_startup_xact_cb, NULL);

    if (!IsExternalConnectionBackend(MyBackendType))
        return;

    for (int i = 0; i < PGSTAT_LOG_NUM_EVENTS; i++)
    {
        for (; pending_connection_events[i] > 0; pending_connection_events[i]--)
            pg_stat_log_count(MyBackendType,
                              MyDatabaseId,
                              MyProc->roleId,
                              LOG,
                              pg_stat_log_lifecycle_codes[i].sqlerrcode,
                              0);
    }

    /*
     * Log_disconnections is final from here on; a configuration reload does
     * not change it in a running backend.
     */
    if (event == XACT_EVENT_PRE_COMMIT && IsUnderPostmaster && Log_disconnections)
        before_shmem_exit(pg_stat_log_disconnect_cb, 0);
}

/*
 * emit_log_hook — intercept log messages for counting
 *
 * Always forwards to the previous hook in the chain. Only counts the
 * message if pg_stat_log is enabled and the severity meets the threshold,
 * except for pgaudit records, which pg_stat_log.track_audit governs.
 */
static void
pg_stat_log_emit_hook(ErrorData *edata)
{
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
        PgStatLogAuditRecord audit_record;
        bool                 is_audit = false;

        /*
         * Read a pgaudit record before the previous hook runs: it may
         * rewrite the message, as pgauditlogtofile does.
         */
        if (pg_stat_log_enabled && pg_stat_log_track_audit != PGSTAT_LOG_TRACK_AUDIT_OFF)
            is_audit =
                pg_stat_log_audit_parse(edata,
                                        pg_stat_log_track_audit == PGSTAT_LOG_TRACK_AUDIT_OBJECT,
                                        &audit_record);

        if (prev_emit_log_hook)
            prev_emit_log_hook(edata);

        if (is_audit)
            pg_stat_log_record_audit(&audit_record);
        else if (pg_stat_log_enabled && edata->elevel >= pg_stat_log_min_elevel)
            pg_stat_log_record_message(edata);
    }
    PG_FINALLY();
    {
        in_emit_log_hook = false;
    }
    PG_END_TRY();
}

/*
 * server_message_level_options was introduced in commit
 * https://github.com/postgres/postgres/commit/0a20ff54f5e6
 * but only exported for use by extensions in
 * https://github.com/postgres/postgres/commit/38e0190ced71,
 * which will ship in PostgreSQL 19.
 */
#if PG_VERSION_NUM < 190000
static const struct config_enum_entry server_message_level_options[] = {
    {"debug5",  DEBUG5,  false},
    {"debug4",  DEBUG4,  false},
    {"debug3",  DEBUG3,  false},
    {"debug2",  DEBUG2,  false},
    {"debug1",  DEBUG1,  false},
    {"debug",   DEBUG2,  true },
    {"info",    INFO,    false},
    {"notice",  NOTICE,  false},
    {"warning", WARNING, false},
    {"error",   ERROR,   false},
    {"log",     LOG,     false},
    {"fatal",   FATAL,   false},
    {"panic",   PANIC,   false},
    {NULL,      0,       false}
};
#endif

/*
 * Module initialization
 */
void
_PG_init(void)
{
    Size shared_size;

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
                             NULL,
                             NULL,
                             NULL);

    DefineCustomEnumVariable("pg_stat_log.min_error_level",
                             "Minimum error level to track.",
                             NULL,
                             &pg_stat_log_min_elevel,
                             WARNING,
                             server_message_level_options,
                             PGC_SUSET,
                             0,
                             NULL,
                             NULL,
                             NULL);

    DefineCustomIntVariable("pg_stat_log.max_entries",
                            "Maximum number of distinct log entry "
                            "combinations to track.",
                            NULL,
                            &pg_stat_log_max,
                            PGSTAT_LOG_MAX_DEFAULT,
                            PGSTAT_LOG_MIN_ENTRIES,
                            PGSTAT_LOG_MAX_ENTRIES,
                            PGC_POSTMASTER,
                            0,
                            NULL,
                            NULL,
                            NULL);

    DefineCustomBoolVariable("pg_stat_log.compute_query_id",
                             "Tracks log messages per query identifier.",
                             "Has no effect when compute_query_id is off. With auto, "
                             "pg_stat_log enables query identifier computation.",
                             &pg_stat_log_compute_query_id,
                             false,
                             PGC_POSTMASTER,
                             0,
                             NULL,
                             NULL,
                             NULL);

    DefineCustomEnumVariable("pg_stat_log.track_audit",
                             "Tracks pgaudit audit records.",
                             "command groups them by class and command, object also by "
                             "object type and name.",
                             &pg_stat_log_track_audit,
                             PGSTAT_LOG_TRACK_AUDIT_OFF,
                             track_audit_options,
                             PGC_SIGHUP,
                             0,
                             NULL,
                             NULL,
                             NULL);

    DefineCustomIntVariable("pg_stat_log.audit_max_entries",
                            "Maximum number of distinct pgaudit record "
                            "combinations to track.",
                            NULL,
                            &pg_stat_log_audit_max,
                            PGSTAT_LOG_AUDIT_MAX_DEFAULT,
                            PGSTAT_LOG_MIN_ENTRIES,
                            PGSTAT_LOG_MAX_ENTRIES,
                            PGC_POSTMASTER,
                            0,
                            NULL,
                            NULL,
                            NULL);

    MarkGUCPrefixReserved(PGSTAT_LOG_MODULE_NAME);

    /* Like pg_stat_statements; a no-op when compute_query_id is off */
    if (pg_stat_log_compute_query_id)
        EnableQueryId();

    /* Compute sizes based on pg_stat_log.max_entries */
    stats_block_size = offsetof(PgStatLog, data) + sizeof(PgStatLogSlot) * (Size) pg_stat_log_max +
                       sizeof(int32) * (Size) pg_stat_log_max;

    shared_size = offsetof(PgStatLogShared, data) + stats_block_size;

    /* Fill in the KindInfo struct — use memcpy because .name is const */
    {
        PgStat_KindInfo tmp = {
            .name            = PGSTAT_LOG_MODULE_NAME,
            .fixed_amount    = true,
            .write_to_file   = true,
            .shared_size     = shared_size,
            .shared_data_off = offsetof(PgStatLogShared, data),
            .shared_data_len = stats_block_size,
            .init_backend_cb = pg_stat_log_init_backend_cb,
            .init_shmem_cb   = pg_stat_log_init_shmem_cb,
            .reset_all_cb    = pg_stat_log_reset_all_cb,
            .snapshot_cb     = pg_stat_log_snapshot_cb,
        };

        memcpy(&log_stats_kind, &tmp, sizeof(PgStat_KindInfo));
    }

    pgstat_register_kind(PGSTAT_KIND_LOG, &log_stats_kind);

    /* Whatever pg_stat_log.track_audit is; see pg_stat_log_audit_register() */
    pg_stat_log_audit_register();

    /*
     * Install shmem_startup_hook so every process registers the LWLock
     * tranche name (needed for EXEC_BACKEND; harmless on fork).
     */
    prev_shmem_startup_hook = shmem_startup_hook;
    shmem_startup_hook      = pg_stat_log_shmem_startup;

    /* Install emit_log_hook */
    prev_emit_log_hook = emit_log_hook;
    emit_log_hook      = pg_stat_log_emit_hook;

    /* Attribute connection lifecycle events once backend startup completes */
    RegisterXactCallback(pg_stat_log_startup_xact_cb, NULL);
}

/*
 * SQL-callable functions
 */
PG_FUNCTION_INFO_V1(pg_stat_log_data);
PG_FUNCTION_INFO_V1(pg_stat_log_data_0_3);

/*
 * pg_stat_log_data_internal
 *		Return all tracked log statistics as a set of rows, with the columns
 *		of the given extension version.
 */
static void
pg_stat_log_data_internal(FunctionCallInfo fcinfo, PgStatLogApiVersion api_version)
{
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    PgStatLog     *snap;
    PgStatLogSlot *entries;
    int            expected_cols;
    int            i;

    pgstat_snapshot_fixed(PGSTAT_KIND_LOG);
    snap = (PgStatLog *) pgstat_get_custom_snapshot_data(PGSTAT_KIND_LOG);

    InitMaterializedSRF(fcinfo, 0);

    expected_cols =
        api_version == PGSTAT_LOG_V0_1 ? PGSTAT_LOG_DATA_COLS_V0_1 : PGSTAT_LOG_DATA_COLS_V0_3;
    if (rsinfo->setDesc->natts != expected_cols)
        elog(ERROR, "incorrect number of output arguments");

    entries = pg_stat_log_entries(snap);

    for (i = 0; i < snap->num_entries; i++)
    {
        Datum          values[PGSTAT_LOG_DATA_COLS];
        bool           nulls[PGSTAT_LOG_DATA_COLS] = {0};
        int            col                         = 0;
        PgStatLogSlot *slot                        = &entries[i];
        const char    *errname;

        if (slot->count <= 0)
            continue;

        values[col++] = CStringGetTextDatum(GetBackendTypeDesc(slot->backend_type));

        if (OidIsValid(slot->dboid))
            values[col] = ObjectIdGetDatum(slot->dboid);
        else
            nulls[col] = true;
        col++;

        if (OidIsValid(slot->userid))
            values[col] = ObjectIdGetDatum(slot->userid);
        else
            nulls[col] = true;
        col++;

        if (api_version >= PGSTAT_LOG_V0_3)
        {
            if (slot->queryid != 0)
                values[col] = Int64GetDatum(slot->queryid);
            else
                nulls[col] = true;
            col++;
        }

        values[col++] = CStringGetTextDatum(error_severity(slot->elevel));
        values[col++] = CStringGetTextDatum(unpack_sql_state(slot->sqlerrcode));

        errname = pg_stat_log_errcode_name(slot->sqlerrcode);
        if (errname)
            values[col] = CStringGetTextDatum(errname);
        else
            nulls[col] = true;
        col++;

        values[col++] = Int64GetDatum(slot->count);

        Assert(col == expected_cols);
        tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
    }
}

/*
 * pg_stat_log_data()
 *		The 0.1 definition, without query_id. Databases where the extension
 *		has not been updated to 0.3 still call it.
 */
Datum
pg_stat_log_data(PG_FUNCTION_ARGS)
{
    pg_stat_log_data_internal(fcinfo, PGSTAT_LOG_V0_1);
    return (Datum) 0;
}

/*
 * pg_stat_log_data_0_3()
 *		The 0.3 definition, with query_id.
 */
Datum
pg_stat_log_data_0_3(PG_FUNCTION_ARGS)
{
    pg_stat_log_data_internal(fcinfo, PGSTAT_LOG_V0_3);
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

PG_FUNCTION_INFO_V1(pg_stat_log_info);

/*
 * pg_stat_log_info()
 *		Return metadata about the pg_stat_log shared memory area:
 *		max_entries capacity, current num_entries, number of dropped
 *		messages due to capacity, and the last reset timestamp.
 */
Datum
pg_stat_log_info(PG_FUNCTION_ARGS)
{
    ReturnSetInfo   *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    PgStatLogShared *shmem;
    PgStatLog       *s;
    Datum            values[4];
    bool             nulls[4] = {0};

    InitMaterializedSRF(fcinfo, 0);

    shmem = (PgStatLogShared *) pgstat_get_custom_shmem_data(PGSTAT_KIND_LOG);
    s     = pg_stat_log_get_stats(shmem);

    LWLockAcquire(&shmem->lock, LW_SHARED);
    values[0] = Int32GetDatum(s->max_entries);
    values[1] = Int32GetDatum(s->num_entries);
    values[2] = Int64GetDatum((int64) shmem->n_dropped);
    values[3] = TimestampTzGetDatum(shmem->stat_reset_timestamp);
    LWLockRelease(&shmem->lock);

    tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);

    return (Datum) 0;
}
