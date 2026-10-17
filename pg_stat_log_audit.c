/*--------------------------------------------------------------------------
 *
 * pg_stat_log_audit.c
 *		Cumulative statistics about pgaudit audit records.
 *
 * pgaudit writes every audit record with one ereport() in log_audit_event(),
 * as "AUDIT: " followed by these CSV fields:
 *
 *   AUDIT_TYPE,STATEMENT_ID,SUBSTATEMENT_ID,CLASS,COMMAND,OBJECT_TYPE,
 *   OBJECT_NAME,STATEMENT,PARAMETER[,ROWS]
 *
 * Records are recognized by that origin, which a RAISE LOG cannot fake, and
 * read up to OBJECT_NAME. They are counted grouped by (backend_type,
 * database_oid, user_oid, query_id, audit_type, class, command) and, with
 * pg_stat_log.track_audit = object, (object_type, object_name), in a second
 * fixed-amount custom stats kind laid out like pg_stat_log's own (see
 * PgStatLog in pg_stat_log.c). check-pgaudit-anchors.pl verifies the record
 * format against pgaudit's sources in CI.
 *
 * pgaudit can write a record for every statement, often under the same key,
 * so existing slots are counted with atomic increments while the lock is held
 * in shared mode. Adding a slot, resetting and copying the table take it
 * exclusively.
 *
 * Copyright (c) 2026, PlanetScale Inc.
 *
 * IDENTIFICATION
 *		pg_stat_log/pg_stat_log_audit.c
 *
 *--------------------------------------------------------------------------
 */

#include "postgres.h"

#include "funcapi.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "common/hashfn.h"
#include "port/atomics.h"
#include "tcop/cmdtag.h"
#include "utils/builtins.h"
#include "utils/pgstat_internal.h"
#include "utils/timestamp.h"
#include "utils/tuplestore.h"

#include "pg_stat_log_audit.h"

#define PGSTAT_LOG_AUDIT_NAME "pg_stat_log_audit"

/* Keep in sync with check-pgaudit-anchors.pl */
#define PGAUDIT_FILENAME "pgaudit.c"
#define PGAUDIT_FUNCNAME "log_audit_event"
#define PGAUDIT_PREFIX   "AUDIT: "

/* AUDIT_TYPE values, indexed by PgStatLogAuditType */
static const char *const pg_stat_log_audit_types[] = {
    NULL,
    "SESSION",
    "OBJECT",
};

/* The CLASS_* names of pgaudit.c, indexed by PgStatLogAuditClass */
static const char *const pg_stat_log_audit_classes[] = {
    NULL,
    "READ",
    "WRITE",
    "FUNCTION",
    "ROLE",
    "DDL",
    "MISC",
};

StaticAssertDecl(lengthof(pg_stat_log_audit_types) == PGSTAT_LOG_AUDIT_NUM_TYPES,
                 "pg_stat_log_audit_types must match PgStatLogAuditType");
StaticAssertDecl(lengthof(pg_stat_log_audit_classes) == PGSTAT_LOG_AUDIT_NUM_CLASSES,
                 "pg_stat_log_audit_classes must match PgStatLogAuditClass");

/* Number of CommandTag values, which cmdtag.h does not define */
#define PG_CMDTAG(tag, name, evtrgok, rwrok, rowcnt) +1
enum
{
    PGSTAT_LOG_AUDIT_NUM_COMMAND_TAGS = 0
#include "tcop/cmdtaglist.h"
};
#undef PG_CMDTAG

#define PGSTAT_LOG_AUDIT_DATA_COLS 10
#define PGSTAT_LOG_AUDIT_INFO_COLS 5

/*
 * Data structures
 */
typedef struct PgStatLogAuditSlot
{
    int32                next; /* next slot index in bucket chain, or -1 */
    BackendType          backend_type;
    Oid                  dboid;
    Oid                  userid;  /* login role, as log_line_prefix's %u */
    int64                queryid; /* 0 if not tracked */
    PgStatLogAuditRecord record;
    pg_atomic_uint64     count;
} PgStatLogAuditSlot;

