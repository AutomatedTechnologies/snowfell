// sfstore.c — Snowfell Storage Service store layer (design record 03
// §3.2/§4/§6.1/§7.4). Every tenant-owned query is tenant-scoped; a
// scoped miss is SF_ERR_NOT_FOUND whether the row is absent or owned
// by another tenant. The embedded DDL below is schema_cloud.sql,
// embedded verbatim (keep the two in sync — schema_cloud.sql is the
// DDL of record).
#include "sfstore.h"
#include "sfsha256.h"

#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

struct sf_store {
    sqlite3 *db;
};

// ---- embedded DDL (schema_cloud.sql) --------------------------------
static const char SF_DDL[] =
    "-- Snowfell Storage Service — operational store DDL (design record 03\n"
    "-- §4/§6.1). This schema lives ONLY in the service's cloud.db. It is\n"
    "-- never applied to the registry, never bundled, never published:\n"
    "-- cs_credentials and cs_tokens hold secret-derived material, and the\n"
    "-- publication filter (design record 01 §2) is absolute.\n"
    "--\n"
    "-- The service embeds this DDL (sf_store_open bootstraps an empty DB\n"
    "-- from it) and versions it via cs_meta.schema_version = 2 (SF-T12h, design §13.10).\n"
    "\n"
    "PRAGMA foreign_keys = ON;\n"
    "\n"
    "CREATE TABLE cs_meta (\n"
    "    key TEXT PRIMARY KEY,\n"
    "    value TEXT NOT NULL\n"
    ");\n"
    "INSERT INTO cs_meta (key, value) VALUES ('schema_version', '2');\n"
    "\n"
    "CREATE TABLE cs_tenants (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    slug TEXT NOT NULL UNIQUE,\n"
    "    display_name TEXT NOT NULL,\n"
    "    state TEXT NOT NULL DEFAULT 'active'\n"
    "        CHECK (state IN ('active', 'suspended', 'closed')),\n"
    "    quota_bytes INTEGER NOT NULL DEFAULT -1,\n"
    "    quota_objects INTEGER NOT NULL DEFAULT -1,\n"
    "    quota_buckets INTEGER NOT NULL DEFAULT -1,\n"
    "    contact_note TEXT NOT NULL DEFAULT '',\n"
    "    provenance TEXT NOT NULL DEFAULT 'service',\n"
    "    directive TEXT NOT NULL DEFAULT '',\n"
    "    created_at TEXT NOT NULL,\n"
    "    updated_at TEXT NOT NULL\n"
    ");\n"
    "\n"
    "CREATE TABLE cs_logins (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    username TEXT NOT NULL,\n"
    "    display_name TEXT NOT NULL DEFAULT '',\n"
    "    role TEXT NOT NULL CHECK (role IN ('tenant_admin', 'tenant_user')),\n"
    "    state TEXT NOT NULL DEFAULT 'active'\n"
    "        CHECK (state IN ('active', 'disabled')),\n"
    "    last_login_at TEXT,\n"
    "    created_at TEXT NOT NULL,\n"
    "    updated_at TEXT NOT NULL,\n"
    "    UNIQUE (tenant_id, username)\n"
    ");\n"
    "\n"
    "-- One credential row per (login, kind). kind 'fido2' is the record-02\n"
    "-- seam: columns stay NULL for it until R1 lands; nothing in v1 writes\n"
    "-- or reads a fido2 row.\n"
    "CREATE TABLE cs_credentials (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    login_id INTEGER NOT NULL REFERENCES cs_logins (id)\n"
    "        ON UPDATE CASCADE ON DELETE CASCADE,\n"
    "    kind TEXT NOT NULL CHECK (kind IN ('password', 'fido2')),\n"
    "    password_salt BLOB,\n"
    "    password_hash BLOB,\n"
    "    password_iterations INTEGER,\n"
    "    password_changed_at TEXT,\n"
    "    failed_attempts INTEGER NOT NULL DEFAULT 0,\n"
    "    locked_until TEXT,\n"
    "    created_at TEXT NOT NULL,\n"
    "    updated_at TEXT NOT NULL,\n"
    "    UNIQUE (login_id, kind)\n"
    ");\n"
    "\n"
    "-- Only SHA-256 digests of tokens are stored (LTD licensing precedent).\n"
    "-- tenant_id/login_id are NULL for the operator token (scope = all).\n"
    "CREATE TABLE cs_tokens (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    tenant_id INTEGER REFERENCES cs_tenants (id)\n"
    "        ON UPDATE CASCADE ON DELETE CASCADE,\n"
    "    login_id INTEGER REFERENCES cs_logins (id)\n"
    "        ON UPDATE CASCADE ON DELETE CASCADE,\n"
    "    kind TEXT NOT NULL CHECK (kind IN ('session', 'api', 'operator')),\n"
    "    token_sha256 BLOB NOT NULL UNIQUE,\n"
    "    label TEXT NOT NULL DEFAULT '',\n"
    "    created_at TEXT NOT NULL,\n"
    "    expires_at TEXT,\n"
    "    revoked_at TEXT,\n"
    "    last_used_at TEXT\n"
    ");\n"
    "CREATE INDEX cs_tokens_login ON cs_tokens (login_id);\n"
    "\n"
    "CREATE TABLE cs_password_resets (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    login_id INTEGER NOT NULL REFERENCES cs_logins (id)\n"
    "        ON UPDATE CASCADE ON DELETE CASCADE,\n"
    "    token_sha256 BLOB NOT NULL UNIQUE,\n"
    "    created_by TEXT NOT NULL DEFAULT '',\n"
    "    created_at TEXT NOT NULL,\n"
    "    expires_at TEXT NOT NULL,\n"
    "    used_at TEXT\n"
    ");\n"
    "\n"
    "CREATE TABLE cs_backends (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    name TEXT NOT NULL UNIQUE,\n"
    "    kind TEXT NOT NULL CHECK (kind IN ('filesystem', 's3')),\n"
    "    config_json TEXT NOT NULL DEFAULT '{}',\n"
    "    secret_ref TEXT NOT NULL DEFAULT '',\n"
    "    state TEXT NOT NULL DEFAULT 'active'\n"
    "        CHECK (state IN ('active', 'disabled')),\n"
    "    created_at TEXT NOT NULL,\n"
    "    updated_at TEXT NOT NULL\n"
    ");\n"
    "\n"
    "\n"
    "-- Content-addressable blobs (design §13.2): identity is\n"
    "-- (tenant_id, sha256) — the per-tenant dedup scope (§13.4). Bytes live\n"
    "-- through the §7 adapters under the blob's hex digest as the adapter\n"
    "-- key. refcount is maintained transactionally at every reference\n"
    "-- create/delete and recomputed by the GC sweep before any deletion.\n"
    "CREATE TABLE cs_blobs (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    sha256 BLOB NOT NULL,\n"
    "    size_bytes INTEGER NOT NULL,\n"
    "    backend_id INTEGER NOT NULL REFERENCES cs_backends (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    refcount INTEGER NOT NULL DEFAULT 0,\n"
    "    state TEXT NOT NULL DEFAULT 'ok' CHECK (state IN ('ok', 'corrupt')),\n"
    "    orphaned_at TEXT,\n"
    "    created_at TEXT NOT NULL,\n"
    "    last_verified_at TEXT,\n"
    "    UNIQUE (tenant_id, sha256)\n"
    ");\n"
    "CREATE INDEX cs_blobs_tenant ON cs_blobs (tenant_id, state);\n"
    "\n"
    "CREATE TABLE cs_buckets (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    name TEXT NOT NULL,\n"
    "    backend_id INTEGER NOT NULL REFERENCES cs_backends (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    quota_bytes INTEGER NOT NULL DEFAULT -1,\n"
    "    object_count INTEGER NOT NULL DEFAULT 0,\n"
    "    total_bytes INTEGER NOT NULL DEFAULT 0,\n"
    "    created_at TEXT NOT NULL,\n"
    "    updated_at TEXT NOT NULL,\n"
    "    UNIQUE (tenant_id, name)\n"
    ");\n"
    "\n"
    "-- tenant_id is denormalized onto the object row deliberately: every\n"
    "-- object query filters on it directly (design §3.2 walls 2-3).\n"
    "CREATE TABLE cs_objects (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    bucket_id INTEGER NOT NULL REFERENCES cs_buckets (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    key TEXT NOT NULL,\n"
    "    size_bytes INTEGER NOT NULL,\n"
    "    sha256 BLOB NOT NULL,\n"
    "    content_type TEXT NOT NULL DEFAULT 'application/octet-stream',\n"
    "    metadata_json TEXT NOT NULL DEFAULT '{}',\n"
    "    blob_id INTEGER REFERENCES cs_blobs (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    created_at TEXT NOT NULL,\n"
    "    updated_at TEXT NOT NULL,\n"
    "    UNIQUE (bucket_id, key)\n"
    ");\n"
    "CREATE INDEX cs_objects_tenant ON cs_objects (tenant_id, bucket_id);\n"
    "\n"
    "-- Append-only by API (the store exposes insert + scoped read only).\n"
    "-- detail_json carries figures and refs — never secrets, never tokens.\n"
    "CREATE TABLE cs_audit_log (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    ts TEXT NOT NULL,\n"
    "    tenant_id INTEGER,\n"
    "    actor_kind TEXT NOT NULL CHECK (actor_kind IN ('operator', 'login', 'system')),\n"
    "    actor_ref TEXT NOT NULL DEFAULT '',\n"
    "    action TEXT NOT NULL,\n"
    "    object_ref TEXT NOT NULL DEFAULT '',\n"
    "    result TEXT NOT NULL CHECK (result IN ('ok', 'denied', 'error')),\n"
    "    detail_json TEXT NOT NULL DEFAULT '{}',\n"
    "    ip TEXT\n"
    ");\n"
    "CREATE INDEX cs_audit_tenant ON cs_audit_log (tenant_id, id);\n"
    "\n"
    "-- CMS content layer (design §13.5): collections are the structure\n"
    "-- tree; items carry append-only versions; refs link items to items or\n"
    "-- blobs. These tables are created at schema v2 and exercised by the\n"
    "-- SF-T12i routes; blob references from cs_content_versions and\n"
    "-- cs_content_refs count in cs_blobs.refcount (§13.2).\n"
    "CREATE TABLE cs_collections (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    parent_id INTEGER REFERENCES cs_collections (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    name TEXT NOT NULL,\n"
    "    slug TEXT NOT NULL,\n"
    "    created_at TEXT NOT NULL,\n"
    "    updated_at TEXT NOT NULL,\n"
    "    UNIQUE (tenant_id, slug)\n"
    ");\n"
    "\n"
    "CREATE TABLE cs_content_items (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    collection_id INTEGER REFERENCES cs_collections (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    slug TEXT NOT NULL,\n"
    "    title TEXT NOT NULL DEFAULT '',\n"
    "    kind TEXT NOT NULL DEFAULT '',\n"
    "    state TEXT NOT NULL DEFAULT 'draft'\n"
    "        CHECK (state IN ('draft', 'published', 'archived')),\n"
    "    current_version_id INTEGER,\n"
    "    metadata_json TEXT NOT NULL DEFAULT '{}',\n"
    "    created_by TEXT NOT NULL DEFAULT '',\n"
    "    created_at TEXT NOT NULL,\n"
    "    updated_at TEXT NOT NULL,\n"
    "    UNIQUE (tenant_id, slug)\n"
    ");\n"
    "\n"
    "CREATE TABLE cs_content_versions (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    item_id INTEGER NOT NULL REFERENCES cs_content_items (id)\n"
    "        ON UPDATE CASCADE ON DELETE CASCADE,\n"
    "    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    version_no INTEGER NOT NULL,\n"
    "    blob_id INTEGER NOT NULL REFERENCES cs_blobs (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    note TEXT NOT NULL DEFAULT '',\n"
    "    metadata_json TEXT NOT NULL DEFAULT '{}',\n"
    "    created_by TEXT NOT NULL DEFAULT '',\n"
    "    created_at TEXT NOT NULL,\n"
    "    UNIQUE (item_id, version_no)\n"
    ");\n"
    "CREATE INDEX cs_content_versions_blob ON cs_content_versions (blob_id);\n"
    "\n"
    "CREATE TABLE cs_content_refs (\n"
    "    id INTEGER PRIMARY KEY,\n"
    "    tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    from_item_id INTEGER NOT NULL REFERENCES cs_content_items (id)\n"
    "        ON UPDATE CASCADE ON DELETE CASCADE,\n"
    "    to_item_id INTEGER REFERENCES cs_content_items (id)\n"
    "        ON UPDATE CASCADE ON DELETE CASCADE,\n"
    "    to_blob_id INTEGER REFERENCES cs_blobs (id)\n"
    "        ON UPDATE CASCADE ON DELETE RESTRICT,\n"
    "    kind TEXT NOT NULL DEFAULT '',\n"
    "    created_at TEXT NOT NULL,\n"
    "    CHECK ((to_item_id IS NOT NULL AND to_blob_id IS NULL)\n"
    "        OR (to_item_id IS NULL AND to_blob_id IS NOT NULL))\n"
    ");\n"
    "CREATE INDEX cs_content_refs_blob ON cs_content_refs (to_blob_id);\n"
    "\n";

