/*
 * airdb C ABI.
 *
 * A thin interface over a single int-property object type. The airdb_*
 * functions below are auto-commit (each call is its own durable transaction);
 * the airdb_txn_* family batches multiple operations into one durable commit.
 * Functions returning int64_t use a non-negative value on success and a
 * negative AIRDB_E_* code on failure; handle-returning functions return NULL
 * on failure.
 *
 * Blob/link values and queries over this boundary are not yet exposed.
 */
#ifndef AIRDB_H
#define AIRDB_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AirdbDatabase AirdbDatabase;
typedef struct AirdbTxn AirdbTxn;

#define AIRDB_OK              0
#define AIRDB_E_GENERIC      (-1)
#define AIRDB_E_NOT_FOUND    (-2)
#define AIRDB_E_BAD_ARGS     (-3)
#define AIRDB_E_CONFLICT     (-4)
#define AIRDB_E_DUPLICATE    (-5)
#define AIRDB_E_NOT_EMPTY    (-6)
#define AIRDB_E_UNSUPPORTED  (-7)
/* A commit-point flush failed: the commit's on-disk fate is indeterminate and
 * this handle refuses further writes. Close and reopen to resolve. */
#define AIRDB_E_INDETERMINATE (-8)

/* Open (creating if absent with `propertyCount` int properties, property 0 is the
 * primary key). `path` must be absolute. Returns NULL on failure (including a
 * non-absolute path). */
AirdbDatabase *airdb_open(const char *path, uint16_t propertyCount);

/* Close and free the handle. Safe with NULL. */
void airdb_close(AirdbDatabase *database);

/* Property count of the object type, or a negative error code. */
int64_t airdb_prop_count(AirdbDatabase *database);

/* Insert `length` u64 values (must equal propertyCount; vals[0] is the primary key).
 * Returns the new object key, or a negative error code. */
int64_t airdb_insert(AirdbDatabase *database, const uint64_t *vals, size_t length);

/* Read the row with primary key `primaryKey` into `out` (length must equal propertyCount).
 * Returns the row version (>= 1), or AIRDB_E_NOT_FOUND. */
int64_t airdb_get(AirdbDatabase *database, uint64_t primaryKey, uint64_t *out, size_t length);

/* Number of live rows, or a negative error code. */
int64_t airdb_count(AirdbDatabase *database);

/* Update the row whose primary key is vals[0] (length must equal propertyCount).
 * Returns AIRDB_OK or a negative error code. */
int64_t airdb_update(AirdbDatabase *database, const uint64_t *vals, size_t length);

/* Delete the row with primary key `primaryKey`. Returns AIRDB_OK or an error code. */
int64_t airdb_delete(AirdbDatabase *database, uint64_t primaryKey);

/* Bulk-load `row_count` rows of `propertyCount` values each from the flat,
 * row-major buffer (row i occupies rows_flat[i*propertyCount..]; element 0 of
 * each row is the primary key) into an EMPTY type in one durable commit. The
 * whole import succeeds atomically or nothing becomes durable. Returns the
 * number of rows loaded, or: AIRDB_E_NOT_EMPTY if the type already holds rows,
 * AIRDB_E_DUPLICATE on a repeated primary key, AIRDB_E_UNSUPPORTED for a type
 * bulk import cannot build, AIRDB_E_BAD_ARGS on a propertyCount mismatch. */
int64_t airdb_bulk_insert(AirdbDatabase *database, const uint64_t *rows_flat,
                          size_t row_count, size_t propertyCount);

/* Append `row_count` rows (same flat layout as airdb_bulk_insert) to a
 * populated type in one durable commit. Strictly-ascending primary keys above
 * the current maximum take a right-edge fast path; any other shape falls back
 * to row-by-row insert. Returns the number of rows appended, or
 * AIRDB_E_DUPLICATE / AIRDB_E_BAD_ARGS / AIRDB_E_GENERIC. A row_count of 0 is
 * a no-op returning 0. */
int64_t airdb_bulk_append(AirdbDatabase *database, const uint64_t *rows_flat,
                          size_t row_count, size_t propertyCount);

/* Begin an explicit write transaction. Acquires the database write lock.
 * Returns NULL on failure. The handle must be passed to exactly one of
 * airdb_commit / airdb_abort; using it after either is undefined behavior. */
AirdbTxn *airdb_begin(AirdbDatabase *database);

/* Abort: release the write lock without making anything durable, free the
 * handle. Safe with NULL. */
void airdb_abort(AirdbTxn *transaction);

/* Commit: make every staged operation durable in a single barrier, release
 * the write lock, free the handle. Returns AIRDB_OK or AIRDB_E_GENERIC. */
int64_t airdb_commit(AirdbTxn *transaction);

/* Stage an insert in the open transaction (no commit). Returns the new object
 * key, or a negative error code. On error the transaction stays open and the
 * staged batch is unchanged. */
int64_t airdb_txn_insert(AirdbTxn *transaction, const uint64_t *vals, size_t length);

/* Stage an update (vals[0] is the primary key). Returns AIRDB_OK or an error
 * code; on error the transaction stays open and the batch is unchanged. */
int64_t airdb_txn_update(AirdbTxn *transaction, const uint64_t *vals, size_t length);

/* Stage a delete of the row with primary key `primaryKey`. Returns AIRDB_OK or an
 * error code; on error the transaction stays open and the batch is
 * unchanged. */
int64_t airdb_txn_delete(AirdbTxn *transaction, uint64_t primaryKey);

#ifdef __cplusplus
}
#endif

#endif /* AIRDB_H */