/*
 * Stats data block, laid out like PgStatLog:
 *
 *   PgStatLogAuditSlot entries[max_entries]   insertion-ordered slots
 *   int32              heads[max_entries]     bucket chain heads (-1 = empty)
 */
typedef struct PgStatLogAudit
{
    int  max_entries;
    int  num_entries;
    char data[FLEXIBLE_ARRAY_MEMBER];
} PgStatLogAudit;

/*
 * Shared memory wrapper. n_folded counts object-level records counted in
 * their command-level row because the table was full, n_dropped records
 * that could not be counted at all.
 */
typedef struct PgStatLogAuditShared
{
    LWLock           lock;
    TimestampTz      stat_reset_timestamp;
    pg_atomic_uint64 n_folded;
    pg_atomic_uint64 n_dropped;
    char             data[FLEXIBLE_ARRAY_MEMBER];
} PgStatLogAuditShared;

/* pg_atomic_uint64 must be 8-byte aligned, in shared memory and snapshots */
StaticAssertDecl(offsetof(PgStatLogAuditShared, data) % 8 == 0 &&
                     offsetof(PgStatLogAudit, data) % 8 == 0 && sizeof(PgStatLogAuditSlot) % 8 == 0,
                 "the slots of pg_stat_log_audit must be 8-byte aligned");

/*
 * Computed sizes (set in pg_stat_log_audit_register based on
 * pg_stat_log.audit_max_entries)
 */
static Size audit_block_size;

static PgStat_KindInfo audit_stats_kind;

/*
 * Accessor helpers
 */
static inline PgStatLogAuditShared *
pg_stat_log_audit_get_shmem(void)
{
    return (PgStatLogAuditShared *) pgstat_get_custom_shmem_data(PGSTAT_KIND_LOG_AUDIT);
}

static inline PgStatLogAudit *
pg_stat_log_audit_get_stats(PgStatLogAuditShared *shmem)
{
    return (PgStatLogAudit *) shmem->data;
}

static inline PgStatLogAuditSlot *
pg_stat_log_audit_entries(PgStatLogAudit *s)
{
    return (PgStatLogAuditSlot *) s->data;
}

static inline int32 *
pg_stat_log_audit_heads(PgStatLogAudit *s)
{
    return (int32 *) (s->data + sizeof(PgStatLogAuditSlot) * (Size) s->max_entries);
}

/*
 * Hash function for slot lookup — combines all key fields into a uint32
 * used to pick a chain bucket (hash % max_entries).
 */
static inline uint32
pg_stat_log_audit_hash_key(BackendType backend_type, Oid dboid, Oid userid, int64 queryid,
                           const PgStatLogAuditRecord *record)
{
    uint32 h;

    h = murmurhash32((uint32) backend_type);
    h = hash_combine(h, murmurhash32((uint32) dboid));
    h = hash_combine(h, murmurhash32((uint32) userid));
    h = hash_combine(h, (uint32) murmurhash64((uint64) queryid));
    h = hash_combine(h,
                     murmurhash32(((uint32) record->audit_type << 24) |
                                  ((uint32) record->audit_class << 16) | (uint16) record->command));
    h = hash_combine(h,
                     hash_bytes((const unsigned char *) record->object_type,
                                (int) strlen(record->object_type)));
    h = hash_combine(h,
                     hash_bytes((const unsigned char *) record->object_name,
                                (int) strlen(record->object_name)));
    return h;
}

static inline bool
pg_stat_log_audit_slot_matches(const PgStatLogAuditSlot *slot, BackendType backend_type, Oid dboid,
                               Oid userid, int64 queryid, const PgStatLogAuditRecord *record)
{
    return slot->backend_type == backend_type && slot->dboid == dboid && slot->userid == userid &&
           slot->queryid == queryid && slot->record.audit_type == record->audit_type &&
           slot->record.audit_class == record->audit_class &&
           slot->record.command == record->command &&
           strcmp(slot->record.object_type, record->object_type) == 0 &&
           strcmp(slot->record.object_name, record->object_name) == 0;
}