// ---- small helpers ----------------------------------------------------

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
    n = strlen(src);
    p = (char *)malloc(n + 1);
    if (!p) return NULL;
    memcpy(p, src, n + 1);
    return p;
}

static const char *col_text(sqlite3_stmt *st, int i) {
    const unsigned char *t = sqlite3_column_text(st, i);
    return t ? (const char *)t : "";
}

static sf_result map_sql_rc(int rc) {
    if (rc == SQLITE_CONSTRAINT) return SF_ERR_CONFLICT;
    if (rc == SQLITE_NOMEM) return SF_ERR_NOMEM;
    return SF_ERR_DB;
}

// Bind text, or NULL when v is NULL. Returns sqlite rc.
static int bind_text(sqlite3_stmt *st, int idx, const char *v) {
    if (!v) return sqlite3_bind_null(st, idx);
    return sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT);
}

// Run a non-query statement to completion. Returns SF_OK or a mapped
// error; *changes (if non-NULL) receives sqlite3_changes().
static sf_result exec_stmt(sf_store *s, sqlite3_stmt *st, int *changes) {
    int rc = sqlite3_step(st);
    sf_result r;
    if (rc == SQLITE_DONE) {
        if (changes) *changes = sqlite3_changes(s->db);
        r = SF_OK;
    } else {
        r = map_sql_rc(rc);
    }
    sqlite3_finalize(st);
    return r;
}

static sf_result exec_sql(sf_store *s, const char *sql) {
    char *err = NULL;
    int rc = sqlite3_exec(s->db, sql, NULL, NULL, &err);
    if (err) sqlite3_free(err);
    if (rc == SQLITE_OK) return SF_OK;
    return map_sql_rc(rc);
}

// ---- row fillers (column order fixed by the SELECT lists below) -------

