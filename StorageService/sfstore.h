// sfstore.h — the service store (cloud.db) and every query over it.
// Design record 03 §3.2 wall 2: there is NO unscoped query for
// tenant-owned data. Every function over buckets, objects, logins,
// tokens, resets, or audit takes the owning tenant's id (or, for the
// explicitly-named *_for_operator functions, is operator-only by name)
// and every statement filters on it. A scoped lookup that misses is
// SF_ERR_NOT_FOUND whether the row is absent or belongs to another
// tenant — the two are indistinguishable by design.
#ifndef SFSTORE_H
#define SFSTORE_H

#include "sfcommon.h"

typedef struct sf_store sf_store;

// Open (creating if absent) the store at `db_path` and bootstrap the
// schema from schema_cloud.sql semantics (embedded DDL, versioned by
// cs_meta.schema_version). Foreign keys ON. Returns NULL on failure.
sf_store *sf_store_open(const char *db_path);
void      sf_store_close(sf_store *s);

// Underlying handle for the few places (schema tests) that need it.
// Route/auth code must use the scoped functions below, never raw SQL.
struct sqlite3;
struct sqlite3 *sf_store_db(sf_store *s);

// ---- Row types -------------------------------------------------------

typedef struct {
    int64_t id;
    char slug[65];
    char display_name[129];
    char state[16];              // active | suspended | closed
    int64_t quota_bytes;         // -1 = default
    int64_t quota_objects;       // -1 = default
    int64_t quota_buckets;       // -1 = default
    char contact_note[257];
    sf_time created_at, updated_at;
} sf_tenant;

typedef struct {
    int64_t id;
    int64_t tenant_id;
    char username[65];
    char display_name[129];
    char role[16];               // tenant_admin | tenant_user
    char state[16];              // active | disabled
    sf_time last_login_at;       // "" when never
    int     locked;              // 1 when a lock is in force now
    sf_time created_at, updated_at;
} sf_login;

typedef struct {
    int64_t id;
    char name[129];
    char kind[16];               // filesystem | s3
    char *config_json;           // owned; non-secret fields only
    char secret_ref[129];        // env var NAME or ""
    char state[16];              // active | disabled
    sf_time created_at, updated_at;
} sf_backend;

typedef struct {
    int64_t id;
    int64_t tenant_id;
    char name[129];
    int64_t backend_id;
    int64_t quota_bytes;         // -1 = none
    int64_t object_count;
    int64_t total_bytes;
    sf_time created_at, updated_at;
} sf_bucket;

typedef struct {
    int64_t id;
    int64_t bucket_id;
    int64_t tenant_id;
    char *key;                   // owned
    int64_t size_bytes;
    uint8_t sha256[32];
    char content_type[129];
    char *metadata_json;         // owned; "{}" when none
    sf_time created_at, updated_at;
} sf_object;

typedef struct {
    int64_t id;
    int64_t tenant_id;           // -1 = operator scope
    char ts[32];
    char actor_kind[16];         // operator | login | system
    char actor_ref[129];
    char action[65];
    char object_ref[257];
    char result[16];             // ok | denied | error
    char *detail_json;           // owned; figures/refs only, never secrets
} sf_audit_entry;

// Effective quota defaults (design §7.4).
#define SF_DEFAULT_QUOTA_BYTES   10737418240LL   // 10 GiB
#define SF_DEFAULT_QUOTA_OBJECTS 100000LL
#define SF_DEFAULT_QUOTA_BUCKETS 100LL
#define SF_MAX_OBJECT_BYTES      268435456LL     // 256 MiB
void sf_tenant_effective_quota(const sf_tenant *t,
                               int64_t *bytes, int64_t *objects, int64_t *buckets);

// ---- Tenants ---------------------------------------------------------
// Operator-scope by nature (tenants are the scope boundary itself).
sf_result sf_store_create_tenant(sf_store *s, const char *slug,
                                 const char *display_name,
                                 int64_t quota_bytes, int64_t quota_objects,
                                 int64_t quota_buckets, const char *contact_note,
                                 sf_tenant *out);
sf_result sf_store_get_tenant(sf_store *s, int64_t id, sf_tenant *out);
sf_result sf_store_get_tenant_by_slug(sf_store *s, const char *slug, sf_tenant *out);
// limit<=0 = no limit; cursor = last id seen (0 = start). Fills up to
// `cap` rows; *out_count set. Rows are caller-freed via sf_tenant_free_all.
sf_result sf_store_list_tenants(sf_store *s, int64_t cursor, int limit,
                                sf_tenant **out_rows, size_t *out_count);
sf_result sf_store_update_tenant(sf_store *s, int64_t id,
                                 const char *display_name /*NULL=keep*/,
                                 const char *state /*NULL=keep*/,
                                 const char *contact_note /*NULL=keep*/);
sf_result sf_store_set_tenant_quota(sf_store *s, int64_t id,
                                    int64_t quota_bytes, int64_t quota_objects,
                                    int64_t quota_buckets);