/*
 * Empty the table and its counters. Called with the lock held exclusively.
 *
 * After a stats file fails to load, the header holds whatever was read from
 * the file, so the block is sized from the GUC.
 */
static void
pg_stat_log_audit_clear(PgStatLogAuditShared *shmem, TimestampTz ts)
{
    PgStatLogAudit *s = pg_stat_log_audit_get_stats(shmem);

    s->max_entries = pg_stat_log_audit_max;
    s->num_entries = 0;
    memset(pg_stat_log_audit_heads(s), 0xFF, sizeof(int32) * (Size) s->max_entries);

    shmem->stat_reset_timestamp = ts;
    pg_atomic_write_u64(&shmem->n_folded, 0);
    pg_atomic_write_u64(&shmem->n_dropped, 0);
}

/*
 * init_backend_cb — per-backend initialization
 *
 * As for pg_stat_log's own block, a changed pg_stat_log.audit_max_entries
 * changes the length of the persisted block, so PostgreSQL discards the
 * stats file and calls reset_all_cb. This check is a safety net against a
 * restored block with a stale layout.
 */
static void
pg_stat_log_audit_init_backend_cb(void)
{
    PgStatLogAuditShared *shmem = pg_stat_log_audit_get_shmem();
    PgStatLogAudit       *s     = pg_stat_log_audit_get_stats(shmem);

    if (s->max_entries != pg_stat_log_audit_max)
    {
        elog(LOG,
             "pg_stat_log: discarding persisted audit stats "
             "(audit_max_entries changed from %d to %d)",
             s->max_entries,
             pg_stat_log_audit_max);

        LWLockAcquire(&shmem->lock, LW_EXCLUSIVE);
        pg_stat_log_audit_clear(shmem, GetCurrentTimestamp());
        LWLockRelease(&shmem->lock);
    }
}

/*
 * init_shmem_cb — initialize shared memory; see pg_stat_log_init_shmem_cb()
 */
static void
pg_stat_log_audit_init_shmem_cb(void *stats)
{
    PgStatLogAuditShared *shmem = (PgStatLogAuditShared *) stats;
    PgStatLogAudit       *s;

#if PG_VERSION_NUM < 190000
    LWLockInitialize(&shmem->lock, LWLockNewTrancheId());
#else
    LWLockInitialize(&shmem->lock, LWLockNewTrancheId(PGSTAT_LOG_AUDIT_NAME));
#endif
    shmem->stat_reset_timestamp = GetCurrentTimestamp();
    pg_atomic_init_u64(&shmem->n_folded, 0);
    pg_atomic_init_u64(&shmem->n_dropped, 0);

    s              = pg_stat_log_audit_get_stats(shmem);
    s->max_entries = pg_stat_log_audit_max;
    s->num_entries = 0;
    memset(pg_stat_log_audit_heads(s), 0xFF, sizeof(int32) * (Size) s->max_entries);
}

/*
 * reset_all_cb — reset statistics, reclaiming all slots
 */
static void
pg_stat_log_audit_reset_all_cb(TimestampTz ts)
{
    PgStatLogAuditShared *shmem = pg_stat_log_audit_get_shmem();

    LWLockAcquire(&shmem->lock, LW_EXCLUSIVE);
    pg_stat_log_audit_clear(shmem, ts);
    LWLockRelease(&shmem->lock);
}

/*
 * snapshot_cb — build snapshot for reads
 *
 * The lock is held exclusively so that no count changes during the copy.
 */
static void
pg_stat_log_audit_snapshot_cb(void)
{
    PgStatLogAuditShared *shmem = pg_stat_log_audit_get_shmem();
    PgStatLogAudit       *snap;

    snap = (PgStatLogAudit *) pgstat_get_custom_snapshot_data(PGSTAT_KIND_LOG_AUDIT);

    LWLockAcquire(&shmem->lock, LW_EXCLUSIVE);
    memcpy(snap, pg_stat_log_audit_get_stats(shmem), audit_block_size);
    LWLockRelease(&shmem->lock);
}

