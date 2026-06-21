/*
 * airdb C ABI.
 *
 * A thin auto-commit interface over a single int-property object type. Each
 * call is its own transaction. Functions returning int64_t use a non-negative
 * value on success and a negative AIRDB_E_* code on failure; handle-returning
 * functions return NULL on failure.
 *
 * Blob/link values, explicit multi-op transactions, and queries over this
 * boundary are not yet exposed.
 */
#ifndef AIRDB_H
#define AIRDB_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AirdbDatabase AirdbDatabase;

#define AIRDB_OK            0
#define AIRDB_E_GENERIC    (-1)
#define AIRDB_E_NOT_FOUND  (-2)
#define AIRDB_E_BAD_ARGS   (-3)
#define AIRDB_E_CONFLICT   (-4)
#define AIRDB_E_DUPLICATE  (-5)

/* Open (creating if absent with `prop_count` int properties, property 0 is the
 * primary key). `path` must be absolute. Returns NULL on failure (including a
 * non-absolute path). */
AirdbDatabase *airdb_open(const char *path, uint16_t prop_count);

/* Close and free the handle. Safe with NULL. */
void airdb_close(AirdbDatabase *db);

/* Property count of the object type, or a negative error code. */
int64_t airdb_prop_count(AirdbDatabase *db);

/* Insert `len` u64 values (must equal prop_count; vals[0] is the primary key).
 * Returns the new object key, or a negative error code. */
int64_t airdb_insert(AirdbDatabase *db, const uint64_t *vals, size_t len);

/* Read the row with primary key `pk` into `out` (len must equal prop_count).
 * Returns the row version (>= 1), or AIRDB_E_NOT_FOUND. */
int64_t airdb_get(AirdbDatabase *db, uint64_t pk, uint64_t *out, size_t len);

/* Number of live rows, or a negative error code. */
int64_t airdb_count(AirdbDatabase *db);

/* Update the row whose primary key is vals[0] (len must equal prop_count).
 * Returns AIRDB_OK or a negative error code. */
int64_t airdb_update(AirdbDatabase *db, const uint64_t *vals, size_t len);

/* Delete the row with primary key `pk`. Returns AIRDB_OK or an error code. */
int64_t airdb_delete(AirdbDatabase *db, uint64_t pk);

#ifdef __cplusplus
}
#endif

#endif /* AIRDB_H */
