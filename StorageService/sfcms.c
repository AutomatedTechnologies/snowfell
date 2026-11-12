// sfcms.c — CMS content layer implementation (design §13.5).
// SQL lives here (not in sfstore.c) because the frozen sfstore.h has
// no CMS surface; the store handle is reached via sf_store_db(),
// exactly as in sfblob.c, whose local helpers this file mirrors.
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include "sfcms.h"
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

static char *dup_str(const char *src) {
    size_t n;
    char *p;
    if (!src) src = "";
    n = strlen(src) + 1;
    p = (char *)malloc(n);
    if (p) memcpy(p, src, n);
    return p;
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

static int exists_scoped(sf_store *s, const char *sql, int64_t tenant_id,
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

// Decrement a blob's refcount by n inside the caller's transaction,
// orphan-stamping when the count reaches 0 (mirrors sfblob.c's
// detach_in_txn, generalized to a batch drop for item deletion).
static sf_result drop_refcount_in_txn(sf_store *s, int64_t tenant_id,
                                      int64_t blob_id, int64_t n,
                                      const char *now) {
    sqlite3_stmt *st = NULL;
    sf_result r;
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_blobs SET refcount = refcount - ?"
            " WHERE tenant_id = ? AND id = ? AND refcount >= ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, n);
    sqlite3_bind_int64(st, 2, tenant_id);
    sqlite3_bind_int64(st, 3, blob_id);
    sqlite3_bind_int64(st, 4, n);
    {
        int changes = 0;
        r = step_done(s, st, &changes); st = NULL;
        if (r != SF_OK) return r;
        if (changes == 0) return SF_ERR_NOT_FOUND;
    }
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_blobs SET orphaned_at = ?"
            " WHERE tenant_id = ? AND id = ? AND refcount = 0"
            " AND orphaned_at IS NULL",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, tenant_id);
    sqlite3_bind_int64(st, 3, blob_id);
    return step_done(s, st, NULL);
}

static sf_result bump_refcount_in_txn(sf_store *s, int64_t tenant_id,
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

// ------------------------------------------------------------ collections

#define COLL_COLS "id, tenant_id, parent_id, name, slug, created_at, updated_at"

static void fill_collection(sqlite3_stmt *st, sf_cms_collection *c) {
    memset(c, 0, sizeof *c);
    c->id = sqlite3_column_int64(st, 0);
    c->tenant_id = sqlite3_column_int64(st, 1);
    c->parent_id = sqlite3_column_type(st, 2) == SQLITE_NULL
                       ? -1 : sqlite3_column_int64(st, 2);
    set_str(c->name, sizeof c->name, col_text(st, 3));
    set_str(c->slug, sizeof c->slug, col_text(st, 4));
    set_str(c->created_at, sizeof c->created_at, col_text(st, 5));
    set_str(c->updated_at, sizeof c->updated_at, col_text(st, 6));
}

sf_result sf_cms_create_collection(sf_store *s, int64_t tenant_id,
                                   int64_t parent_id, const char *name,
                                   const char *slug,
                                   sf_cms_collection *out) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    if (!s || tenant_id < 0 || !name || !name[0] || !slug || !slug[0])
        return SF_ERR_VALIDATION;
    if (parent_id >= 0 &&
        !exists_scoped(s,
            "SELECT id FROM cs_collections WHERE tenant_id = ? AND id = ?",
            tenant_id, parent_id))
        return SF_ERR_NOT_FOUND;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db_of(s),
            "INSERT INTO cs_collections (tenant_id, parent_id, name, slug,"
            " created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    if (parent_id >= 0) sqlite3_bind_int64(st, 2, parent_id);
    else sqlite3_bind_null(st, 2);
    sqlite3_bind_text(st, 3, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, slug, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, now, -1, SQLITE_TRANSIENT);
    r = step_done(s, st, NULL);
    if (r != SF_OK) return r;
    if (out)
        return sf_cms_get_collection(s, tenant_id,
                                     sqlite3_last_insert_rowid(db_of(s)), out);
    return SF_OK;
}

sf_result sf_cms_get_collection(sf_store *s, int64_t tenant_id,
                                int64_t collection_id,
                                sf_cms_collection *out) {
    sqlite3_stmt *st = NULL;
    sf_result r = SF_ERR_NOT_FOUND;
    if (!s || !out) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT " COLL_COLS " FROM cs_collections"
            " WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, collection_id);
    if (sqlite3_step(st) == SQLITE_ROW) { fill_collection(st, out); r = SF_OK; }
    sqlite3_finalize(st);
    return r;
}

sf_result sf_cms_list_collections(sf_store *s, int64_t tenant_id,
                                  int64_t cursor, int limit,
                                  sf_cms_collection **out_rows,
                                  size_t *out_count) {
    sqlite3_stmt *st = NULL;
    sf_cms_collection *rows = NULL;
    size_t count = 0, cap = 0;
    int rc;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (limit <= 0) limit = 50;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT " COLL_COLS " FROM cs_collections"
            " WHERE tenant_id = ? AND id > ? ORDER BY id ASC LIMIT ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, cursor);
    sqlite3_bind_int(st, 3, limit);
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (count == cap) {
            size_t ncap = cap ? cap * 2 : 16;
            sf_cms_collection *nr =
                (sf_cms_collection *)realloc(rows, ncap * sizeof *nr);
            if (!nr) { free(rows); sqlite3_finalize(st); return SF_ERR_NOMEM; }
            rows = nr; cap = ncap;
        }
        fill_collection(st, &rows[count]);
        count++;
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) { free(rows); return map_rc(rc); }
    *out_rows = rows;
    *out_count = count;
    return SF_OK;
}