/*
 * pg_stat_log_audit_register — register the audit stats kind
 *
 * Called from _PG_init whatever pg_stat_log.track_audit is: a stats file
 * holding a kind that is no longer registered is discarded as a whole.
 */
void
pg_stat_log_audit_register(void)
{
    Size shared_size;

    audit_block_size = offsetof(PgStatLogAudit, data) +
                       sizeof(PgStatLogAuditSlot) * (Size) pg_stat_log_audit_max +
                       sizeof(int32) * (Size) pg_stat_log_audit_max;

    shared_size = offsetof(PgStatLogAuditShared, data) + audit_block_size;

    /* Fill in the KindInfo struct — use memcpy because .name is const */
    {
        PgStat_KindInfo tmp = {
            .name            = PGSTAT_LOG_AUDIT_NAME,
            .fixed_amount    = true,
            .write_to_file   = true,
            .shared_size     = shared_size,
            .shared_data_off = offsetof(PgStatLogAuditShared, data),
            .shared_data_len = audit_block_size,
            .init_backend_cb = pg_stat_log_audit_init_backend_cb,
            .init_shmem_cb   = pg_stat_log_audit_init_shmem_cb,
            .reset_all_cb    = pg_stat_log_audit_reset_all_cb,
            .snapshot_cb     = pg_stat_log_audit_snapshot_cb,
        };

        memcpy(&audit_stats_kind, &tmp, sizeof(PgStat_KindInfo));
    }

    pgstat_register_kind(PGSTAT_KIND_LOG_AUDIT, &audit_stats_kind);
}

/*
 * pg_stat_log_audit_shmem_startup — register the tranche name in every
 * process; see pg_stat_log_shmem_startup()
 */
void
pg_stat_log_audit_shmem_startup(void)
{
#if PG_VERSION_NUM < 190000
    PgStatLogAuditShared *shmem = pg_stat_log_audit_get_shmem();

    LWLockRegisterTranche(shmem->lock.tranche, PGSTAT_LOG_AUDIT_NAME);
#endif
}

/*
 * Read the CSV field at *pos into buf and advance *pos to the next field, or
 * to NULL after the last one. Returns false when no field is left.
 *
 * pgaudit quotes a field only when it contains a comma, a double quote, CR
 * or LF, doubling embedded double quotes. A value longer than bufsize - 1
 * bytes is clipped at a character boundary.
 */
static bool
pg_stat_log_audit_read_field(const char **pos, char *buf, int bufsize)
{
    const char *p       = *pos;
    int         len     = 0;
    bool        clipped = false;

    buf[0] = '\0';
    if (p == NULL)
        return false;

    if (*p == '"')
    {
        p++;
        while (*p != '\0')
        {
            if (*p == '"')
            {
                p++;
                if (*p != '"')
                    break; /* closing quote */
            }
            if (len < bufsize - 1)
                buf[len++] = *p;
            else
                clipped = true;
            p++;
        }
    }
    else
    {
        for (; *p != '\0' && *p != ','; p++)
        {
            if (len < bufsize - 1)
                buf[len++] = *p;
            else
                clipped = true;
        }
    }
    buf[len] = '\0';

    if (clipped)
    {
        int cliplen = pg_mbcliplen(buf, len, len);

        memset(buf + cliplen, 0, len - cliplen);
    }

    *pos = (*p == ',') ? p + 1 : NULL;
    return true;
}

/* Index of name in names, or 0 (unparsed) if it is not there */
static uint8
pg_stat_log_audit_lookup(const char *name, const char *const *names, int nnames)
{
    for (int i = 1; i < nnames; i++)
    {
        if (strcmp(name, names[i]) == 0)
            return (uint8) i;
    }
    return 0;
}

/*
 * pg_stat_log_audit_parse — recognize and read a pgaudit record
 *
 * Returns false for any other message. Must run before the previous
 * emit_log_hook: pgauditlogtofile splits the message in place, after which
 * only AUDIT_TYPE can be read. The object fields are read only when
 * with_object is set.
 */