static void fill_tenant(sqlite3_stmt *st, sf_tenant *t) {
    memset(t, 0, sizeof *t);
    t->id = sqlite3_column_int64(st, 0);
    set_str(t->slug, sizeof t->slug, col_text(st, 1));
    set_str(t->display_name, sizeof t->display_name, col_text(st, 2));
    set_str(t->state, sizeof t->state, col_text(st, 3));
    t->quota_bytes = sqlite3_column_int64(st, 4);
    t->quota_objects = sqlite3_column_int64(st, 5);
    t->quota_buckets = sqlite3_column_int64(st, 6);
    set_str(t->contact_note, sizeof t->contact_note, col_text(st, 7));
    set_str(t->created_at, sizeof t->created_at, col_text(st, 8));
    set_str(t->updated_at, sizeof t->updated_at, col_text(st, 9));
}

static void fill_login(sqlite3_stmt *st, sf_login *l) {
    char nowbuf[32];
    const char *locked_until;
    memset(l, 0, sizeof *l);
    l->id = sqlite3_column_int64(st, 0);
    l->tenant_id = sqlite3_column_int64(st, 1);
    set_str(l->username, sizeof l->username, col_text(st, 2));
    set_str(l->display_name, sizeof l->display_name, col_text(st, 3));
    set_str(l->role, sizeof l->role, col_text(st, 4));
    set_str(l->state, sizeof l->state, col_text(st, 5));
    if (sqlite3_column_type(st, 6) != SQLITE_NULL)
        set_str(l->last_login_at, sizeof l->last_login_at, col_text(st, 6));
    locked_until = (sqlite3_column_type(st, 7) != SQLITE_NULL)
                       ? col_text(st, 7) : "";
    sf_now_iso(nowbuf);
    l->locked = (locked_until[0] && strcmp(locked_until, nowbuf) > 0) ? 1 : 0;
    set_str(l->created_at, sizeof l->created_at, col_text(st, 8));
    set_str(l->updated_at, sizeof l->updated_at, col_text(st, 9));
}

static void fill_backend(sqlite3_stmt *st, sf_backend *b) {
    memset(b, 0, sizeof *b);
    b->id = sqlite3_column_int64(st, 0);
    set_str(b->name, sizeof b->name, col_text(st, 1));
    set_str(b->kind, sizeof b->kind, col_text(st, 2));
    b->config_json = dup_str(col_text(st, 3));
    set_str(b->secret_ref, sizeof b->secret_ref, col_text(st, 4));
    set_str(b->state, sizeof b->state, col_text(st, 5));
    set_str(b->created_at, sizeof b->created_at, col_text(st, 6));
    set_str(b->updated_at, sizeof b->updated_at, col_text(st, 7));
}

static void fill_bucket(sqlite3_stmt *st, sf_bucket *b) {
    memset(b, 0, sizeof *b);
    b->id = sqlite3_column_int64(st, 0);
    b->tenant_id = sqlite3_column_int64(st, 1);
    set_str(b->name, sizeof b->name, col_text(st, 2));
    b->backend_id = sqlite3_column_int64(st, 3);
    b->quota_bytes = sqlite3_column_int64(st, 4);
    b->object_count = sqlite3_column_int64(st, 5);
    b->total_bytes = sqlite3_column_int64(st, 6);
    set_str(b->created_at, sizeof b->created_at, col_text(st, 7));
    set_str(b->updated_at, sizeof b->updated_at, col_text(st, 8));
}

static void fill_object(sqlite3_stmt *st, sf_object *o) {
    const void *blob;
    int blen;
    memset(o, 0, sizeof *o);
    o->id = sqlite3_column_int64(st, 0);
    o->bucket_id = sqlite3_column_int64(st, 1);
    o->tenant_id = sqlite3_column_int64(st, 2);
    o->key = dup_str(col_text(st, 3));
    o->size_bytes = sqlite3_column_int64(st, 4);
    blob = sqlite3_column_blob(st, 5);
    blen = sqlite3_column_bytes(st, 5);
    if (blob && blen == 32) memcpy(o->sha256, blob, 32);
    set_str(o->content_type, sizeof o->content_type, col_text(st, 6));
    o->metadata_json = dup_str(col_text(st, 7));
    set_str(o->created_at, sizeof o->created_at, col_text(st, 8));
    set_str(o->updated_at, sizeof o->updated_at, col_text(st, 9));
}

static void fill_audit(sqlite3_stmt *st, sf_audit_entry *a) {
    memset(a, 0, sizeof *a);
    a->id = sqlite3_column_int64(st, 0);
    a->tenant_id = (sqlite3_column_type(st, 1) == SQLITE_NULL)
                       ? -1 : sqlite3_column_int64(st, 1);
    set_str(a->ts, sizeof a->ts, col_text(st, 2));
    set_str(a->actor_kind, sizeof a->actor_kind, col_text(st, 3));
    set_str(a->actor_ref, sizeof a->actor_ref, col_text(st, 4));
    set_str(a->action, sizeof a->action, col_text(st, 5));
    set_str(a->object_ref, sizeof a->object_ref, col_text(st, 6));
    set_str(a->result, sizeof a->result, col_text(st, 7));
    a->detail_json = dup_str(col_text(st, 8));
}

#define TENANT_COLS "id, slug, display_name, state, quota_bytes, quota_objects, quota_buckets, contact_note, created_at, updated_at"
#define LOGIN_SELECT "SELECT l.id, l.tenant_id, l.username, l.display_name, l.role, l.state, l.last_login_at, c.locked_until, l.created_at, l.updated_at FROM cs_logins l LEFT JOIN cs_credentials c ON c.login_id = l.id AND c.kind = 'password'"
#define BACKEND_COLS "id, name, kind, config_json, secret_ref, state, created_at, updated_at"
#define BUCKET_COLS "id, tenant_id, name, backend_id, quota_bytes, object_count, total_bytes, created_at, updated_at"
#define OBJECT_COLS "id, bucket_id, tenant_id, key, size_bytes, sha256, content_type, metadata_json, created_at, updated_at"
#define AUDIT_COLS "id, tenant_id, ts, actor_kind, actor_ref, action, object_ref, result, detail_json"

// Generic dynamic list driver: `fill` copies one row from the stmt.
typedef void (*sf_fill_fn)(sqlite3_stmt *st, void *row);

static sf_result run_list(sqlite3_stmt *st, size_t row_size, sf_fill_fn fill,
                          void **out_rows, size_t *out_count) {
    void *rows = NULL;
    size_t count = 0, cap = 0;
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        if (count == cap) {
            size_t ncap = cap ? cap * 2 : 16;
            void *nr = realloc(rows, ncap * row_size);
            if (!nr) { free(rows); sqlite3_finalize(st); return SF_ERR_NOMEM; }
            rows = nr; cap = ncap;
        }
        fill(st, (char *)rows + count * row_size);
        count++;
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) { free(rows); return map_sql_rc(rc); }
    *out_rows = rows;
    *out_count = count;
    return SF_OK;
}

static void fill_tenant_cb(sqlite3_stmt *st, void *row) { fill_tenant(st, (sf_tenant *)row); }
static void fill_login_cb(sqlite3_stmt *st, void *row) { fill_login(st, (sf_login *)row); }
static void fill_backend_cb(sqlite3_stmt *st, void *row) { fill_backend(st, (sf_backend *)row); }
static void fill_bucket_cb(sqlite3_stmt *st, void *row) { fill_bucket(st, (sf_bucket *)row); }
static void fill_object_cb(sqlite3_stmt *st, void *row) { fill_object(st, (sf_object *)row); }
static void fill_audit_cb(sqlite3_stmt *st, void *row) { fill_audit(st, (sf_audit_entry *)row); }

// ---- open / bootstrap --------------------------------------------------

