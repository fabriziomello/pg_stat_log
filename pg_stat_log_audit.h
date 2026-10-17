/*--------------------------------------------------------------------------
 *
 * pg_stat_log_audit.h
 *		Cumulative statistics about pgaudit audit records.
 *
 * Copyright (c) 2026, PlanetScale Inc.
 *
 * IDENTIFICATION
 *		pg_stat_log/pg_stat_log_audit.h
 *
 *--------------------------------------------------------------------------
 */
#ifndef PG_STAT_LOG_AUDIT_H
#define PG_STAT_LOG_AUDIT_H

#include "miscadmin.h"
#include "utils/elog.h"

/*
 * Custom stats kind ID — registered at
 * https://wiki.postgresql.org/wiki/CustomCumulativeStats
 */
#define PGSTAT_KIND_LOG_AUDIT 31

#define PGSTAT_LOG_AUDIT_MAX_DEFAULT 1024

/* Values of pg_stat_log.track_audit */
typedef enum PgStatLogTrackAudit
{
    PGSTAT_LOG_TRACK_AUDIT_OFF,
    PGSTAT_LOG_TRACK_AUDIT_COMMAND,
    PGSTAT_LOG_TRACK_AUDIT_OBJECT,
} PgStatLogTrackAudit;

/* AUDIT_TYPE of a record */
typedef enum PgStatLogAuditType
{
    PGSTAT_LOG_AUDIT_TYPE_UNPARSED,
    PGSTAT_LOG_AUDIT_TYPE_SESSION,
    PGSTAT_LOG_AUDIT_TYPE_OBJECT,
    PGSTAT_LOG_AUDIT_NUM_TYPES
} PgStatLogAuditType;

/* CLASS of a record */
typedef enum PgStatLogAuditClass
{
    PGSTAT_LOG_AUDIT_CLASS_UNPARSED,
    PGSTAT_LOG_AUDIT_CLASS_READ,
    PGSTAT_LOG_AUDIT_CLASS_WRITE,
    PGSTAT_LOG_AUDIT_CLASS_FUNCTION,
    PGSTAT_LOG_AUDIT_CLASS_ROLE,
    PGSTAT_LOG_AUDIT_CLASS_DDL,
    PGSTAT_LOG_AUDIT_CLASS_MISC,
    PGSTAT_LOG_AUDIT_NUM_CLASSES
} PgStatLogAuditClass;

#define PGSTAT_LOG_AUDIT_OBJECT_TYPE_LEN 32
#define PGSTAT_LOG_AUDIT_OBJECT_NAME_LEN (2 * NAMEDATALEN)

/*
 * The fields of a pgaudit record that are counted. Fields that could not be
 * read keep their zero value (-1 for command); the object fields are empty
 * unless pg_stat_log.track_audit is object. Unused bytes are zero.
 */
typedef struct PgStatLogAuditRecord
{
    uint8 audit_type;                                    /* PgStatLogAuditType */
    uint8 audit_class;                                   /* PgStatLogAuditClass */
    int16 command;                                       /* CommandTag, or -1 */
    char  object_type[PGSTAT_LOG_AUDIT_OBJECT_TYPE_LEN]; /* "" if none */
    char  object_name[PGSTAT_LOG_AUDIT_OBJECT_NAME_LEN]; /* "" if none */
} PgStatLogAuditRecord;

extern int pg_stat_log_audit_max;

extern void pg_stat_log_audit_register(void);
extern void pg_stat_log_audit_shmem_startup(void);
extern bool pg_stat_log_audit_parse(const ErrorData *edata, bool with_object,
                                    PgStatLogAuditRecord *record);
extern void pg_stat_log_audit_count(const PgStatLogAuditRecord *record, BackendType backend_type,
                                    Oid dboid, Oid userid, int64 queryid);

#endif /* PG_STAT_LOG_AUDIT_H */