bool
pg_stat_log_audit_parse(const ErrorData *edata, bool with_object, PgStatLogAuditRecord *record)
{
    const char *pos;
    char        field[NAMEDATALEN];

    /* elog.c has already reduced edata->filename to its base name */
    if (edata->funcname == NULL || edata->filename == NULL || edata->message == NULL ||
        strcmp(edata->funcname, PGAUDIT_FUNCNAME) != 0 ||
        strcmp(edata->filename, PGAUDIT_FILENAME) != 0 ||
        strncmp(edata->message, PGAUDIT_PREFIX, strlen(PGAUDIT_PREFIX)) != 0)
        return false;

    memset(record, 0, sizeof(PgStatLogAuditRecord));
    record->command = -1;

    pos = edata->message + strlen(PGAUDIT_PREFIX);

    if (pg_stat_log_audit_read_field(&pos, field, sizeof(field)))
        record->audit_type =
            pg_stat_log_audit_lookup(field, pg_stat_log_audit_types, PGSTAT_LOG_AUDIT_NUM_TYPES);

    /* STATEMENT_ID and SUBSTATEMENT_ID */
    pg_stat_log_audit_read_field(&pos, field, sizeof(field));
    pg_stat_log_audit_read_field(&pos, field, sizeof(field));

    if (pg_stat_log_audit_read_field(&pos, field, sizeof(field)))
        record->audit_class = pg_stat_log_audit_lookup(field,
                                                       pg_stat_log_audit_classes,
                                                       PGSTAT_LOG_AUDIT_NUM_CLASSES);

    /* An unknown command tag becomes CMDTAG_UNKNOWN, which pgaudit prints as ??? */
    if (pg_stat_log_audit_read_field(&pos, field, sizeof(field)))
        record->command = (int16) GetCommandTagEnum(field);

    if (with_object)
    {
        pg_stat_log_audit_read_field(&pos, record->object_type, sizeof(record->object_type));
        pg_stat_log_audit_read_field(&pos, record->object_name, sizeof(record->object_name));
    }

    return true;
}

/* The slot of a key, or NULL. Called with the lock held. */
static PgStatLogAuditSlot *
pg_stat_log_audit_find(PgStatLogAudit *s, uint32 hash, BackendType backend_type, Oid dboid,
                       Oid userid, int64 queryid, const PgStatLogAuditRecord *record)
{
    PgStatLogAuditSlot *entries = pg_stat_log_audit_entries(s);
    int32              *heads   = pg_stat_log_audit_heads(s);

    for (int32 idx = heads[hash % s->max_entries]; idx != -1; idx = entries[idx].next)
    {
        PgStatLogAuditSlot *slot = &entries[idx];

        if (pg_stat_log_audit_slot_matches(slot, backend_type, dboid, userid, queryid, record))
            return slot;
    }
    return NULL;
}

/*
 * Count one record in the slot of its key. If the key has none and the
 * table is full, count an object-level record in its command-level slot
 * instead, if that exists, or else drop the record. Returns false if the key
 * has no slot and one can still be added. Called with the lock held, in
 * shared mode or exclusively.
 */
static bool
pg_stat_log_audit_count_existing(PgStatLogAuditShared *shmem, uint32 hash, BackendType backend_type,
                                 Oid dboid, Oid userid, int64 queryid,
                                 const PgStatLogAuditRecord *record)
{
    PgStatLogAudit     *s = pg_stat_log_audit_get_stats(shmem);
    PgStatLogAuditSlot *slot;

    slot = pg_stat_log_audit_find(s, hash, backend_type, dboid, userid, queryid, record);
    if (slot != NULL)
    {
        pg_atomic_fetch_add_u64(&slot->count, 1);
        return true;
    }

    if (s->num_entries < s->max_entries)
        return false;

    if (record->object_type[0] != '\0' || record->object_name[0] != '\0')
    {
        PgStatLogAuditRecord command_record = *record;
        uint32               command_hash;

        memset(command_record.object_type, 0, sizeof(command_record.object_type));
        memset(command_record.object_name, 0, sizeof(command_record.object_name));

        command_hash =
            pg_stat_log_audit_hash_key(backend_type, dboid, userid, queryid, &command_record);
        slot = pg_stat_log_audit_find(s,
                                      command_hash,
                                      backend_type,
                                      dboid,
                                      userid,
                                      queryid,
                                      &command_record);
        if (slot != NULL)
        {
            pg_atomic_fetch_add_u64(&slot->count, 1);
            pg_atomic_fetch_add_u64(&shmem->n_folded, 1);
            return true;
        }
    }

    pg_atomic_fetch_add_u64(&shmem->n_dropped, 1);
    return true;
}