// Schema v1 -> v2 upgrade (design §13.10): create the §13 tables, add
// cs_objects.blob_id, backfill one blob per distinct (tenant_id,
// sha256) among existing objects (backend taken from the referencing
// bucket; if several buckets on different backends hold the same
// digest, the lowest backend id wins — the service was never deployed
// at v1, so this is a correctness exercise, exercised by test), link
// the objects, and set refcounts from the links. Note: v1 object bytes
// live under key-derived adapter names; the backfill links rows only —
// byte migration is out of scope for a never-deployed v1.
static const char SF_UPGRADE_V1_V2[] =
    "CREATE TABLE IF NOT EXISTS cs_blobs ("
    " id INTEGER PRIMARY KEY,"
    " tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)"
    "   ON UPDATE CASCADE ON DELETE RESTRICT,"
    " sha256 BLOB NOT NULL,"
    " size_bytes INTEGER NOT NULL,"
    " backend_id INTEGER NOT NULL REFERENCES cs_backends (id)"
    "   ON UPDATE CASCADE ON DELETE RESTRICT,"
    " refcount INTEGER NOT NULL DEFAULT 0,"
    " state TEXT NOT NULL DEFAULT 'ok' CHECK (state IN ('ok', 'corrupt')),"
    " orphaned_at TEXT,"
    " created_at TEXT NOT NULL,"
    " last_verified_at TEXT,"
    " UNIQUE (tenant_id, sha256));"
    "CREATE INDEX IF NOT EXISTS cs_blobs_tenant ON cs_blobs (tenant_id, state);"
    "CREATE TABLE IF NOT EXISTS cs_collections ("
    " id INTEGER PRIMARY KEY,"
    " tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)"
    "   ON UPDATE CASCADE ON DELETE RESTRICT,"
    " parent_id INTEGER REFERENCES cs_collections (id)"
    "   ON UPDATE CASCADE ON DELETE RESTRICT,"
    " name TEXT NOT NULL, slug TEXT NOT NULL,"
    " created_at TEXT NOT NULL, updated_at TEXT NOT NULL,"
    " UNIQUE (tenant_id, slug));"
    "CREATE TABLE IF NOT EXISTS cs_content_items ("
    " id INTEGER PRIMARY KEY,"
    " tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)"
    "   ON UPDATE CASCADE ON DELETE RESTRICT,"
    " collection_id INTEGER REFERENCES cs_collections (id)"
    "   ON UPDATE CASCADE ON DELETE RESTRICT,"
    " slug TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',"
    " kind TEXT NOT NULL DEFAULT '',"
    " state TEXT NOT NULL DEFAULT 'draft'"
    "   CHECK (state IN ('draft', 'published', 'archived')),"
    " current_version_id INTEGER,"
    " metadata_json TEXT NOT NULL DEFAULT '{}',"
    " created_by TEXT NOT NULL DEFAULT '',"
    " created_at TEXT NOT NULL, updated_at TEXT NOT NULL,"
    " UNIQUE (tenant_id, slug));"
    "CREATE TABLE IF NOT EXISTS cs_content_versions ("
    " id INTEGER PRIMARY KEY,"
    " item_id INTEGER NOT NULL REFERENCES cs_content_items (id)"
    "   ON UPDATE CASCADE ON DELETE CASCADE,"
    " tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)"
    "   ON UPDATE CASCADE ON DELETE RESTRICT,"
    " version_no INTEGER NOT NULL,"
    " blob_id INTEGER NOT NULL REFERENCES cs_blobs (id)"
    "   ON UPDATE CASCADE ON DELETE RESTRICT,"
    " note TEXT NOT NULL DEFAULT '',"
    " metadata_json TEXT NOT NULL DEFAULT '{}',"
    " created_by TEXT NOT NULL DEFAULT '',"
    " created_at TEXT NOT NULL,"
    " UNIQUE (item_id, version_no));"
    "CREATE INDEX IF NOT EXISTS cs_content_versions_blob"
    " ON cs_content_versions (blob_id);"
    "CREATE TABLE IF NOT EXISTS cs_content_refs ("
    " id INTEGER PRIMARY KEY,"
    " tenant_id INTEGER NOT NULL REFERENCES cs_tenants (id)"
    "   ON UPDATE CASCADE ON DELETE RESTRICT,"
    " from_item_id INTEGER NOT NULL REFERENCES cs_content_items (id)"
    "   ON UPDATE CASCADE ON DELETE CASCADE,"
    " to_item_id INTEGER REFERENCES cs_content_items (id)"
    "   ON UPDATE CASCADE ON DELETE CASCADE,"
    " to_blob_id INTEGER REFERENCES cs_blobs (id)"
    "   ON UPDATE CASCADE ON DELETE RESTRICT,"
    " kind TEXT NOT NULL DEFAULT '',"
    " created_at TEXT NOT NULL,"
    " CHECK ((to_item_id IS NOT NULL AND to_blob_id IS NULL)"
    "     OR (to_item_id IS NULL AND to_blob_id IS NOT NULL)));"
    "CREATE INDEX IF NOT EXISTS cs_content_refs_blob"
    " ON cs_content_refs (to_blob_id);"
    "ALTER TABLE cs_objects ADD COLUMN blob_id INTEGER"
    " REFERENCES cs_blobs (id) ON UPDATE CASCADE ON DELETE RESTRICT;"
    "INSERT INTO cs_blobs (tenant_id, sha256, size_bytes, backend_id,"
    " refcount, state, orphaned_at, created_at, last_verified_at)"
    " SELECT o.tenant_id, o.sha256, MIN(o.size_bytes), MIN(b.backend_id),"
    " 0, 'ok', NULL, MIN(o.created_at), NULL"
    " FROM cs_objects o JOIN cs_buckets b ON b.id = o.bucket_id"
    " GROUP BY o.tenant_id, o.sha256;"
    "UPDATE cs_objects SET blob_id = (SELECT id FROM cs_blobs"
    " WHERE cs_blobs.tenant_id = cs_objects.tenant_id"
    " AND cs_blobs.sha256 = cs_objects.sha256);"
    "UPDATE cs_blobs SET refcount = (SELECT COUNT(*) FROM cs_objects"
    " WHERE cs_objects.blob_id = cs_blobs.id);"
    "UPDATE cs_meta SET value = '2' WHERE key = 'schema_version';";

static int store_schema_version(sf_store *s, char *out, size_t cap) {
    sqlite3_stmt *st = NULL;
    int found = 0;
    if (sqlite3_prepare_v2(s->db,
             "SELECT value FROM cs_meta WHERE key = 'schema_version'",
             -1, &st, NULL) == SQLITE_OK && st) {
        if (sqlite3_step(st) == SQLITE_ROW) {
            const char *v = col_text(st, 0);
            size_t n = strlen(v);
            if (n >= cap) n = cap - 1;
            memcpy(out, v, n);
            out[n] = '\0';
            found = 1;
        }
        sqlite3_finalize(st);
    }
    return found;
}

sf_store *sf_store_open(const char *db_path) {
    sf_store *s;
    char version[16] = "";

    if (!db_path || !db_path[0]) return NULL;
    s = (sf_store *)calloc(1, sizeof *s);
    if (!s) return NULL;
    if (sqlite3_open(db_path, &s->db) != SQLITE_OK) {
        if (s->db) sqlite3_close(s->db);
        free(s);
        return NULL;
    }
    sqlite3_busy_timeout(s->db, 5000);
    if (exec_sql(s, "PRAGMA foreign_keys = ON") != SF_OK) {
        sqlite3_close(s->db); free(s); return NULL;
    }

    if (!store_schema_version(s, version, sizeof version)) {
        // Empty (or table-less) DB: bootstrap from the embedded DDL,
        // then verify the version it claims.
        if (exec_sql(s, SF_DDL) != SF_OK ||
            !store_schema_version(s, version, sizeof version) ||
            strcmp(version, "2") != 0) {
            sqlite3_close(s->db); free(s); return NULL;
        }
        return s;
    }
    if (strcmp(version, "2") == 0) return s;
    if (strcmp(version, "1") == 0) {
        if (exec_sql(s, "BEGIN IMMEDIATE") != SF_OK ||
            exec_sql(s, SF_UPGRADE_V1_V2) != SF_OK ||
            exec_sql(s, "COMMIT") != SF_OK) {
            exec_sql(s, "ROLLBACK");
            sqlite3_close(s->db); free(s); return NULL;
        }
        if (!store_schema_version(s, version, sizeof version) ||
            strcmp(version, "2") != 0) {
            sqlite3_close(s->db); free(s); return NULL;
        }
        return s;
    }
    sqlite3_close(s->db); free(s); return NULL;
}