void sf_cms_collection_free_all(sf_cms_collection *rows, size_t count) {
    (void)count;
    free(rows);
}

sf_result sf_cms_update_collection(sf_store *s, int64_t tenant_id,
                                   int64_t collection_id, const char *name,
                                   const char *slug, int64_t parent_id) {
    sf_cms_collection cur;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    if (!s) return SF_ERR_VALIDATION;
    r = sf_cms_get_collection(s, tenant_id, collection_id, &cur);
    if (r != SF_OK) return r;
    if (parent_id >= 0) {
        // Walk the new parent's ancestor chain: meeting this
        // collection anywhere in it would close a cycle.
        int64_t walk = parent_id;
        int hops = 0;
        while (walk >= 0 && hops++ < 10000) {
            sf_cms_collection p;
            if (walk == collection_id) return SF_ERR_VALIDATION;
            if (sf_cms_get_collection(s, tenant_id, walk, &p) != SF_OK)
                return SF_ERR_NOT_FOUND;
            walk = p.parent_id;
        }
    }
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_collections SET name = ?, slug = ?, parent_id = ?,"
            " updated_at = ? WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, name ? name : cur.name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, slug ? slug : cur.slug, -1, SQLITE_TRANSIENT);
    {
        int64_t np = parent_id == -2 ? cur.parent_id : parent_id;
        if (np >= 0) sqlite3_bind_int64(st, 3, np);
        else sqlite3_bind_null(st, 3);
    }
    sqlite3_bind_text(st, 4, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 5, tenant_id);
    sqlite3_bind_int64(st, 6, collection_id);
    return step_done(s, st, NULL);
}