void sf_tenant_free_all(sf_tenant *rows, size_t count);

// ---- Logins (tenant-scoped) ------------------------------------------
sf_result sf_store_create_login(sf_store *s, int64_t tenant_id,
                                const char *username, const char *display_name,
                                const char *role, sf_login *out);
sf_result sf_store_get_login(sf_store *s, int64_t tenant_id, int64_t login_id,
                             sf_login *out);
sf_result sf_store_list_logins(sf_store *s, int64_t tenant_id,
                               int64_t cursor, int limit,
                               sf_login **out_rows, size_t *out_count);
sf_result sf_store_update_login(sf_store *s, int64_t tenant_id, int64_t login_id,
                                const char *display_name /*NULL=keep*/,
                                const char *role /*NULL=keep*/,
                                const char *state /*NULL=keep*/);
sf_result sf_store_delete_login(sf_store *s, int64_t tenant_id, int64_t login_id);
sf_result sf_store_count_active_admins(sf_store *s, int64_t tenant_id, int64_t *out);
void sf_login_free_all(sf_login *rows, size_t count);

// ---- Backends (operator-scope by nature) ------------------------------
sf_result sf_store_create_backend(sf_store *s, const char *name, const char *kind,
                                  const char *config_json, const char *secret_ref,
                                  sf_backend *out);
sf_result sf_store_get_backend(sf_store *s, int64_t id, sf_backend *out);
sf_result sf_store_list_backends(sf_store *s, sf_backend **out_rows, size_t *out_count);
sf_result sf_store_update_backend(sf_store *s, int64_t id,
                                  const char *config_json /*NULL=keep*/,
                                  const char *state /*NULL=keep*/);
void sf_backend_free(sf_backend *b);
void sf_backend_free_all(sf_backend *rows, size_t count);

// ---- Buckets (tenant-scoped) ------------------------------------------
sf_result sf_store_create_bucket(sf_store *s, int64_t tenant_id, const char *name,
                                 int64_t backend_id, int64_t quota_bytes,
                                 sf_bucket *out);
sf_result sf_store_get_bucket_by_name(sf_store *s, int64_t tenant_id,
                                      const char *name, sf_bucket *out);
sf_result sf_store_get_bucket_by_id(sf_store *s, int64_t tenant_id,
                                    int64_t bucket_id, sf_bucket *out);
sf_result sf_store_list_buckets(sf_store *s, int64_t tenant_id,
                                int64_t cursor, int limit,
                                sf_bucket **out_rows, size_t *out_count);
sf_result sf_store_update_bucket_quota(sf_store *s, int64_t tenant_id,
                                       int64_t bucket_id, int64_t quota_bytes);
sf_result sf_store_delete_bucket(sf_store *s, int64_t tenant_id, int64_t bucket_id);
void sf_bucket_free_all(sf_bucket *rows, size_t count);

// ---- Objects (tenant-scoped) ------------------------------------------
// put: inserts or replaces the row AND adjusts bucket counters in the
// same transaction. The caller writes bytes via the adapter first and
// compensates with adapter delete when this returns non-OK (§7.1).
sf_result sf_store_put_object(sf_store *s, int64_t tenant_id, int64_t bucket_id,
                              const char *key, int64_t size_bytes,
                              const uint8_t sha256[32], const char *content_type,
                              const char *metadata_json, sf_object *out);
sf_result sf_store_get_object(sf_store *s, int64_t tenant_id, int64_t bucket_id,
                              const char *key, sf_object *out);
sf_result sf_store_list_objects(sf_store *s, int64_t tenant_id, int64_t bucket_id,
                                const char *prefix, int64_t cursor, int limit,
                                sf_object **out_rows, size_t *out_count);
sf_result sf_store_delete_object(sf_store *s, int64_t tenant_id, int64_t bucket_id,
                                 const char *key);
void sf_object_free(sf_object *o);
void sf_object_free_all(sf_object *rows, size_t count);

// Usage: tenant totals derived from bucket counters (the books truth).
sf_result sf_store_tenant_usage(sf_store *s, int64_t tenant_id,
                                int64_t *total_bytes, int64_t *total_objects,
                                int64_t *bucket_count_rows);

// ---- Audit (append + tenant-scoped read) -------------------------------
sf_result sf_store_audit(sf_store *s, int64_t tenant_id /*-1 operator*/,
                         const char *actor_kind, const char *actor_ref,
                         const char *action, const char *object_ref,
                         const char *result, const char *detail_json,
                         const char *ip);
sf_result sf_store_list_audit(sf_store *s, int64_t tenant_id /*-1 = all (operator)*/,
                              const char *action_filter /*NULL=any*/,
                              int64_t cursor, int limit,
                              sf_audit_entry **out_rows, size_t *out_count);
void sf_audit_free_all(sf_audit_entry *rows, size_t count);

#endif // SFSTORE_H
