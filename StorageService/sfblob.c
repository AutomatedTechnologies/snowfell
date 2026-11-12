// sfblob.c — blob layer implementation (design §13.2/§13.3/§13.6).
// SQL lives here (not in sfstore.c) because the frozen sfstore.h has
// no blob surface; the store handle is reached via sf_store_db().
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include "sfblob.h"
#include "sfsha256.h"

#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static sqlite3 *db_of(sf_store *s) { return sf_store_db(s); }

static void set_str(char *dst, size_t cap, const char *src) {
    size_t n;
    if (!dst || cap == 0) return;
    if (!src) src = "";
    n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static const char *col_text(sqlite3_stmt *st, int i) {
    const unsigned char *t = sqlite3_column_text(st, i);
    return t ? (const char *)t : "";
}

static sf_result map_rc(int rc) {
    if (rc == SQLITE_CONSTRAINT) return SF_ERR_CONFLICT;
    if (rc == SQLITE_NOMEM) return SF_ERR_NOMEM;
    return SF_ERR_DB;
}

static sf_result exec_sql(sf_store *s, const char *sql) {
    char *err = NULL;
    int rc = sqlite3_exec(db_of(s), sql, NULL, NULL, &err);
    if (err) sqlite3_free(err);
    return rc == SQLITE_OK ? SF_OK : map_rc(rc);
}

static sf_result step_done(sf_store *s, sqlite3_stmt *st, int *changes) {
    int rc = sqlite3_step(st);
    sf_result r;
    if (rc == SQLITE_DONE) {
        if (changes) *changes = sqlite3_changes(db_of(s));
        r = SF_OK;
    } else {
        r = map_rc(rc);
    }
    sqlite3_finalize(st);
    return r;
}

#define BLOB_COLS "id, tenant_id, sha256, size_bytes, backend_id, refcount," \
                  " state, orphaned_at, created_at, last_verified_at"

static void fill_blob(sqlite3_stmt *st, sf_blob *b) {
    const void *raw;
    int blen;
    memset(b, 0, sizeof *b);
    b->id = sqlite3_column_int64(st, 0);
    b->tenant_id = sqlite3_column_int64(st, 1);
    raw = sqlite3_column_blob(st, 2);
    blen = sqlite3_column_bytes(st, 2);
    if (raw && blen == 32) memcpy(b->sha256, raw, 32);
    sf_hex_encode(b->sha256, 32, b->sha256_hex);
    b->size_bytes = sqlite3_column_int64(st, 3);
    b->backend_id = sqlite3_column_int64(st, 4);
    b->refcount = sqlite3_column_int64(st, 5);
    set_str(b->state, sizeof b->state, col_text(st, 6));
    if (sqlite3_column_type(st, 7) != SQLITE_NULL)
        set_str(b->orphaned_at, sizeof b->orphaned_at, col_text(st, 7));
    set_str(b->created_at, sizeof b->created_at, col_text(st, 8));
    if (sqlite3_column_type(st, 9) != SQLITE_NULL)
        set_str(b->last_verified_at, sizeof b->last_verified_at, col_text(st, 9));
}

static sf_result get_blob_where(sf_store *s, const char *where,
                                int64_t tenant_id, int64_t id_key,
                                const uint8_t *sha_key, sf_blob *out) {
    sqlite3_stmt *st = NULL;
    char sql[512];
    sf_result r = SF_ERR_NOT_FOUND;
    snprintf(sql, sizeof sql, "SELECT " BLOB_COLS " FROM cs_blobs WHERE %s", where);
    if (sqlite3_prepare_v2(db_of(s), sql, -1, &st, NULL) != SQLITE_OK)
        return SF_ERR_DB;
    if (sha_key) {
        sqlite3_bind_blob(st, 1, sha_key, 32, SQLITE_TRANSIENT);
        if (tenant_id >= 0) sqlite3_bind_int64(st, 2, tenant_id);
    } else {
        sqlite3_bind_int64(st, 1, id_key);
        if (tenant_id >= 0) sqlite3_bind_int64(st, 2, tenant_id);
    }
    if (sqlite3_step(st) == SQLITE_ROW) { fill_blob(st, out); r = SF_OK; }
    sqlite3_finalize(st);
    return r;
}

sf_result sf_blob_get_by_id(sf_store *s, int64_t tenant_id, int64_t blob_id,
                            sf_blob *out) {
    if (!s || !out) return SF_ERR_VALIDATION;
    if (tenant_id >= 0)
        return get_blob_where(s, "id = ? AND tenant_id = ?", tenant_id, blob_id,
                              NULL, out);
    return get_blob_where(s, "id = ?", -1, blob_id, NULL, out);
}

sf_result sf_blob_get_by_digest(sf_store *s, int64_t tenant_id,
                                const uint8_t sha256[32], sf_blob *out) {
    if (!s || !sha256 || !out || tenant_id < 0) return SF_ERR_VALIDATION;
    return get_blob_where(s, "sha256 = ? AND tenant_id = ?", tenant_id, 0,
                          sha256, out);
}

sf_result sf_blob_list(sf_store *s, int64_t tenant_id,
                       sf_blob **out_rows, size_t *out_count) {
    sqlite3_stmt *st = NULL;
    sf_blob *rows = NULL;
    size_t count = 0, cap = 0;
    int rc;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (tenant_id >= 0) {
        if (sqlite3_prepare_v2(db_of(s),
                "SELECT " BLOB_COLS " FROM cs_blobs WHERE tenant_id = ?"
                " ORDER BY id ASC", -1, &st, NULL) != SQLITE_OK)
            return SF_ERR_DB;
        sqlite3_bind_int64(st, 1, tenant_id);
    } else {
        if (sqlite3_prepare_v2(db_of(s),
                "SELECT " BLOB_COLS " FROM cs_blobs ORDER BY id ASC",
                -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    }
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (count == cap) {
            size_t ncap = cap ? cap * 2 : 16;
            sf_blob *nr = (sf_blob *)realloc(rows, ncap * sizeof *nr);
            if (!nr) { free(rows); sqlite3_finalize(st); return SF_ERR_NOMEM; }
            rows = nr; cap = ncap;
        }
        fill_blob(st, &rows[count]);
        count++;
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) { free(rows); return map_rc(rc); }
    *out_rows = rows;
    *out_count = count;
    return SF_OK;
}

void sf_blob_free_all(sf_blob *rows, size_t count) {
    (void)count;
    free(rows);
}

sf_result sf_blob_object_blob_id(sf_store *s, int64_t object_id, int64_t *out) {
    sqlite3_stmt *st = NULL;
    sf_result r = SF_ERR_NOT_FOUND;
    if (!s || !out) return SF_ERR_VALIDATION;
    *out = -1;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT blob_id FROM cs_objects WHERE id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, object_id);
    if (sqlite3_step(st) == SQLITE_ROW) {
        r = SF_OK;
        if (sqlite3_column_type(st, 0) != SQLITE_NULL)
            *out = sqlite3_column_int64(st, 0);
    }
    sqlite3_finalize(st);
    return r;
}

sf_result sf_blob_reference_buckets(sf_store *s, int64_t tenant_id,
                                    int64_t blob_id, int64_t **out,
                                    size_t *out_count) {
    sqlite3_stmt *st = NULL;
    int64_t *rows = NULL;
    size_t count = 0, cap = 0;
    int rc;
    if (!s || !out || !out_count) return SF_ERR_VALIDATION;
    *out = NULL; *out_count = 0;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT DISTINCT bucket_id FROM cs_objects"
            " WHERE tenant_id = ? AND blob_id = ? ORDER BY bucket_id ASC",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, blob_id);
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (count == cap) {
            size_t ncap = cap ? cap * 2 : 8;
            int64_t *nr = (int64_t *)realloc(rows, ncap * sizeof *nr);
            if (!nr) { free(rows); sqlite3_finalize(st); return SF_ERR_NOMEM; }
            rows = nr; cap = ncap;
        }
        rows[count++] = sqlite3_column_int64(st, 0);
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) { free(rows); return map_rc(rc); }
    *out = rows;
    *out_count = count;
    return SF_OK;
}