sf_result sf_cms_delete_collection(sf_store *s, int64_t tenant_id,
                                   int64_t collection_id) {
    sqlite3_stmt *st = NULL;
    sf_result r;
    int64_t children = 0, items = 0;
    if (!s) return SF_ERR_VALIDATION;
    {
        sf_cms_collection cur;
        r = sf_cms_get_collection(s, tenant_id, collection_id, &cur);
        if (r != SF_OK) return r;
    }
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT (SELECT COUNT(*) FROM cs_collections"
            "   WHERE tenant_id = ? AND parent_id = ?),"
            " (SELECT COUNT(*) FROM cs_content_items"
            "   WHERE tenant_id = ? AND collection_id = ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, collection_id);
    sqlite3_bind_int64(st, 3, tenant_id);
    sqlite3_bind_int64(st, 4, collection_id);
    if (sqlite3_step(st) == SQLITE_ROW) {
        children = sqlite3_column_int64(st, 0);
        items = sqlite3_column_int64(st, 1);
    }
    sqlite3_finalize(st); st = NULL;
    if (children > 0 || items > 0) return SF_ERR_CONFLICT;
    if (sqlite3_prepare_v2(db_of(s),
            "DELETE FROM cs_collections WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, collection_id);
    {
        int changes = 0;
        r = step_done(s, st, &changes);
        if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    }
    return r;
}

// ------------------------------------------------------------ items

#define ITEM_COLS "i.id, i.tenant_id, i.collection_id, i.slug, i.title," \
                  " i.kind, i.state, i.metadata_json, i.created_by," \
                  " i.created_at, i.updated_at, i.current_version_id," \
                  " v.version_no, v.blob_id, b.sha256, b.size_bytes"
#define ITEM_JOINS " FROM cs_content_items i" \
                   " LEFT JOIN cs_content_versions v" \
                   "   ON v.id = i.current_version_id" \
                   " LEFT JOIN cs_blobs b ON b.id = v.blob_id"

static void fill_item(sqlite3_stmt *st, sf_cms_item *it) {
    const void *raw;
    int blen;
    memset(it, 0, sizeof *it);
    it->id = sqlite3_column_int64(st, 0);
    it->tenant_id = sqlite3_column_int64(st, 1);
    it->collection_id = sqlite3_column_type(st, 2) == SQLITE_NULL
                            ? -1 : sqlite3_column_int64(st, 2);
    set_str(it->slug, sizeof it->slug, col_text(st, 3));
    it->title = dup_str(col_text(st, 4));
    set_str(it->kind, sizeof it->kind, col_text(st, 5));
    set_str(it->state, sizeof it->state, col_text(st, 6));
    it->metadata_json = dup_str(col_text(st, 7));
    it->created_by = dup_str(col_text(st, 8));
    set_str(it->created_at, sizeof it->created_at, col_text(st, 9));
    set_str(it->updated_at, sizeof it->updated_at, col_text(st, 10));
    it->current_version_id = sqlite3_column_type(st, 11) == SQLITE_NULL
                                 ? -1 : sqlite3_column_int64(st, 11);
    it->current_version_no = sqlite3_column_type(st, 12) == SQLITE_NULL
                                 ? -1 : sqlite3_column_int64(st, 12);
    it->current_blob_id = sqlite3_column_type(st, 13) == SQLITE_NULL
                              ? -1 : sqlite3_column_int64(st, 13);
    raw = sqlite3_column_blob(st, 14);
    blen = sqlite3_column_bytes(st, 14);
    if (raw && blen == 32) {
        uint8_t digest[32];
        memcpy(digest, raw, 32);
        sf_hex_encode(digest, 32, it->current_sha256_hex);
    }
    it->current_size_bytes = sqlite3_column_type(st, 15) == SQLITE_NULL
                                 ? 0 : sqlite3_column_int64(st, 15);
}

void sf_cms_item_free(sf_cms_item *it) {
    if (!it) return;
    free(it->title); it->title = NULL;
    free(it->metadata_json); it->metadata_json = NULL;
    free(it->created_by); it->created_by = NULL;
}

void sf_cms_item_free_all(sf_cms_item *rows, size_t count) {
    if (!rows) return;
    for (size_t i = 0; i < count; i++) sf_cms_item_free(&rows[i]);
    free(rows);
}

sf_result sf_cms_create_item(sf_store *s, int64_t tenant_id,
                             int64_t collection_id, const char *slug,
                             const char *title, const char *kind,
                             const char *metadata_json, int64_t blob_id,
                             const char *created_by, sf_cms_item *out) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t item_id = -1, version_id = -1;
    if (!s || tenant_id < 0 || !slug || !slug[0] || blob_id < 0)
        return SF_ERR_VALIDATION;
    if (!title) title = "";
    if (!kind) kind = "";
    if (!metadata_json) metadata_json = "{}";
    if (!created_by) created_by = "";
    sf_now_iso(now);

    r = exec_sql(s, "BEGIN IMMEDIATE");
    if (r != SF_OK) return r;
    if (collection_id >= 0 &&
        !exists_scoped(s,
            "SELECT id FROM cs_collections WHERE tenant_id = ? AND id = ?",
            tenant_id, collection_id)) {
        exec_sql(s, "ROLLBACK");
        return SF_ERR_NOT_FOUND;
    }
    // The blob must resolve inside this tenant (§13.7): the increment
    // is scoped, so a cross-tenant blob id misses exactly like an
    // absent one — and it happens before the item insert, so a miss
    // leaves nothing behind.
    r = bump_refcount_in_txn(s, tenant_id, blob_id);
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }

    if (sqlite3_prepare_v2(db_of(s),
            "INSERT INTO cs_content_items (tenant_id, collection_id, slug,"
            " title, kind, state, current_version_id, metadata_json,"
            " created_by, created_at, updated_at)"
            " VALUES (?, ?, ?, ?, ?, 'draft', NULL, ?, ?, ?, ?)",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, tenant_id);
    if (collection_id >= 0) sqlite3_bind_int64(st, 2, collection_id);
    else sqlite3_bind_null(st, 2);
    sqlite3_bind_text(st, 3, slug, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, title, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, kind, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, metadata_json, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 7, created_by, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 8, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 9, now, -1, SQLITE_TRANSIENT);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    item_id = sqlite3_last_insert_rowid(db_of(s));

    if (sqlite3_prepare_v2(db_of(s),
            "INSERT INTO cs_content_versions (item_id, tenant_id, version_no,"
            " blob_id, note, metadata_json, created_by, created_at)"
            " VALUES (?, ?, 1, ?, '', ?, ?, ?)",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, item_id);
    sqlite3_bind_int64(st, 2, tenant_id);
    sqlite3_bind_int64(st, 3, blob_id);
    sqlite3_bind_text(st, 4, metadata_json, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, created_by, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, now, -1, SQLITE_TRANSIENT);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    version_id = sqlite3_last_insert_rowid(db_of(s));

    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_content_items SET current_version_id = ? WHERE id = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, version_id);
    sqlite3_bind_int64(st, 2, item_id);
    r = step_done(s, st, NULL); st = NULL;
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }

    r = exec_sql(s, "COMMIT");
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    if (out) return sf_cms_get_item(s, tenant_id, item_id, out);
    return SF_OK;
}

sf_result sf_cms_get_item(sf_store *s, int64_t tenant_id, int64_t item_id,
                          sf_cms_item *out) {
    sqlite3_stmt *st = NULL;
    sf_result r = SF_ERR_NOT_FOUND;
    if (!s || !out) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT " ITEM_COLS ITEM_JOINS
            " WHERE i.tenant_id = ? AND i.id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, item_id);
    if (sqlite3_step(st) == SQLITE_ROW) { fill_item(st, out); r = SF_OK; }
    sqlite3_finalize(st);
    return r;
}

// Shared list/search body. `pattern` is the escaped LIKE pattern for
// q (NULL = no q filter).
static sf_result list_items_query(sf_store *s, int64_t tenant_id,
                                  const char *pattern, int64_t collection_id,
                                  const char *kind, const char *state,
                                  int64_t cursor, int limit,
                                  sf_cms_item **out_rows, size_t *out_count) {
    char sql[1024];
    sqlite3_stmt *st = NULL;
    sf_cms_item *rows = NULL;
    size_t count = 0, cap = 0;
    int rc, bind = 1;
    if (limit <= 0) limit = 50;
    snprintf(sql, sizeof sql,
             "SELECT " ITEM_COLS ITEM_JOINS
             " WHERE i.tenant_id = ? AND i.id > ?");
    if (pattern)
        strncat(sql,
                " AND (i.title LIKE ? ESCAPE '\\' OR i.slug LIKE ? ESCAPE '\\'"
                " OR i.metadata_json LIKE ? ESCAPE '\\')",
                sizeof sql - strlen(sql) - 1);
    if (collection_id >= 0)
        strncat(sql, " AND i.collection_id = ?", sizeof sql - strlen(sql) - 1);
    if (kind)
        strncat(sql, " AND i.kind = ?", sizeof sql - strlen(sql) - 1);
    if (state)
        strncat(sql, " AND i.state = ?", sizeof sql - strlen(sql) - 1);
    strncat(sql, " ORDER BY i.id ASC LIMIT ?", sizeof sql - strlen(sql) - 1);
    if (sqlite3_prepare_v2(db_of(s), sql, -1, &st, NULL) != SQLITE_OK)
        return SF_ERR_DB;
    sqlite3_bind_int64(st, bind++, tenant_id);
    sqlite3_bind_int64(st, bind++, cursor);
    if (pattern) {
        sqlite3_bind_text(st, bind++, pattern, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, bind++, pattern, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, bind++, pattern, -1, SQLITE_TRANSIENT);
    }
    if (collection_id >= 0) sqlite3_bind_int64(st, bind++, collection_id);
    if (kind) sqlite3_bind_text(st, bind++, kind, -1, SQLITE_TRANSIENT);
    if (state) sqlite3_bind_text(st, bind++, state, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(st, bind++, limit);
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (count == cap) {
            size_t ncap = cap ? cap * 2 : 16;
            sf_cms_item *nr = (sf_cms_item *)realloc(rows, ncap * sizeof *nr);
            if (!nr) {
                for (size_t i = 0; i < count; i++) sf_cms_item_free(&rows[i]);
                free(rows);
                sqlite3_finalize(st);
                return SF_ERR_NOMEM;
            }
            rows = nr; cap = ncap;
        }
        fill_item(st, &rows[count]);
        count++;
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) {
        sf_cms_item_free_all(rows, count);
        return map_rc(rc);
    }
    *out_rows = rows;
    *out_count = count;
    return SF_OK;
}

sf_result sf_cms_list_items(sf_store *s, int64_t tenant_id,
                            int64_t collection_id, const char *kind,
                            const char *state, int64_t cursor, int limit,
                            sf_cms_item **out_rows, size_t *out_count) {
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    return list_items_query(s, tenant_id, NULL, collection_id, kind, state,
                            cursor, limit, out_rows, out_count);
}

sf_result sf_cms_search_items(sf_store *s, int64_t tenant_id, const char *q,
                              int64_t collection_id, const char *kind,
                              const char *state, int64_t cursor, int limit,
                              sf_cms_item **out_rows, size_t *out_count) {
    char *pattern = NULL;
    sf_result r;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (q && q[0]) {
        // Escape LIKE metacharacters so q matches literally: the
        // escape character itself first, then % and _ (§13.5: q is a
        // substring, not a pattern language).
        size_t cap = strlen(q) * 2 + 3, n = 0;
        pattern = (char *)malloc(cap);
        if (!pattern) return SF_ERR_NOMEM;
        pattern[n++] = '%';
        for (const char *p = q; *p; p++) {
            if (*p == '\\' || *p == '%' || *p == '_') pattern[n++] = '\\';
            pattern[n++] = *p;
        }
        pattern[n++] = '%';
        pattern[n] = '\0';
    }
    r = list_items_query(s, tenant_id, pattern, collection_id, kind, state,
                         cursor, limit, out_rows, out_count);
    free(pattern);
    return r;
}

sf_result sf_cms_update_item(sf_store *s, int64_t tenant_id, int64_t item_id,
                             const char *title, const char *kind,
                             int64_t collection_id,
                             const char *metadata_json) {
    sf_cms_item cur;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    if (!s) return SF_ERR_VALIDATION;
    memset(&cur, 0, sizeof cur);
    r = sf_cms_get_item(s, tenant_id, item_id, &cur);
    if (r != SF_OK) return r;
    if (collection_id >= 0 &&
        !exists_scoped(s,
            "SELECT id FROM cs_collections WHERE tenant_id = ? AND id = ?",
            tenant_id, collection_id)) {
        sf_cms_item_free(&cur);
        return SF_ERR_NOT_FOUND;
    }
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_content_items SET title = ?, kind = ?,"
            " collection_id = ?, metadata_json = ?, updated_at = ?"
            " WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) {
        sf_cms_item_free(&cur);
        return SF_ERR_DB;
    }
    sqlite3_bind_text(st, 1, title ? title : (cur.title ? cur.title : ""),
                      -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, kind ? kind : cur.kind, -1, SQLITE_TRANSIENT);
    {
        int64_t nc = collection_id == -2 ? cur.collection_id : collection_id;
        if (nc >= 0) sqlite3_bind_int64(st, 3, nc);
        else sqlite3_bind_null(st, 3);
    }
    sqlite3_bind_text(st, 4,
                      metadata_json ? metadata_json
                                    : (cur.metadata_json ? cur.metadata_json : "{}"),
                      -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 6, tenant_id);
    sqlite3_bind_int64(st, 7, item_id);
    r = step_done(s, st, NULL);
    sf_cms_item_free(&cur);
    return r;
}