/* Add a slot for a key, counting one record. Called with the lock held exclusively. */
static void
pg_stat_log_audit_add(PgStatLogAudit *s, uint32 hash, BackendType backend_type, Oid dboid,
                      Oid userid, int64 queryid, const PgStatLogAuditRecord *record)
{
    int32              *heads  = pg_stat_log_audit_heads(s);
    uint32              bucket = hash % s->max_entries;
    PgStatLogAuditSlot *slot   = &pg_stat_log_audit_entries(s)[s->num_entries];

    Assert(s->num_entries < s->max_entries);

    slot->backend_type = backend_type;
    slot->dboid        = dboid;
    slot->userid       = userid;
    slot->queryid      = queryid;
    slot->record       = *record;
    pg_atomic_init_u64(&slot->count, 1);
    slot->next    = heads[bucket];
    heads[bucket] = s->num_entries;
    s->num_entries++;
}

/*
 * pg_stat_log_audit_count — record one pgaudit record in shared memory
 *
 * When the table is full, a record with a new object-level key is counted
 * in its command-level row instead, if that row exists, so that new
 * activity stays visible; only records that fit neither are dropped.
 */
void
pg_stat_log_audit_count(const PgStatLogAuditRecord *record, BackendType backend_type, Oid dboid,
                        Oid userid, int64 queryid)
{
    PgStatLogAuditShared *shmem = pg_stat_log_audit_get_shmem();
    uint32                hash;
    bool                  counted;

    hash = pg_stat_log_audit_hash_key(backend_type, dboid, userid, queryid, record);

    LWLockAcquire(&shmem->lock, LW_SHARED);
    counted =
        pg_stat_log_audit_count_existing(shmem, hash, backend_type, dboid, userid, queryid, record);
    LWLockRelease(&shmem->lock);

    if (counted)
        return;

    /* Another backend may have added the slot or filled the table meanwhile */
    LWLockAcquire(&shmem->lock, LW_EXCLUSIVE);
    counted =
        pg_stat_log_audit_count_existing(shmem, hash, backend_type, dboid, userid, queryid, record);
    if (!counted)
        pg_stat_log_audit_add(pg_stat_log_audit_get_stats(shmem),
                              hash,
                              backend_type,
                              dboid,
                              userid,
                              queryid,
                              record);
    LWLockRelease(&shmem->lock);
}

/*
 * SQL-callable functions
 */
PG_FUNCTION_INFO_V1(pg_stat_log_audit_data);

/*
 * pg_stat_log_audit_data()
 *		Return all tracked pgaudit record statistics as a set of rows.
 */