// Decrement + orphan-stamp inside the caller's transaction.
static sf_result detach_in_txn(sf_store *s, int64_t tenant_id, int64_t blob_id,
                               int *now_orphan_out) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t rc_count = -1;
    if (now_orphan_out) *now_orphan_out = 0;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_blobs SET refcount = refcount - 1"
            " WHERE tenant_id = ? AND id = ? AND refcount > 0",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, blob_id);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) return r;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT refcount FROM cs_blobs WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, blob_id);
    if (sqlite3_step(st) == SQLITE_ROW) rc_count = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st); st = NULL;
    if (rc_count < 0) return SF_ERR_NOT_FOUND;
    if (rc_count == 0) {
        if (sqlite3_prepare_v2(db_of(s),
                "UPDATE cs_blobs SET orphaned_at = ?"
                " WHERE tenant_id = ? AND id = ? AND orphaned_at IS NULL",
                -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
        sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 2, tenant_id);
        sqlite3_bind_int64(st, 3, blob_id);
        r = step_done(s, st, NULL);
        if (r == SF_OK && now_orphan_out) *now_orphan_out = 1;
        return r;
    }
    return SF_OK;
}

// Get-or-create + refcount++ inside the caller's transaction.
static sf_result attach_in_txn(sf_store *s, int64_t tenant_id,
                               const uint8_t sha256[32], int64_t size_bytes,
                               int64_t backend_id, sf_blob *out, int *hit_out) {
    sf_blob existing;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    if (hit_out) *hit_out = 0;
    r = sf_blob_get_by_digest(s, tenant_id, sha256, &existing);
    if (r == SF_OK) {
        if (hit_out) *hit_out = 1;
        if (sqlite3_prepare_v2(db_of(s),
                "UPDATE cs_blobs SET refcount = refcount + 1,"
                " orphaned_at = NULL WHERE tenant_id = ? AND id = ?",
                -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
        sqlite3_bind_int64(st, 1, tenant_id);
        sqlite3_bind_int64(st, 2, existing.id);
        r = step_done(s, st, NULL); st = NULL;
        if (r != SF_OK) return r;
        if (out) return sf_blob_get_by_id(s, tenant_id, existing.id, out);
        return SF_OK;
    }
    if (r != SF_ERR_NOT_FOUND) return r;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db_of(s),
            "INSERT INTO cs_blobs (tenant_id, sha256, size_bytes, backend_id,"
            " refcount, state, orphaned_at, created_at, last_verified_at)"
            " VALUES (?, ?, ?, ?, 1, 'ok', NULL, ?, NULL)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_blob(st, 2, sha256, 32, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, size_bytes);
    sqlite3_bind_int64(st, 4, backend_id);
    sqlite3_bind_text(st, 5, now, -1, SQLITE_TRANSIENT);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) return r;
    if (out) {
        int64_t id = sqlite3_last_insert_rowid(db_of(s));
        return sf_blob_get_by_id(s, tenant_id, id, out);
    }
    return SF_OK;
}

sf_result sf_blob_create_unreferenced(sf_store *s, int64_t tenant_id,
                                      const uint8_t sha256[32],
                                      int64_t size_bytes, int64_t backend_id,
                                      sf_blob *out, int *created_out) {
    sf_blob existing;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    if (!s || !sha256) return SF_ERR_VALIDATION;
    if (created_out) *created_out = 0;
    r = sf_blob_get_by_digest(s, tenant_id, sha256, &existing);
    if (r == SF_OK) { if (out) *out = existing; return SF_OK; }
    if (r != SF_ERR_NOT_FOUND) return r;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db_of(s),
            "INSERT INTO cs_blobs (tenant_id, sha256, size_bytes, backend_id,"
            " refcount, state, orphaned_at, created_at, last_verified_at)"
            " VALUES (?, ?, ?, ?, 0, 'ok', ?, ?, NULL)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_blob(st, 2, sha256, 32, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, size_bytes);
    sqlite3_bind_int64(st, 4, backend_id);
    sqlite3_bind_text(st, 5, now, -1, SQLITE_TRANSIENT);  // orphaned at creation
    sqlite3_bind_text(st, 6, now, -1, SQLITE_TRANSIENT);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) return r;
    if (created_out) *created_out = 1;
    if (out) {
        int64_t id = sqlite3_last_insert_rowid(db_of(s));
        return sf_blob_get_by_id(s, tenant_id, id, out);
    }
    return SF_OK;
}