sf_result sf_cms_set_item_state(sf_store *s, int64_t tenant_id,
                                int64_t item_id, const char *state) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int changes = 0;
    if (!s || !state ||
        (strcmp(state, "draft") != 0 && strcmp(state, "published") != 0 &&
         strcmp(state, "archived") != 0))
        return SF_ERR_VALIDATION;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_content_items SET state = ?, updated_at = ?"
            " WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, state, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, tenant_id);
    sqlite3_bind_int64(st, 4, item_id);
    r = step_done(s, st, &changes);
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

sf_result sf_cms_delete_item(sf_store *s, int64_t tenant_id, int64_t item_id,
                             char *slug_out, size_t slug_cap) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    // (blob_id, drops) pairs gathered before the delete cascades.
    int64_t blobs[512];
    int64_t drops[512];
    size_t nb = 0;
    if (!s) return SF_ERR_VALIDATION;
    sf_now_iso(now);
    r = exec_sql(s, "BEGIN IMMEDIATE");
    if (r != SF_OK) return r;
    {
        int found = 0;
        if (sqlite3_prepare_v2(db_of(s),
                "SELECT slug FROM cs_content_items"
                " WHERE tenant_id = ? AND id = ?",
                -1, &st, NULL) != SQLITE_OK) {
            exec_sql(s, "ROLLBACK");
            return SF_ERR_DB;
        }
        sqlite3_bind_int64(st, 1, tenant_id);
        sqlite3_bind_int64(st, 2, item_id);
        if (sqlite3_step(st) == SQLITE_ROW) {
            found = 1;
            if (slug_out && slug_cap > 0)
                set_str(slug_out, slug_cap, col_text(st, 0));
        }
        sqlite3_finalize(st); st = NULL;
        if (!found) { exec_sql(s, "ROLLBACK"); return SF_ERR_NOT_FOUND; }
    }
    // References this item holds: its versions, and its outgoing
    // blob refs. (Incoming refs and outgoing item refs hold no blob
    // count; the cascades remove their rows.)
    {
        static const char *qs[2] = {
            "SELECT blob_id, COUNT(*) FROM cs_content_versions"
            " WHERE tenant_id = ? AND item_id = ? GROUP BY blob_id",
            "SELECT to_blob_id, COUNT(*) FROM cs_content_refs"
            " WHERE tenant_id = ? AND from_item_id = ?"
            " AND to_blob_id IS NOT NULL GROUP BY to_blob_id"
        };
        for (int q = 0; q < 2; q++) {
            int rc;
            if (sqlite3_prepare_v2(db_of(s), qs[q], -1, &st, NULL) != SQLITE_OK) {
                exec_sql(s, "ROLLBACK");
                return SF_ERR_DB;
            }
            sqlite3_bind_int64(st, 1, tenant_id);
            sqlite3_bind_int64(st, 2, item_id);
            while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
                int64_t bid = sqlite3_column_int64(st, 0);
                int64_t cnt = sqlite3_column_int64(st, 1);
                size_t j;
                for (j = 0; j < nb; j++) if (blobs[j] == bid) break;
                if (j == nb) {
                    if (nb >= 512) {
                        sqlite3_finalize(st);
                        exec_sql(s, "ROLLBACK");
                        return SF_ERR_TOO_LARGE;
                    }
                    blobs[nb] = bid;
                    drops[nb] = 0;
                    nb++;
                }
                drops[j] += cnt;
            }
            sqlite3_finalize(st); st = NULL;
            if (rc != SQLITE_DONE) { exec_sql(s, "ROLLBACK"); return map_rc(rc); }
        }
    }
    if (sqlite3_prepare_v2(db_of(s),
            "DELETE FROM cs_content_items WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) {
        exec_sql(s, "ROLLBACK");
        return SF_ERR_DB;
    }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, item_id);
    {
        int changes = 0;
        r = step_done(s, st, &changes); st = NULL;
        if (r != SF_OK || changes == 0) {
            exec_sql(s, "ROLLBACK");
            return r != SF_OK ? r : SF_ERR_NOT_FOUND;
        }
    }
    for (size_t j = 0; j < nb; j++) {
        r = drop_refcount_in_txn(s, tenant_id, blobs[j], drops[j], now);
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    }
    return exec_sql(s, "COMMIT");
}