void sf_store_close(sf_store *s) {
    if (!s) return;
    if (s->db) sqlite3_close(s->db);
    free(s);
}

sqlite3 *sf_store_db(sf_store *s) { return s ? s->db : NULL; }

// ---- quotas --------------------------------------------------------------

void sf_tenant_effective_quota(const sf_tenant *t,
                               int64_t *bytes, int64_t *objects, int64_t *buckets) {
    if (!t) return;
    if (bytes)   *bytes   = (t->quota_bytes   == -1) ? SF_DEFAULT_QUOTA_BYTES   : t->quota_bytes;
    if (objects) *objects = (t->quota_objects == -1) ? SF_DEFAULT_QUOTA_OBJECTS : t->quota_objects;
    if (buckets) *buckets = (t->quota_buckets == -1) ? SF_DEFAULT_QUOTA_BUCKETS : t->quota_buckets;
}

// ---- Tenants ---------------------------------------------------------------

sf_result sf_store_create_tenant(sf_store *s, const char *slug,
                                 const char *display_name,
                                 int64_t quota_bytes, int64_t quota_objects,
                                 int64_t quota_buckets, const char *contact_note,
                                 sf_tenant *out) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t id;
    if (!s || !slug || !slug[0] || !display_name) return SF_ERR_VALIDATION;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(s->db,
            "INSERT INTO cs_tenants (slug, display_name, state, quota_bytes, quota_objects, quota_buckets, contact_note, created_at, updated_at) VALUES (?, ?, 'active', ?, ?, ?, ?, ?, ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, slug, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, display_name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, quota_bytes);
    sqlite3_bind_int64(st, 4, quota_objects);
    sqlite3_bind_int64(st, 5, quota_buckets);
    sqlite3_bind_text(st, 6, contact_note ? contact_note : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 7, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 8, now, -1, SQLITE_TRANSIENT);
    r = exec_stmt(s, st, NULL);
    if (r != SF_OK) return r;
    id = sqlite3_last_insert_rowid(s->db);
    if (out) return sf_store_get_tenant(s, id, out);
    return SF_OK;
}