sf_result sf_blob_put_object_ref(sf_store *s, int64_t tenant_id,
                                 int64_t bucket_id, const char *key,
                                 int64_t size_bytes, const uint8_t sha256[32],
                                 const char *content_type,
                                 const char *metadata_json,
                                 int64_t backend_id,
                                 sf_object *out, sf_blob *blob_out,
                                 int *hit_out) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int have_bucket = 0;
    int64_t existing_id = -1, existing_size = 0, existing_blob = -1;
    sf_blob blob;
    int hit = 0;

    if (!s || !key || !key[0] || size_bytes < 0 || !sha256)
        return SF_ERR_VALIDATION;
    if (!content_type) content_type = "application/octet-stream";
    if (!metadata_json) metadata_json = "{}";
    if (hit_out) *hit_out = 0;
    sf_now_iso(now);

    r = exec_sql(s, "BEGIN IMMEDIATE");
    if (r != SF_OK) return r;

    if (sqlite3_prepare_v2(db_of(s),
            "SELECT id FROM cs_buckets WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, bucket_id);
    if (sqlite3_step(st) == SQLITE_ROW) have_bucket = 1;
    sqlite3_finalize(st); st = NULL;
    if (!have_bucket) { exec_sql(s, "ROLLBACK"); return SF_ERR_NOT_FOUND; }

    if (sqlite3_prepare_v2(db_of(s),
            "SELECT id, size_bytes, blob_id FROM cs_objects"
            " WHERE tenant_id = ? AND bucket_id = ? AND key = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, bucket_id);
    sqlite3_bind_text(st, 3, key, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) {
        existing_id = sqlite3_column_int64(st, 0);
        existing_size = sqlite3_column_int64(st, 1);
        if (sqlite3_column_type(st, 2) != SQLITE_NULL)
            existing_blob = sqlite3_column_int64(st, 2);
    }
    sqlite3_finalize(st); st = NULL;

    memset(&blob, 0, sizeof blob);
    r = attach_in_txn(s, tenant_id, sha256, size_bytes, backend_id, &blob, &hit);
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    if (hit_out) *hit_out = hit;

    if (existing_id >= 0) {
        if (sqlite3_prepare_v2(db_of(s),
                "UPDATE cs_objects SET size_bytes = ?, sha256 = ?,"
                " content_type = ?, metadata_json = ?, blob_id = ?,"
                " updated_at = ? WHERE id = ?",
                -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
        sqlite3_bind_int64(st, 1, size_bytes);
        sqlite3_bind_blob(st, 2, sha256, 32, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 3, content_type, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 4, metadata_json, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 5, blob.id);
        sqlite3_bind_text(st, 6, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 7, existing_id);
        r = step_done(s, st, NULL); st = NULL;
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
        if (sqlite3_prepare_v2(db_of(s),
                "UPDATE cs_buckets SET total_bytes = total_bytes + ?,"
                " updated_at = ? WHERE tenant_id = ? AND id = ?",
                -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
        sqlite3_bind_int64(st, 1, size_bytes - existing_size);
        sqlite3_bind_text(st, 2, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 3, tenant_id);
        sqlite3_bind_int64(st, 4, bucket_id);
        r = step_done(s, st, NULL); st = NULL;
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    } else {
        if (sqlite3_prepare_v2(db_of(s),
                "INSERT INTO cs_objects (bucket_id, tenant_id, key,"
                " size_bytes, sha256, content_type, metadata_json, blob_id,"
                " created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
        sqlite3_bind_int64(st, 1, bucket_id);
        sqlite3_bind_int64(st, 2, tenant_id);
        sqlite3_bind_text(st, 3, key, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 4, size_bytes);
        sqlite3_bind_blob(st, 5, sha256, 32, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 6, content_type, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 7, metadata_json, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 8, blob.id);
        sqlite3_bind_text(st, 9, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 10, now, -1, SQLITE_TRANSIENT);
        r = step_done(s, st, NULL); st = NULL;
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
        if (sqlite3_prepare_v2(db_of(s),
                "UPDATE cs_buckets SET object_count = object_count + 1,"
                " total_bytes = total_bytes + ?, updated_at = ?"
                " WHERE tenant_id = ? AND id = ?",
                -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
        sqlite3_bind_int64(st, 1, size_bytes);
        sqlite3_bind_text(st, 2, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 3, tenant_id);
        sqlite3_bind_int64(st, 4, bucket_id);
        r = step_done(s, st, NULL); st = NULL;
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    }

    // Detach the replaced blob in the same transaction (skip when the
    // replacement references the very same blob: attach+detach net 0
    // is achieved by doing neither twice — attach already ran, so a
    // same-blob replace must detach the OLD reference exactly once,
    // which is what this does: counts stay correct in both cases).
    if (existing_blob >= 0) {
        r = detach_in_txn(s, tenant_id, existing_blob, NULL);
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    }

    r = exec_sql(s, "COMMIT");
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    if (blob_out) *blob_out = blob;
    if (out) return sf_store_get_object(s, tenant_id, bucket_id, key, out);
    return SF_OK;
}

sf_result sf_blob_delete_object_ref(sf_store *s, int64_t tenant_id,
                                    int64_t bucket_id, const char *key,
                                    int64_t *detached_blob_id_out) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t size = 0, blob_id = -1;
    int found = 0;
    if (!s || !key) return SF_ERR_VALIDATION;
    if (detached_blob_id_out) *detached_blob_id_out = -1;
    sf_now_iso(now);
    r = exec_sql(s, "BEGIN IMMEDIATE");
    if (r != SF_OK) return r;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT size_bytes, blob_id FROM cs_objects"
            " WHERE tenant_id = ? AND bucket_id = ? AND key = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, bucket_id);
    sqlite3_bind_text(st, 3, key, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) {
        found = 1;
        size = sqlite3_column_int64(st, 0);
        if (sqlite3_column_type(st, 1) != SQLITE_NULL)
            blob_id = sqlite3_column_int64(st, 1);
    }
    sqlite3_finalize(st); st = NULL;
    if (!found) { exec_sql(s, "ROLLBACK"); return SF_ERR_NOT_FOUND; }

    if (sqlite3_prepare_v2(db_of(s),
            "DELETE FROM cs_objects WHERE tenant_id = ? AND bucket_id = ? AND key = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, bucket_id);
    sqlite3_bind_text(st, 3, key, -1, SQLITE_TRANSIENT);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }

    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_buckets SET object_count = object_count - 1,"
            " total_bytes = total_bytes - ?, updated_at = ?"
            " WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, size);
    sqlite3_bind_text(st, 2, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, tenant_id);
    sqlite3_bind_int64(st, 4, bucket_id);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }

    if (blob_id >= 0) {
        r = detach_in_txn(s, tenant_id, blob_id, NULL);
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
        if (detached_blob_id_out) *detached_blob_id_out = blob_id;
    }
    return exec_sql(s, "COMMIT");
}

// Increment + un-orphan inside the caller's transaction; the blob
// must exist in scope (changes == 0 is a scoped miss).
static sf_result attach_increment_in_txn(sf_store *s, int64_t tenant_id,
                                         int64_t blob_id) {
    sqlite3_stmt *st = NULL;
    sf_result r;
    int changes = 0;
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_blobs SET refcount = refcount + 1, orphaned_at = NULL"
            " WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, blob_id);
    r = step_done(s, st, &changes);
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

// Scoped existence probe inside the caller's transaction.
static int exists_in_txn(sf_store *s, const char *sql, int64_t tenant_id,
                         int64_t id) {
    sqlite3_stmt *st = NULL;
    int found = 0;
    if (sqlite3_prepare_v2(db_of(s), sql, -1, &st, NULL) != SQLITE_OK)
        return 0;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, id);
    if (sqlite3_step(st) == SQLITE_ROW) found = 1;
    sqlite3_finalize(st);
    return found;
}

sf_result sf_blob_attach_version(sf_store *s, int64_t tenant_id,
                                 int64_t item_id, int64_t blob_id,
                                 const char *note, const char *metadata_json,
                                 const char *created_by,
                                 int64_t *version_id_out,
                                 int64_t *version_no_out) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t next_no = 0, version_id = -1;
    if (!s || tenant_id < 0) return SF_ERR_VALIDATION;
    if (!note) note = "";
    if (!metadata_json) metadata_json = "{}";
    if (!created_by) created_by = "";
    sf_now_iso(now);
    r = exec_sql(s, "BEGIN IMMEDIATE");
    if (r != SF_OK) return r;
    if (!exists_in_txn(s,
            "SELECT id FROM cs_content_items WHERE tenant_id = ? AND id = ?",
            tenant_id, item_id)) {
        exec_sql(s, "ROLLBACK");
        return SF_ERR_NOT_FOUND;
    }
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT COALESCE(MAX(version_no), 0) + 1"
            " FROM cs_content_versions WHERE item_id = ?",
            -1, &st, NULL) != SQLITE_OK) {
        exec_sql(s, "ROLLBACK");
        return SF_ERR_DB;
    }
    sqlite3_bind_int64(st, 1, item_id);
    if (sqlite3_step(st) == SQLITE_ROW) next_no = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st); st = NULL;
    if (next_no <= 0) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }

    r = attach_increment_in_txn(s, tenant_id, blob_id);
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }

    if (sqlite3_prepare_v2(db_of(s),
            "INSERT INTO cs_content_versions (item_id, tenant_id, version_no,"
            " blob_id, note, metadata_json, created_by, created_at)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, item_id);
    sqlite3_bind_int64(st, 2, tenant_id);
    sqlite3_bind_int64(st, 3, next_no);
    sqlite3_bind_int64(st, 4, blob_id);
    sqlite3_bind_text(st, 5, note, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, metadata_json, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 7, created_by, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 8, now, -1, SQLITE_TRANSIENT);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    version_id = sqlite3_last_insert_rowid(db_of(s));

    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_content_items SET current_version_id = ?, updated_at = ?"
            " WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, version_id);
    sqlite3_bind_text(st, 2, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, tenant_id);
    sqlite3_bind_int64(st, 4, item_id);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }

    r = exec_sql(s, "COMMIT");
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    if (version_id_out) *version_id_out = version_id;
    if (version_no_out) *version_no_out = next_no;
    return SF_OK;
}

sf_result sf_blob_attach_content_ref(sf_store *s, int64_t tenant_id,
                                     int64_t from_item_id,
                                     int64_t to_item_id, int64_t to_blob_id,
                                     const char *kind, int64_t *ref_id_out) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    // The exactly-one-target CHECK, honored in code before any SQL.
    if (!s || tenant_id < 0) return SF_ERR_VALIDATION;
    if ((to_item_id >= 0) == (to_blob_id >= 0)) return SF_ERR_VALIDATION;
    if (!kind) kind = "";
    sf_now_iso(now);
    r = exec_sql(s, "BEGIN IMMEDIATE");
    if (r != SF_OK) return r;
    if (!exists_in_txn(s,
            "SELECT id FROM cs_content_items WHERE tenant_id = ? AND id = ?",
            tenant_id, from_item_id)) {
        exec_sql(s, "ROLLBACK");
        return SF_ERR_NOT_FOUND;
    }
    if (to_item_id >= 0 &&
        !exists_in_txn(s,
            "SELECT id FROM cs_content_items WHERE tenant_id = ? AND id = ?",
            tenant_id, to_item_id)) {
        exec_sql(s, "ROLLBACK");
        return SF_ERR_NOT_FOUND;
    }
    if (to_blob_id >= 0) {
        r = attach_increment_in_txn(s, tenant_id, to_blob_id);
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    }
    if (sqlite3_prepare_v2(db_of(s),
            "INSERT INTO cs_content_refs (tenant_id, from_item_id, to_item_id,"
            " to_blob_id, kind, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, from_item_id);
    if (to_item_id >= 0) sqlite3_bind_int64(st, 3, to_item_id);
    else sqlite3_bind_null(st, 3);
    if (to_blob_id >= 0) sqlite3_bind_int64(st, 4, to_blob_id);
    else sqlite3_bind_null(st, 4);
    sqlite3_bind_text(st, 5, kind, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, now, -1, SQLITE_TRANSIENT);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    if (ref_id_out) *ref_id_out = sqlite3_last_insert_rowid(db_of(s));
    return exec_sql(s, "COMMIT");
}

sf_result sf_blob_detach(sf_store *s, int64_t tenant_id, int64_t blob_id,
                         int *now_orphan_out) {
    sf_result r;
    if (!s) return SF_ERR_VALIDATION;
    r = exec_sql(s, "BEGIN IMMEDIATE");
    if (r != SF_OK) return r;
    r = detach_in_txn(s, tenant_id, blob_id, now_orphan_out);
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    return exec_sql(s, "COMMIT");
}

sf_result sf_blob_recompute_refcount(sf_store *s, int64_t tenant_id,
                                     int64_t blob_id, int64_t *out_count) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t count = 0;
    if (!s || !out_count) return SF_ERR_VALIDATION;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT (SELECT COUNT(*) FROM cs_objects WHERE blob_id = ?)"
            " + (SELECT COUNT(*) FROM cs_content_versions WHERE blob_id = ?)"
            " + (SELECT COUNT(*) FROM cs_content_refs WHERE to_blob_id = ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, blob_id);
    sqlite3_bind_int64(st, 2, blob_id);
    sqlite3_bind_int64(st, 3, blob_id);
    if (sqlite3_step(st) != SQLITE_ROW) {
        sqlite3_finalize(st);
        return SF_ERR_NOT_FOUND;
    }
    count = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st); st = NULL;
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_blobs SET refcount = ?,"
            " orphaned_at = CASE WHEN ? = 0 THEN COALESCE(orphaned_at, ?)"
            " ELSE NULL END WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, count);
    sqlite3_bind_int64(st, 2, count);
    sqlite3_bind_text(st, 3, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 4, tenant_id);
    sqlite3_bind_int64(st, 5, blob_id);
    {
        int changes = 0;
        r = step_done(s, st, &changes); st = NULL;
        if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    }
    *out_count = count;
    return r;
}

sf_result sf_blob_set_state(sf_store *s, int64_t tenant_id, int64_t blob_id,
                            const char *state) {
    sqlite3_stmt *st = NULL;
    sf_result r;
    int changes = 0;
    if (!s || !state ||
        (strcmp(state, "ok") != 0 && strcmp(state, "corrupt") != 0))
        return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_blobs SET state = ? WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, state, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, tenant_id);
    sqlite3_bind_int64(st, 3, blob_id);
    r = step_done(s, st, &changes);
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

sf_result sf_blob_delete_row(sf_store *s, int64_t tenant_id, int64_t blob_id) {
    sqlite3_stmt *st = NULL;
    sf_result r;
    int changes = 0;
    if (!s) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(db_of(s),
            "DELETE FROM cs_blobs WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, blob_id);
    r = step_done(s, st, &changes);
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

sf_result sf_blob_read(sf_adapter_ctx *actx, const sf_blob *blob,
                       uint8_t **data_out, size_t *len_out) {
    if (!actx || !blob) return SF_ERR_VALIDATION;
    if (strcmp(blob->state, "corrupt") == 0) return SF_BLOB_ERR_CORRUPT;
    return actx->vt->get(actx, blob->sha256_hex, data_out, len_out);
}

sf_result sf_blob_verify(sf_store *s, sf_adapter_ctx *actx, sf_blob *blob,
                         int *verified_out) {
    uint8_t *data = NULL;
    size_t len = 0;
    sf_result r;
    if (!s || !actx || !blob || !verified_out) return SF_ERR_VALIDATION;
    *verified_out = 0;
    // Verify reads the bytes even when state is already corrupt: the
    // recompute is the verdict, not the cached state.
    r = actx->vt->get(actx, blob->sha256_hex, &data, &len);
    if (r != SF_OK) {
        // Unreadable bytes are an integrity failure, stated as such.
        sf_blob_set_state(s, blob->tenant_id, blob->id, "corrupt");
        return SF_OK;
    }
    {
        uint8_t digest[32];
        int match;
        sf_sha256(data, len, digest);
        match = ((int64_t)len == blob->size_bytes) &&
                sf_ct_equal(digest, blob->sha256, 32) == 0;
        free(data);
        if (match) {
            sqlite3_stmt *st = NULL;
            sf_time now;
            sf_now_iso(now);
            if (sqlite3_prepare_v2(db_of(s),
                    "UPDATE cs_blobs SET last_verified_at = ?, state = 'ok'"
                    " WHERE tenant_id = ? AND id = ?",
                    -1, &st, NULL) == SQLITE_OK) {
                sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
                sqlite3_bind_int64(st, 2, blob->tenant_id);
                sqlite3_bind_int64(st, 3, blob->id);
                step_done(s, st, NULL);
            }
            set_str(blob->state, sizeof blob->state, "ok");
            set_str(blob->last_verified_at, sizeof blob->last_verified_at, now);
            *verified_out = 1;
            return SF_OK;
        }
    }
    sf_blob_set_state(s, blob->tenant_id, blob->id, "corrupt");
    set_str(blob->state, sizeof blob->state, "corrupt");
    return SF_OK;
}

sf_result sf_blob_accounting(sf_store *s, int64_t tenant_id,
                             sf_dedup_stats *out) {
    sqlite3_stmt *st = NULL;
    sf_result r = SF_ERR_DB;
    if (!s || !out) return SF_ERR_VALIDATION;
    memset(out, 0, sizeof *out);
    out->dedup_ratio = 1.0;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT"
            " (SELECT COALESCE(SUM(size_bytes),0) FROM cs_objects"
            "   WHERE tenant_id = ?)"
            " + (SELECT COALESCE(SUM(b.size_bytes),0)"
            "     FROM cs_content_versions v JOIN cs_blobs b ON b.id = v.blob_id"
            "     WHERE v.tenant_id = ?)"
            " + (SELECT COALESCE(SUM(b.size_bytes),0)"
            "     FROM cs_content_refs rf JOIN cs_blobs b ON b.id = rf.to_blob_id"
            "     WHERE rf.tenant_id = ?),"
            " (SELECT COALESCE(SUM(size_bytes),0) FROM cs_blobs"
            "   WHERE tenant_id = ? AND refcount > 0),"
            " (SELECT COUNT(*) FROM cs_blobs WHERE tenant_id = ?),"
            " (SELECT COUNT(*) FROM cs_objects WHERE tenant_id = ?)"
            " + (SELECT COUNT(*) FROM cs_content_versions WHERE tenant_id = ?)"
            " + (SELECT COUNT(*) FROM cs_content_refs WHERE tenant_id = ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    for (int i = 1; i <= 8; i++) sqlite3_bind_int64(st, i, tenant_id);
    if (sqlite3_step(st) == SQLITE_ROW) {
        out->logical_bytes = sqlite3_column_int64(st, 0);
        out->physical_bytes = sqlite3_column_int64(st, 1);
        out->blob_count = sqlite3_column_int64(st, 2);
        out->reference_count = sqlite3_column_int64(st, 3);
        r = SF_OK;
    }
    sqlite3_finalize(st);
    if (r == SF_OK) {
        out->bytes_saved = out->logical_bytes - out->physical_bytes;
        out->dedup_ratio = out->physical_bytes > 0
            ? (double)out->logical_bytes / (double)out->physical_bytes : 1.0;
    }
    return r;
}