// ------------------------------------------------------------ versions

#define VERSION_COLS "v.id, v.item_id, v.tenant_id, v.version_no, v.blob_id," \
                     " b.sha256, b.size_bytes, v.note, v.metadata_json," \
                     " v.created_by, v.created_at"
#define VERSION_JOINS " FROM cs_content_versions v" \
                      " JOIN cs_blobs b ON b.id = v.blob_id"

static void fill_version(sqlite3_stmt *st, sf_cms_version *v) {
    const void *raw;
    int blen;
    memset(v, 0, sizeof *v);
    v->id = sqlite3_column_int64(st, 0);
    v->item_id = sqlite3_column_int64(st, 1);
    v->tenant_id = sqlite3_column_int64(st, 2);
    v->version_no = sqlite3_column_int64(st, 3);
    v->blob_id = sqlite3_column_int64(st, 4);
    raw = sqlite3_column_blob(st, 5);
    blen = sqlite3_column_bytes(st, 5);
    if (raw && blen == 32) {
        uint8_t digest[32];
        memcpy(digest, raw, 32);
        sf_hex_encode(digest, 32, v->sha256_hex);
    }
    v->size_bytes = sqlite3_column_int64(st, 6);
    v->note = dup_str(col_text(st, 7));
    v->metadata_json = dup_str(col_text(st, 8));
    v->created_by = dup_str(col_text(st, 9));
    set_str(v->created_at, sizeof v->created_at, col_text(st, 10));
}