static sf_result get_tenant_where(sf_store *s, const char *where,
                                  const char *text_key, int64_t id_key,
                                  sf_tenant *out) {
    sqlite3_stmt *st = NULL;
    char sql[256];
    sf_result r = SF_ERR_NOT_FOUND;
    if (!s || !out) return SF_ERR_VALIDATION;
    snprintf(sql, sizeof sql, "SELECT " TENANT_COLS " FROM cs_tenants WHERE %s", where);
    if (sqlite3_prepare_v2(s->db, sql, -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    if (text_key) sqlite3_bind_text(st, 1, text_key, -1, SQLITE_TRANSIENT);
    else sqlite3_bind_int64(st, 1, id_key);
    if (sqlite3_step(st) == SQLITE_ROW) { fill_tenant(st, out); r = SF_OK; }
    sqlite3_finalize(st);
    return r;
}

sf_result sf_store_get_tenant(sf_store *s, int64_t id, sf_tenant *out) {
    return get_tenant_where(s, "id = ?", NULL, id, out);
}

sf_result sf_store_get_tenant_by_slug(sf_store *s, const char *slug, sf_tenant *out) {
    if (!slug) return SF_ERR_VALIDATION;
    return get_tenant_where(s, "slug = ?", slug, 0, out);
}

sf_result sf_store_list_tenants(sf_store *s, int64_t cursor, int limit,
                                sf_tenant **out_rows, size_t *out_count) {
    sqlite3_stmt *st = NULL;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (sqlite3_prepare_v2(s->db,
            "SELECT " TENANT_COLS " FROM cs_tenants WHERE id > ? ORDER BY id ASC LIMIT ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, cursor);
    sqlite3_bind_int64(st, 2, limit <= 0 ? -1 : limit);
    return run_list(st, sizeof(sf_tenant), fill_tenant_cb,
                    (void **)out_rows, out_count);
}

sf_result sf_store_update_tenant(sf_store *s, int64_t id,
                                 const char *display_name,
                                 const char *state,
                                 const char *contact_note) {
    sf_tenant cur;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r = sf_store_get_tenant(s, id, &cur);
    int changes = 0;
    if (r != SF_OK) return r;
    if (state && strcmp(state, "active") != 0 && strcmp(state, "suspended") != 0 &&
        strcmp(state, "closed") != 0) return SF_ERR_VALIDATION;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(s->db,
            "UPDATE cs_tenants SET display_name = ?, state = ?, contact_note = ?, updated_at = ? WHERE id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, display_name ? display_name : cur.display_name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, state ? state : cur.state, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, contact_note ? contact_note : cur.contact_note, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 5, id);
    r = exec_stmt(s, st, &changes);
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

sf_result sf_store_set_tenant_quota(sf_store *s, int64_t id,
                                    int64_t quota_bytes, int64_t quota_objects,
                                    int64_t quota_buckets) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int changes = 0;
    if (!s) return SF_ERR_VALIDATION;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(s->db,
            "UPDATE cs_tenants SET quota_bytes = ?, quota_objects = ?, quota_buckets = ?, updated_at = ? WHERE id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, quota_bytes);
    sqlite3_bind_int64(st, 2, quota_objects);
    sqlite3_bind_int64(st, 3, quota_buckets);
    sqlite3_bind_text(st, 4, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 5, id);
    r = exec_stmt(s, st, &changes);
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

void sf_tenant_free_all(sf_tenant *rows, size_t count) {
    (void)count;
    free(rows);
}

// ---- Logins ------------------------------------------------------------------

sf_result sf_store_create_login(sf_store *s, int64_t tenant_id,
                                const char *username, const char *display_name,
                                const char *role, sf_login *out) {
    sf_tenant t;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t id;
    if (!s || !username || !username[0] || !role) return SF_ERR_VALIDATION;
    if (strcmp(role, "tenant_admin") != 0 && strcmp(role, "tenant_user") != 0)
        return SF_ERR_VALIDATION;
    r = sf_store_get_tenant(s, tenant_id, &t);
    if (r != SF_OK) return r;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(s->db,
            "INSERT INTO cs_logins (tenant_id, username, display_name, role, state, created_at, updated_at) VALUES (?, ?, ?, ?, 'active', ?, ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_text(st, 2, username, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, display_name ? display_name : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, role, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, now, -1, SQLITE_TRANSIENT);
    r = exec_stmt(s, st, NULL);
    if (r != SF_OK) return r;
    id = sqlite3_last_insert_rowid(s->db);
    if (out) return sf_store_get_login(s, tenant_id, id, out);
    return SF_OK;
}

sf_result sf_store_get_login(sf_store *s, int64_t tenant_id, int64_t login_id,
                             sf_login *out) {
    sqlite3_stmt *st = NULL;
    sf_result r = SF_ERR_NOT_FOUND;
    if (!s || !out) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(s->db,
            LOGIN_SELECT " WHERE l.tenant_id = ? AND l.id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, login_id);
    if (sqlite3_step(st) == SQLITE_ROW) { fill_login(st, out); r = SF_OK; }
    sqlite3_finalize(st);
    return r;
}

sf_result sf_store_list_logins(sf_store *s, int64_t tenant_id,
                               int64_t cursor, int limit,
                               sf_login **out_rows, size_t *out_count) {
    sqlite3_stmt *st = NULL;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (sqlite3_prepare_v2(s->db,
            LOGIN_SELECT " WHERE l.tenant_id = ? AND l.id > ? ORDER BY l.id ASC LIMIT ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, cursor);
    sqlite3_bind_int64(st, 3, limit <= 0 ? -1 : limit);
    return run_list(st, sizeof(sf_login), fill_login_cb,
                    (void **)out_rows, out_count);
}

sf_result sf_store_update_login(sf_store *s, int64_t tenant_id, int64_t login_id,
                                const char *display_name,
                                const char *role,
                                const char *state) {
    sf_login cur;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r = sf_store_get_login(s, tenant_id, login_id, &cur);
    int changes = 0;
    if (r != SF_OK) return r;
    if (role && strcmp(role, "tenant_admin") != 0 && strcmp(role, "tenant_user") != 0)
        return SF_ERR_VALIDATION;
    if (state && strcmp(state, "active") != 0 && strcmp(state, "disabled") != 0)
        return SF_ERR_VALIDATION;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(s->db,
            "UPDATE cs_logins SET display_name = ?, role = ?, state = ?, updated_at = ? WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, display_name ? display_name : cur.display_name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, role ? role : cur.role, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, state ? state : cur.state, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 5, tenant_id);
    sqlite3_bind_int64(st, 6, login_id);
    r = exec_stmt(s, st, &changes);
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

sf_result sf_store_delete_login(sf_store *s, int64_t tenant_id, int64_t login_id) {
    sqlite3_stmt *st = NULL;
    sf_result r;
    int changes = 0;
    if (!s) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(s->db,
            "DELETE FROM cs_logins WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, login_id);
    r = exec_stmt(s, st, &changes);
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

sf_result sf_store_count_active_admins(sf_store *s, int64_t tenant_id, int64_t *out) {
    sqlite3_stmt *st = NULL;
    sf_result r = SF_ERR_DB;
    if (!s || !out) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(s->db,
            "SELECT COUNT(*) FROM cs_logins WHERE tenant_id = ? AND role = 'tenant_admin' AND state = 'active'",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    if (sqlite3_step(st) == SQLITE_ROW) { *out = sqlite3_column_int64(st, 0); r = SF_OK; }
    sqlite3_finalize(st);
    return r;
}

void sf_login_free_all(sf_login *rows, size_t count) {
    (void)count;
    free(rows);
}

// ---- Backends ------------------------------------------------------------------

sf_result sf_store_create_backend(sf_store *s, const char *name, const char *kind,
                                  const char *config_json, const char *secret_ref,
                                  sf_backend *out) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t id;
    if (!s || !name || !name[0] || !kind) return SF_ERR_VALIDATION;
    if (strcmp(kind, "filesystem") != 0 && strcmp(kind, "s3") != 0)
        return SF_ERR_VALIDATION;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(s->db,
            "INSERT INTO cs_backends (name, kind, config_json, secret_ref, state, created_at, updated_at) VALUES (?, ?, ?, ?, 'active', ?, ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, kind, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, config_json ? config_json : "{}", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, secret_ref ? secret_ref : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, now, -1, SQLITE_TRANSIENT);
    r = exec_stmt(s, st, NULL);
    if (r != SF_OK) return r;
    id = sqlite3_last_insert_rowid(s->db);
    if (out) return sf_store_get_backend(s, id, out);
    return SF_OK;
}

sf_result sf_store_get_backend(sf_store *s, int64_t id, sf_backend *out) {
    sqlite3_stmt *st = NULL;
    sf_result r = SF_ERR_NOT_FOUND;
    if (!s || !out) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(s->db,
            "SELECT " BACKEND_COLS " FROM cs_backends WHERE id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, id);
    if (sqlite3_step(st) == SQLITE_ROW) { fill_backend(st, out); r = SF_OK; }
    sqlite3_finalize(st);
    if (r != SF_OK && out) { out->config_json = NULL; }
    return r;
}

sf_result sf_store_list_backends(sf_store *s, sf_backend **out_rows, size_t *out_count) {
    sqlite3_stmt *st = NULL;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (sqlite3_prepare_v2(s->db,
            "SELECT " BACKEND_COLS " FROM cs_backends ORDER BY id ASC",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    return run_list(st, sizeof(sf_backend), fill_backend_cb,
                    (void **)out_rows, out_count);
}

sf_result sf_store_update_backend(sf_store *s, int64_t id,
                                  const char *config_json,
                                  const char *state) {
    sf_backend cur;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int changes = 0;
    memset(&cur, 0, sizeof cur);
    r = sf_store_get_backend(s, id, &cur);
    if (r != SF_OK) return r;
    if (state && strcmp(state, "active") != 0 && strcmp(state, "disabled") != 0) {
        sf_backend_free(&cur);
        return SF_ERR_VALIDATION;
    }
    sf_now_iso(now);
    if (sqlite3_prepare_v2(s->db,
            "UPDATE cs_backends SET config_json = ?, state = ?, updated_at = ? WHERE id = ?",
            -1, &st, NULL) != SQLITE_OK) { sf_backend_free(&cur); return SF_ERR_DB; }
    sqlite3_bind_text(st, 1, config_json ? config_json : (cur.config_json ? cur.config_json : "{}"), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, state ? state : cur.state, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 4, id);
    r = exec_stmt(s, st, &changes);
    sf_backend_free(&cur);
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

void sf_backend_free(sf_backend *b) {
    if (!b) return;
    free(b->config_json);
    b->config_json = NULL;
}

void sf_backend_free_all(sf_backend *rows, size_t count) {
    size_t i;
    if (!rows) return;
    for (i = 0; i < count; i++) free(rows[i].config_json);
    free(rows);
}

// ---- Buckets ---------------------------------------------------------------------

sf_result sf_store_create_bucket(sf_store *s, int64_t tenant_id, const char *name,
                                 int64_t backend_id, int64_t quota_bytes,
                                 sf_bucket *out) {
    sf_tenant t;
    sf_backend b;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t id;
    if (!s || !name || !name[0]) return SF_ERR_VALIDATION;
    r = sf_store_get_tenant(s, tenant_id, &t);
    if (r != SF_OK) return r;
    memset(&b, 0, sizeof b);
    r = sf_store_get_backend(s, backend_id, &b);
    if (r != SF_OK) return r;
    sf_backend_free(&b);
    sf_now_iso(now);
    if (sqlite3_prepare_v2(s->db,
            "INSERT INTO cs_buckets (tenant_id, name, backend_id, quota_bytes, object_count, total_bytes, created_at, updated_at) VALUES (?, ?, ?, ?, 0, 0, ?, ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_text(st, 2, name, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, backend_id);
    sqlite3_bind_int64(st, 4, quota_bytes);
    sqlite3_bind_text(st, 5, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, now, -1, SQLITE_TRANSIENT);
    r = exec_stmt(s, st, NULL);
    if (r != SF_OK) return r;
    id = sqlite3_last_insert_rowid(s->db);
    if (out) return sf_store_get_bucket_by_id(s, tenant_id, id, out);
    return SF_OK;
}

static sf_result get_bucket_where(sf_store *s, int64_t tenant_id,
                                  const char *where, const char *name_key,
                                  int64_t id_key, sf_bucket *out) {
    sqlite3_stmt *st = NULL;
    char sql[256];
    sf_result r = SF_ERR_NOT_FOUND;
    if (!s || !out) return SF_ERR_VALIDATION;
    snprintf(sql, sizeof sql,
             "SELECT " BUCKET_COLS " FROM cs_buckets WHERE tenant_id = ? AND %s", where);
    if (sqlite3_prepare_v2(s->db, sql, -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    if (name_key) sqlite3_bind_text(st, 2, name_key, -1, SQLITE_TRANSIENT);
    else sqlite3_bind_int64(st, 2, id_key);
    if (sqlite3_step(st) == SQLITE_ROW) { fill_bucket(st, out); r = SF_OK; }
    sqlite3_finalize(st);
    return r;
}

sf_result sf_store_get_bucket_by_name(sf_store *s, int64_t tenant_id,
                                      const char *name, sf_bucket *out) {
    if (!name) return SF_ERR_VALIDATION;
    return get_bucket_where(s, tenant_id, "name = ?", name, 0, out);
}

sf_result sf_store_get_bucket_by_id(sf_store *s, int64_t tenant_id,
                                    int64_t bucket_id, sf_bucket *out) {
    return get_bucket_where(s, tenant_id, "id = ?", NULL, bucket_id, out);
}

sf_result sf_store_list_buckets(sf_store *s, int64_t tenant_id,
                                int64_t cursor, int limit,
                                sf_bucket **out_rows, size_t *out_count) {
    sqlite3_stmt *st = NULL;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (sqlite3_prepare_v2(s->db,
            "SELECT " BUCKET_COLS " FROM cs_buckets WHERE tenant_id = ? AND id > ? ORDER BY id ASC LIMIT ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, cursor);
    sqlite3_bind_int64(st, 3, limit <= 0 ? -1 : limit);
    return run_list(st, sizeof(sf_bucket), fill_bucket_cb,
                    (void **)out_rows, out_count);
}

sf_result sf_store_update_bucket_quota(sf_store *s, int64_t tenant_id,
                                       int64_t bucket_id, int64_t quota_bytes) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int changes = 0;
    if (!s) return SF_ERR_VALIDATION;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(s->db,
            "UPDATE cs_buckets SET quota_bytes = ?, updated_at = ? WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, quota_bytes);
    sqlite3_bind_text(st, 2, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, tenant_id);
    sqlite3_bind_int64(st, 4, bucket_id);
    r = exec_stmt(s, st, &changes);
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

sf_result sf_store_delete_bucket(sf_store *s, int64_t tenant_id, int64_t bucket_id) {
    sqlite3_stmt *st = NULL;
    sf_result r;
    int changes = 0;
    if (!s) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(s->db,
            "DELETE FROM cs_buckets WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, bucket_id);
    r = exec_stmt(s, st, &changes);
    // FK RESTRICT (objects still present) maps to SF_ERR_CONFLICT via
    // map_sql_rc inside exec_stmt.
    if (r == SF_OK && changes == 0) return SF_ERR_NOT_FOUND;
    return r;
}

void sf_bucket_free_all(sf_bucket *rows, size_t count) {
    (void)count;
    free(rows);
}

// ---- Objects ------------------------------------------------------------------------

sf_result sf_store_put_object(sf_store *s, int64_t tenant_id, int64_t bucket_id,
                              const char *key, int64_t size_bytes,
                              const uint8_t sha256[32], const char *content_type,
                              const char *metadata_json, sf_object *out) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t existing_id = -1, existing_size = 0;
    int have_bucket = 0;

    if (!s || !key || !key[0] || size_bytes < 0) return SF_ERR_VALIDATION;
    if (!content_type) content_type = "application/octet-stream";
    if (!metadata_json) metadata_json = "{}";
    sf_now_iso(now);

    r = exec_sql(s, "BEGIN IMMEDIATE");
    if (r != SF_OK) return r;

    // Bucket must exist in this tenant's scope.
    if (sqlite3_prepare_v2(s->db,
            "SELECT id FROM cs_buckets WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, bucket_id);
    if (sqlite3_step(st) == SQLITE_ROW) have_bucket = 1;
    sqlite3_finalize(st); st = NULL;
    if (!have_bucket) { exec_sql(s, "ROLLBACK"); return SF_ERR_NOT_FOUND; }

    // Existing row (replace case)?
    if (sqlite3_prepare_v2(s->db,
            "SELECT id, size_bytes FROM cs_objects WHERE tenant_id = ? AND bucket_id = ? AND key = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, bucket_id);
    sqlite3_bind_text(st, 3, key, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) {
        existing_id = sqlite3_column_int64(st, 0);
        existing_size = sqlite3_column_int64(st, 1);
    }
    sqlite3_finalize(st); st = NULL;

    if (existing_id >= 0) {
        if (sqlite3_prepare_v2(s->db,
                "UPDATE cs_objects SET size_bytes = ?, sha256 = ?, content_type = ?, metadata_json = ?, updated_at = ? WHERE id = ?",
                -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
        sqlite3_bind_int64(st, 1, size_bytes);
        if (sha256) sqlite3_bind_blob(st, 2, sha256, 32, SQLITE_TRANSIENT);
        else sqlite3_bind_zeroblob(st, 2, 32);
        sqlite3_bind_text(st, 3, content_type, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 4, metadata_json, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 5, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 6, existing_id);
        r = exec_stmt(s, st, NULL); st = NULL;
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
        if (sqlite3_prepare_v2(s->db,
                "UPDATE cs_buckets SET total_bytes = total_bytes + ?, updated_at = ? WHERE tenant_id = ? AND id = ?",
                -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
        sqlite3_bind_int64(st, 1, size_bytes - existing_size);
        sqlite3_bind_text(st, 2, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 3, tenant_id);
        sqlite3_bind_int64(st, 4, bucket_id);
        r = exec_stmt(s, st, NULL); st = NULL;
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    } else {
        if (sqlite3_prepare_v2(s->db,
                "INSERT INTO cs_objects (bucket_id, tenant_id, key, size_bytes, sha256, content_type, metadata_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
        sqlite3_bind_int64(st, 1, bucket_id);
        sqlite3_bind_int64(st, 2, tenant_id);
        sqlite3_bind_text(st, 3, key, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 4, size_bytes);
        if (sha256) sqlite3_bind_blob(st, 5, sha256, 32, SQLITE_TRANSIENT);
        else sqlite3_bind_zeroblob(st, 5, 32);
        sqlite3_bind_text(st, 6, content_type, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 7, metadata_json, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 8, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 9, now, -1, SQLITE_TRANSIENT);
        r = exec_stmt(s, st, NULL); st = NULL;
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
        if (sqlite3_prepare_v2(s->db,
                "UPDATE cs_buckets SET object_count = object_count + 1, total_bytes = total_bytes + ?, updated_at = ? WHERE tenant_id = ? AND id = ?",
                -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
        sqlite3_bind_int64(st, 1, size_bytes);
        sqlite3_bind_text(st, 2, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 3, tenant_id);
        sqlite3_bind_int64(st, 4, bucket_id);
        r = exec_stmt(s, st, NULL); st = NULL;
        if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    }

    r = exec_sql(s, "COMMIT");
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }
    if (out) return sf_store_get_object(s, tenant_id, bucket_id, key, out);
    return SF_OK;
}

sf_result sf_store_get_object(sf_store *s, int64_t tenant_id, int64_t bucket_id,
                              const char *key, sf_object *out) {
    sqlite3_stmt *st = NULL;
    sf_result r = SF_ERR_NOT_FOUND;
    if (!s || !key || !out) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(s->db,
            "SELECT " OBJECT_COLS " FROM cs_objects WHERE tenant_id = ? AND bucket_id = ? AND key = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, bucket_id);
    sqlite3_bind_text(st, 3, key, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) { fill_object(st, out); r = SF_OK; }
    sqlite3_finalize(st);
    if (r != SF_OK) { out->key = NULL; out->metadata_json = NULL; }
    return r;
}

sf_result sf_store_list_objects(sf_store *s, int64_t tenant_id, int64_t bucket_id,
                                const char *prefix, int64_t cursor, int limit,
                                sf_object **out_rows, size_t *out_count) {
    sqlite3_stmt *st = NULL;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (prefix && prefix[0]) {
        // substr() prefix match: LIKE wildcards in the prefix stay literal.
        if (sqlite3_prepare_v2(s->db,
                "SELECT " OBJECT_COLS " FROM cs_objects WHERE tenant_id = ? AND bucket_id = ? AND id > ? AND substr(key, 1, ?) = ? ORDER BY id ASC LIMIT ?",
                -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
        sqlite3_bind_int64(st, 1, tenant_id);
        sqlite3_bind_int64(st, 2, bucket_id);
        sqlite3_bind_int64(st, 3, cursor);
        sqlite3_bind_int64(st, 4, (int64_t)strlen(prefix));
        sqlite3_bind_text(st, 5, prefix, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 6, limit <= 0 ? -1 : limit);
    } else {
        if (sqlite3_prepare_v2(s->db,
                "SELECT " OBJECT_COLS " FROM cs_objects WHERE tenant_id = ? AND bucket_id = ? AND id > ? ORDER BY id ASC LIMIT ?",
                -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
        sqlite3_bind_int64(st, 1, tenant_id);
        sqlite3_bind_int64(st, 2, bucket_id);
        sqlite3_bind_int64(st, 3, cursor);
        sqlite3_bind_int64(st, 4, limit <= 0 ? -1 : limit);
    }
    return run_list(st, sizeof(sf_object), fill_object_cb,
                    (void **)out_rows, out_count);
}

sf_result sf_store_delete_object(sf_store *s, int64_t tenant_id, int64_t bucket_id,
                                 const char *key) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    int64_t size = 0;
    int found = 0;

    if (!s || !key) return SF_ERR_VALIDATION;
    sf_now_iso(now);
    r = exec_sql(s, "BEGIN IMMEDIATE");
    if (r != SF_OK) return r;

    if (sqlite3_prepare_v2(s->db,
            "SELECT size_bytes FROM cs_objects WHERE tenant_id = ? AND bucket_id = ? AND key = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, bucket_id);
    sqlite3_bind_text(st, 3, key, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) { found = 1; size = sqlite3_column_int64(st, 0); }
    sqlite3_finalize(st); st = NULL;
    if (!found) { exec_sql(s, "ROLLBACK"); return SF_ERR_NOT_FOUND; }

    if (sqlite3_prepare_v2(s->db,
            "DELETE FROM cs_objects WHERE tenant_id = ? AND bucket_id = ? AND key = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, bucket_id);
    sqlite3_bind_text(st, 3, key, -1, SQLITE_TRANSIENT);
    r = exec_stmt(s, st, NULL); st = NULL;
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }

    if (sqlite3_prepare_v2(s->db,
            "UPDATE cs_buckets SET object_count = object_count - 1, total_bytes = total_bytes - ?, updated_at = ? WHERE tenant_id = ? AND id = ?",
            -1, &st, NULL) != SQLITE_OK) { exec_sql(s, "ROLLBACK"); return SF_ERR_DB; }
    sqlite3_bind_int64(st, 1, size);
    sqlite3_bind_text(st, 2, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, tenant_id);
    sqlite3_bind_int64(st, 4, bucket_id);
    r = exec_stmt(s, st, NULL); st = NULL;
    if (r != SF_OK) { exec_sql(s, "ROLLBACK"); return r; }

    return exec_sql(s, "COMMIT");
}

void sf_object_free(sf_object *o) {
    if (!o) return;
    free(o->key);
    free(o->metadata_json);
    o->key = NULL;
    o->metadata_json = NULL;
}

void sf_object_free_all(sf_object *rows, size_t count) {
    size_t i;
    if (!rows) return;
    for (i = 0; i < count; i++) {
        free(rows[i].key);
        free(rows[i].metadata_json);
    }
    free(rows);
}

// ---- Usage -----------------------------------------------------------------------------

sf_result sf_store_tenant_usage(sf_store *s, int64_t tenant_id,
                                int64_t *total_bytes, int64_t *total_objects,
                                int64_t *bucket_count_rows) {
    sf_tenant t;
    sqlite3_stmt *st = NULL;
    sf_result r;
    if (!s || !total_bytes || !total_objects || !bucket_count_rows)
        return SF_ERR_VALIDATION;
    r = sf_store_get_tenant(s, tenant_id, &t);
    if (r != SF_OK) return r;
    if (sqlite3_prepare_v2(s->db,
            "SELECT COALESCE(SUM(total_bytes), 0), COALESCE(SUM(object_count), 0), COUNT(*) FROM cs_buckets WHERE tenant_id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    r = SF_ERR_DB;
    if (sqlite3_step(st) == SQLITE_ROW) {
        *total_bytes = sqlite3_column_int64(st, 0);
        *total_objects = sqlite3_column_int64(st, 1);
        *bucket_count_rows = sqlite3_column_int64(st, 2);
        r = SF_OK;
    }
    sqlite3_finalize(st);
    return r;
}

// ---- Audit ---------------------------------------------------------------------------------

sf_result sf_store_audit(sf_store *s, int64_t tenant_id,
                         const char *actor_kind, const char *actor_ref,
                         const char *action, const char *object_ref,
                         const char *result, const char *detail_json,
                         const char *ip) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;
    if (!s || !actor_kind || !action || !result) return SF_ERR_VALIDATION;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(s->db,
            "INSERT INTO cs_audit_log (ts, tenant_id, actor_kind, actor_ref, action, object_ref, result, detail_json, ip) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
    if (tenant_id < 0) sqlite3_bind_null(st, 2);
    else sqlite3_bind_int64(st, 2, tenant_id);
    sqlite3_bind_text(st, 3, actor_kind, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, actor_ref ? actor_ref : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, action, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, object_ref ? object_ref : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 7, result, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 8, detail_json ? detail_json : "{}", -1, SQLITE_TRANSIENT);
    bind_text(st, 9, ip);
    r = exec_stmt(s, st, NULL);
    return r;
}

sf_result sf_store_list_audit(sf_store *s, int64_t tenant_id,
                              const char *action_filter,
                              int64_t cursor, int limit,
                              sf_audit_entry **out_rows, size_t *out_count) {
    sqlite3_stmt *st = NULL;
    char sql[640];
    int idx = 1;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    snprintf(sql, sizeof sql,
             "SELECT " AUDIT_COLS " FROM cs_audit_log WHERE id > ?%s%s ORDER BY id ASC LIMIT ?",
             tenant_id >= 0 ? " AND tenant_id = ?" : "",
             action_filter ? " AND action = ?" : "");
    if (sqlite3_prepare_v2(s->db, sql, -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, idx++, cursor);
    if (tenant_id >= 0) sqlite3_bind_int64(st, idx++, tenant_id);
    if (action_filter) sqlite3_bind_text(st, idx++, action_filter, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, idx, limit <= 0 ? -1 : limit);
    return run_list(st, sizeof(sf_audit_entry), fill_audit_cb,
                    (void **)out_rows, out_count);
}

void sf_audit_free_all(sf_audit_entry *rows, size_t count) {
    size_t i;
    if (!rows) return;
    for (i = 0; i < count; i++) free(rows[i].detail_json);
    free(rows);
}