Datum
pg_stat_log_audit_data(PG_FUNCTION_ARGS)
{
    ReturnSetInfo      *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    PgStatLogAudit     *snap;
    PgStatLogAuditSlot *entries;

    pgstat_snapshot_fixed(PGSTAT_KIND_LOG_AUDIT);
    snap = (PgStatLogAudit *) pgstat_get_custom_snapshot_data(PGSTAT_KIND_LOG_AUDIT);

    InitMaterializedSRF(fcinfo, 0);

    if (rsinfo->setDesc->natts != PGSTAT_LOG_AUDIT_DATA_COLS)
        elog(ERROR, "incorrect number of output arguments");

    entries = pg_stat_log_audit_entries(snap);

    for (int i = 0; i < snap->num_entries; i++)
    {
        Datum                       values[PGSTAT_LOG_AUDIT_DATA_COLS];
        bool                        nulls[PGSTAT_LOG_AUDIT_DATA_COLS] = {0};
        int                         col                               = 0;
        PgStatLogAuditSlot         *slot                              = &entries[i];
        const PgStatLogAuditRecord *record                            = &slot->record;

        if (pg_atomic_read_u64(&slot->count) == 0)
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

        if (slot->queryid != 0)
            values[col] = Int64GetDatum(slot->queryid);
        else
            nulls[col] = true;
        col++;

        if (record->audit_type > 0 && record->audit_type < PGSTAT_LOG_AUDIT_NUM_TYPES)
            values[col] = CStringGetTextDatum(pg_stat_log_audit_types[record->audit_type]);
        else
            nulls[col] = true;
        col++;

        if (record->audit_class > 0 && record->audit_class < PGSTAT_LOG_AUDIT_NUM_CLASSES)
            values[col] = CStringGetTextDatum(pg_stat_log_audit_classes[record->audit_class]);
        else
            nulls[col] = true;
        col++;

        if (record->command >= 0 && record->command < PGSTAT_LOG_AUDIT_NUM_COMMAND_TAGS)
            values[col] = CStringGetTextDatum(GetCommandTagName((CommandTag) record->command));
        else
            nulls[col] = true;
        col++;

        if (record->object_type[0] != '\0')
            values[col] = CStringGetTextDatum(record->object_type);
        else
            nulls[col] = true;
        col++;

        if (record->object_name[0] != '\0')
            values[col] = CStringGetTextDatum(record->object_name);
        else
            nulls[col] = true;
        col++;

        values[col++] = Int64GetDatum((int64) pg_atomic_read_u64(&slot->count));

        Assert(col == PGSTAT_LOG_AUDIT_DATA_COLS);
        tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
    }

    return (Datum) 0;
}

PG_FUNCTION_INFO_V1(pg_stat_log_audit_reset);

/*
 * pg_stat_log_audit_reset()
 *		Reset all tracked pgaudit record statistics.
 */
Datum
pg_stat_log_audit_reset(PG_FUNCTION_ARGS)
{
    pgstat_reset_of_kind(PGSTAT_KIND_LOG_AUDIT);

    PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(pg_stat_log_audit_info);

/*
 * pg_stat_log_audit_info()
 *		Return metadata about the pg_stat_log_audit shared memory area:
 *		max_entries capacity, current num_entries, the number of records
 *		folded into command-level rows or dropped for lack of capacity, and
 *		the last reset timestamp.
 */
Datum
pg_stat_log_audit_info(PG_FUNCTION_ARGS)
{
    ReturnSetInfo        *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    PgStatLogAuditShared *shmem;
    PgStatLogAudit       *s;
    Datum                 values[PGSTAT_LOG_AUDIT_INFO_COLS];
    bool                  nulls[PGSTAT_LOG_AUDIT_INFO_COLS] = {0};

    InitMaterializedSRF(fcinfo, 0);

    if (rsinfo->setDesc->natts != PGSTAT_LOG_AUDIT_INFO_COLS)
        elog(ERROR, "incorrect number of output arguments");

    shmem = pg_stat_log_audit_get_shmem();
    s     = pg_stat_log_audit_get_stats(shmem);

    LWLockAcquire(&shmem->lock, LW_SHARED);
    values[0] = Int32GetDatum(s->max_entries);
    values[1] = Int32GetDatum(s->num_entries);
    values[2] = Int64GetDatum((int64) pg_atomic_read_u64(&shmem->n_folded));
    values[3] = Int64GetDatum((int64) pg_atomic_read_u64(&shmem->n_dropped));
    values[4] = TimestampTzGetDatum(shmem->stat_reset_timestamp);
    LWLockRelease(&shmem->lock);

    tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);

    return (Datum) 0;
}