void sf_cms_version_free(sf_cms_version *v) {
    if (!v) return;
    free(v->note); v->note = NULL;
    free(v->metadata_json); v->metadata_json = NULL;
    free(v->created_by); v->created_by = NULL;
}

void sf_cms_version_free_all(sf_cms_version *rows, size_t count) {
    if (!rows) return;
    for (size_t i = 0; i < count; i++) sf_cms_version_free(&rows[i]);
    free(rows);
}

sf_result sf_cms_get_version(sf_store *s, int64_t tenant_id, int64_t item_id,
                             int64_t version_no, sf_cms_version *out) {
    sqlite3_stmt *st = NULL;
    sf_result r = SF_ERR_NOT_FOUND;
    if (!s || !out) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT " VERSION_COLS VERSION_JOINS
            " WHERE v.tenant_id = ? AND v.item_id = ? AND v.version_no = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, item_id);
    sqlite3_bind_int64(st, 3, version_no);
    if (sqlite3_step(st) == SQLITE_ROW) { fill_version(st, out); r = SF_OK; }
    sqlite3_finalize(st);
    return r;
}

sf_result sf_cms_append_version(sf_store *s, int64_t tenant_id,
                                int64_t item_id, int64_t blob_id,
                                const char *note, const char *metadata_json,
                                const char *created_by,
                                sf_cms_version *out) {
    int64_t version_no = 0;
    sf_result r;
    if (!s) return SF_ERR_VALIDATION;
    r = sf_blob_attach_version(s, tenant_id, item_id, blob_id, note,
                               metadata_json, created_by, NULL, &version_no);
    if (r != SF_OK) return r;
    if (out) return sf_cms_get_version(s, tenant_id, item_id, version_no, out);
    return SF_OK;
}

