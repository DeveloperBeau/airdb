/* Compiles against include/airdb.h and links libairdb.a: proves the C ABI is
 * callable from C end to end. Returns non-zero on any failure. */
#include "airdb.h"
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

#define CHECK(cond)                                                            \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "FAIL: %s (line %d)\n", #cond, __LINE__);          \
            return 1;                                                          \
        }                                                                      \
    } while (0)

int main(void) {
    /* The storage layer requires an absolute path. */
    const char *path = "/tmp/airdb_ffi_smoke_test.airdb";
    remove(path);
    remove("/tmp/airdb_ffi_smoke_test.airdb.coord");

    AirdbDatabase *db = airdb_open(path, 3);
    CHECK(db != NULL);
    CHECK(airdb_prop_count(db) == 3);

    uint64_t a[3] = {100, 7, 1};
    uint64_t b[3] = {200, 8, 0};
    CHECK(airdb_insert(db, a, 3) >= 0);
    CHECK(airdb_insert(db, b, 3) >= 0);
    CHECK(airdb_count(db) == 2);
    CHECK(airdb_insert(db, a, 3) == AIRDB_E_DUPLICATE);

    uint64_t out[3] = {0, 0, 0};
    CHECK(airdb_get(db, 200, out, 3) >= 1);
    CHECK(out[0] == 200 && out[1] == 8);
    CHECK(airdb_get(db, 999, out, 3) == AIRDB_E_NOT_FOUND);

    uint64_t upd[3] = {200, 88, 0};
    CHECK(airdb_update(db, upd, 3) == AIRDB_OK);
    CHECK(airdb_get(db, 200, out, 3) >= 1);
    CHECK(out[1] == 88);

    CHECK(airdb_delete(db, 100) == AIRDB_OK);
    CHECK(airdb_count(db) == 1);

    airdb_close(db);

    /* Reopen and confirm persistence. */
    AirdbDatabase *db2 = airdb_open(path, 3);
    CHECK(db2 != NULL);
    CHECK(airdb_count(db2) == 1);
    CHECK(airdb_get(db2, 200, out, 3) >= 1);
    CHECK(out[1] == 88);
    airdb_close(db2);

    remove(path);
    remove("/tmp/airdb_ffi_smoke_test.airdb.coord");
    printf("ffi_smoke: ok\n");
    return 0;
}