sf_result sf_cms_rollback(sf_store *s, int64_t tenant_id, int64_t item_id,
                          int64_t target_version_no, const char *created_by,
                          sf_cms_version *out) {
    sf_cms_version target;
    char note[64];
    sf_result r;
    if (!s) return SF_ERR_VALIDATION;
    memset(&target, 0, sizeof target);
    r = sf_cms_get_version(s, tenant_id, item_id, target_version_no, &target);
    if (r != SF_OK) return r;
    snprintf(note, sizeof note, "rollback of v%lld", (long long)target_version_no);
    r = sf_cms_append_version(s, tenant_id, item_id, target.blob_id, note,
                              target.metadata_json ? target.metadata_json : "{}",
                              created_by, out);
    sf_cms_version_free(&target);
    return r;
}

sf_result sf_cms_list_versions(sf_store *s, int64_t tenant_id,
                               int64_t item_id, sf_cms_version **out_rows,
                               size_t *out_count) {
    sqlite3_stmt *st = NULL;
    sf_cms_version *rows = NULL;
    size_t count = 0, cap = 0;
    int rc;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (!exists_scoped(s,
            "SELECT id FROM cs_content_items WHERE tenant_id = ? AND id = ?",
            tenant_id, item_id))
        return SF_ERR_NOT_FOUND;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT " VERSION_COLS VERSION_JOINS
            " WHERE v.tenant_id = ? AND v.item_id = ?"
            " ORDER BY v.version_no DESC LIMIT 10000",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, item_id);
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (count == cap) {
            size_t ncap = cap ? cap * 2 : 16;
            sf_cms_version *nr =
                (sf_cms_version *)realloc(rows, ncap * sizeof *nr);
            if (!nr) {
                sf_cms_version_free_all(rows, count);
                sqlite3_finalize(st);
                return SF_ERR_NOMEM;
            }
            rows = nr; cap = ncap;
        }
        fill_version(st, &rows[count]);
        count++;
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) {
        sf_cms_version_free_all(rows, count);
        return map_rc(rc);
    }
    *out_rows = rows;
    *out_count = count;
    return SF_OK;
}

// ------------------------------------------------------------ refs

#define REF_COLS "id, tenant_id, from_item_id, to_item_id, to_blob_id, kind," \
                 " created_at"

static void fill_ref(sqlite3_stmt *st, sf_cms_ref *rf) {
    memset(rf, 0, sizeof *rf);
    rf->id = sqlite3_column_int64(st, 0);
    rf->tenant_id = sqlite3_column_int64(st, 1);
    rf->from_item_id = sqlite3_column_int64(st, 2);
    rf->to_item_id = sqlite3_column_type(st, 3) == SQLITE_NULL
                         ? -1 : sqlite3_column_int64(st, 3);
    rf->to_blob_id = sqlite3_column_type(st, 4) == SQLITE_NULL
                         ? -1 : sqlite3_column_int64(st, 4);
    set_str(rf->kind, sizeof rf->kind, col_text(st, 5));
    set_str(rf->created_at, sizeof rf->created_at, col_text(st, 6));
}

void sf_cms_ref_free_all(sf_cms_ref *rows, size_t count) {
    (void)count;
    free(rows);
}

sf_result sf_cms_create_ref(sf_store *s, int64_t tenant_id,
                            int64_t from_item_id, int64_t to_item_id,
                            int64_t to_blob_id, const char *kind,
                            sf_cms_ref *out) {
    int64_t ref_id = -1;
    sf_result r;
    if (!s) return SF_ERR_VALIDATION;
    r = sf_blob_attach_content_ref(s, tenant_id, from_item_id, to_item_id,
                                   to_blob_id, kind, &ref_id);
    if (r != SF_OK) return r;
    if (out) return sf_cms_get_ref(s, tenant_id, from_item_id, ref_id, out);
    return SF_OK;
}

sf_result sf_cms_get_ref(sf_store *s, int64_t tenant_id, int64_t from_item_id,
                         int64_t ref_id, sf_cms_ref *out) {
    sqlite3_stmt *st = NULL;
    sf_result r = SF_ERR_NOT_FOUND;
    if (!s || !out) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT " REF_COLS " FROM cs_content_refs"
            " WHERE tenant_id = ? AND from_item_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, from_item_id);
    sqlite3_bind_int64(st, 3, ref_id);
    if (sqlite3_step(st) == SQLITE_ROW) { fill_ref(st, out); r = SF_OK; }
    sqlite3_finalize(st);
    return r;
}

sf_result sf_cms_list_refs(sf_store *s, int64_t tenant_id, int64_t item_id,
                           sf_cms_ref **out_rows, size_t *out_count) {
    sqlite3_stmt *st = NULL;
    sf_cms_ref *rows = NULL;
    size_t count = 0, cap = 0;
    int rc;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (!exists_scoped(s,
            "SELECT id FROM cs_content_items WHERE tenant_id = ? AND id = ?",
            tenant_id, item_id))
        return SF_ERR_NOT_FOUND;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT " REF_COLS " FROM cs_content_refs"
            " WHERE tenant_id = ? AND from_item_id = ? ORDER BY id ASC",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, item_id);
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (count == cap) {
            size_t ncap = cap ? cap * 2 : 16;
            sf_cms_ref *nr = (sf_cms_ref *)realloc(rows, ncap * sizeof *nr);
            if (!nr) { free(rows); sqlite3_finalize(st); return SF_ERR_NOMEM; }
            rows = nr; cap = ncap;
        }
        fill_ref(st, &rows[count]);
        count++;
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) { free(rows); return map_rc(rc); }
    *out_rows = rows;
    *out_count = count;
    return SF_OK;
}

sf_result sf_cms_delete_ref(sf_store *s, int64_t tenant_id,
                            int64_t from_item_id, int64_t ref_id) {
    sf_cms_ref rf;
    sf_time now;
    sqlite3_stmt *st = NULL;
    sf_result r;
    if (!s) return SF_ERR_VALIDATION;
    memset(&rf, 0, sizeof rf);
    r = sf_cms_get_ref(s, tenant_id, from_item_id, ref_id, &rf);
    if (r != SF_OK) return r;
    sf_now_iso(now);
    r = exec_sql(s, "BEGIN IMMEDIATE");
    if (r != SF_OK) return r;
    if (sqlite3_prepare_v2(db_of(s),
            "DELETE FROM cs_content_refs"
            " WHERE tenant_id = ? AND from_item_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) {
        exec_sql(s, "ROLLBACK");
        return SF_ERR_DB;
    }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, from_item_id);
    sqlite3_bind_int64(st, 3, ref_id);
    {
        int changes = 0;
        r = step_done(s, st, &changes); st = NULL;
        if (r != SF_OK || changes == 0) {
            exec_sql(s, "ROLLBACK");
            return r != SF_OK ? r : SF_ERR_NOT_FOUND;
        }
    }
    if (rf.to_blob_id >= 0) {
        r = drop_refcount_in_txn(s, tenant_id, rf.to_blob_id, 1, now);
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    }
    return exec_sql(s, "COMMIT");
}
