// sfcms.h — the CMS content layer store (design record 03 §13.5).
// NEW header (SF-T12i): the frozen headers are unchanged; CMS store
// functions live here, mirroring sfblob.h's style.
//
// Model: collections are the tenant's structure tree; content items
// carry append-only versions (cs_content_versions) whose payloads are
// blob references; refs link an item to exactly one of another item
// or a blob. Every function is tenant-scoped (§3.2 wall 2): a scoped
// miss is SF_ERR_NOT_FOUND whether the row is absent or belongs to
// another tenant.
//
// Transactions: any operation that creates or drops a blob reference
// does so in the SAME transaction as the reference row itself —
// item creation (first version), item deletion (all versions + refs),
// and ref deletion here; version appends and ref creation go through
// the sfblob attach primitives (sf_blob_attach_version /
// sf_blob_attach_content_ref), which are that transaction for their
// reference kind. cs_blobs.refcount is never adjusted outside one.
#ifndef SFCMS_H
#define SFCMS_H

#include "sfcommon.h"
#include "sfstore.h"
#include "sfblob.h"

typedef struct {
    int64_t id;
    int64_t tenant_id;
    int64_t parent_id;           // -1 = root
    char name[257];
    char slug[129];
    sf_time created_at, updated_at;
} sf_cms_collection;

typedef struct {
    int64_t id;
    int64_t tenant_id;
    int64_t collection_id;       // -1 = root (no collection)
    char slug[129];
    char *title;                 // owned
    char kind[65];
    char state[16];              // draft | published | archived
    char *metadata_json;         // owned; "{}" when none
    char *created_by;            // owned; opaque actor ref (login:<id>)
    sf_time created_at, updated_at;
    // Current version summary (-1 / "" when the item has no version;
    // items are always created with version 1, so this is defensive).
    int64_t current_version_id;  // -1 = none
    int64_t current_version_no;  // -1 = none
    int64_t current_blob_id;     // -1 = none
    char current_sha256_hex[65];
    int64_t current_size_bytes;
} sf_cms_item;

typedef struct {
    int64_t id;
    int64_t item_id;
    int64_t tenant_id;
    int64_t version_no;
    int64_t blob_id;
    char sha256_hex[65];
    int64_t size_bytes;
    char *note;                  // owned
    char *metadata_json;         // owned
    char *created_by;            // owned
    sf_time created_at;
} sf_cms_version;

typedef struct {
    int64_t id;
    int64_t tenant_id;
    int64_t from_item_id;
    int64_t to_item_id;          // -1 = none (exactly one target is set)
    int64_t to_blob_id;          // -1 = none
    char kind[65];
    sf_time created_at;
} sf_cms_ref;

void sf_cms_item_free(sf_cms_item *it);
void sf_cms_item_free_all(sf_cms_item *rows, size_t count);
void sf_cms_version_free(sf_cms_version *v);
void sf_cms_version_free_all(sf_cms_version *rows, size_t count);
void sf_cms_collection_free_all(sf_cms_collection *rows, size_t count);
void sf_cms_ref_free_all(sf_cms_ref *rows, size_t count);

// ---- Collections -------------------------------------------------------
sf_result sf_cms_create_collection(sf_store *s, int64_t tenant_id,
                                   int64_t parent_id /*-1 = root*/,
                                   const char *name, const char *slug,
                                   sf_cms_collection *out);
sf_result sf_cms_get_collection(sf_store *s, int64_t tenant_id,
                                int64_t collection_id,
                                sf_cms_collection *out);
sf_result sf_cms_list_collections(sf_store *s, int64_t tenant_id,
                                  int64_t cursor, int limit,
                                  sf_cms_collection **out_rows,
                                  size_t *out_count);
// name/slug NULL = keep; parent_id: -2 = keep, -1 = root, >= 0 = set
// (must resolve in scope; a parent cycle is SF_ERR_VALIDATION).
sf_result sf_cms_update_collection(sf_store *s, int64_t tenant_id,
                                   int64_t collection_id,
                                   const char *name, const char *slug,
                                   int64_t parent_id);
// SF_ERR_CONFLICT while child collections or items remain (§13.7).
sf_result sf_cms_delete_collection(sf_store *s, int64_t tenant_id,
                                   int64_t collection_id);

// ---- Items ---------------------------------------------------------------
// Create the item AND its version 1 (referencing blob_id, which must
// resolve inside the tenant) in one transaction. Slug conflict is
// SF_ERR_CONFLICT; a cross-tenant collection/blob id is
// SF_ERR_NOT_FOUND.
sf_result sf_cms_create_item(sf_store *s, int64_t tenant_id,
                             int64_t collection_id /*-1 = root*/,
                             const char *slug, const char *title,
                             const char *kind, const char *metadata_json,
                             int64_t blob_id, const char *created_by,
                             sf_cms_item *out);
sf_result sf_cms_get_item(sf_store *s, int64_t tenant_id, int64_t item_id,
                          sf_cms_item *out);
// Filters: collection_id -1 = any; kind/state NULL = any.
sf_result sf_cms_list_items(sf_store *s, int64_t tenant_id,
                            int64_t collection_id, const char *kind,
                            const char *state, int64_t cursor, int limit,
                            sf_cms_item **out_rows, size_t *out_count);
// §13.5 search: q is a substring over title, slug, and the
// metadata_json text, matched literally (% and _ in q are escaped,
// never wildcards); filters as in sf_cms_list_items. q NULL/"" = all.
sf_result sf_cms_search_items(sf_store *s, int64_t tenant_id, const char *q,
                              int64_t collection_id, const char *kind,
                              const char *state, int64_t cursor, int limit,
                              sf_cms_item **out_rows, size_t *out_count);
// Field edits only (title/kind/collection/metadata) — never creates a
// version. NULL = keep for title/kind/metadata_json; collection_id:
// -2 = keep, -1 = root, >= 0 = set (must resolve in scope).
sf_result sf_cms_update_item(sf_store *s, int64_t tenant_id, int64_t item_id,
                             const char *title, const char *kind,
                             int64_t collection_id,
                             const char *metadata_json);
sf_result sf_cms_set_item_state(sf_store *s, int64_t tenant_id,
                                int64_t item_id, const char *state);
// Delete the item, its versions, and its refs (both directions) in
// one transaction, detaching every blob those rows referenced.
// *slug_out (when non-NULL) receives the item's slug for the audit
// row (§13.5: deletion is audited with the slug).
sf_result sf_cms_delete_item(sf_store *s, int64_t tenant_id, int64_t item_id,
                             char *slug_out, size_t slug_cap);

// ---- Versions ------------------------------------------------------------
// Append via sf_blob_attach_version, then read the row back.
sf_result sf_cms_append_version(sf_store *s, int64_t tenant_id,
                                int64_t item_id, int64_t blob_id,
                                const char *note, const char *metadata_json,
                                const char *created_by, sf_cms_version *out);
// Rollback: a NEW version referencing the target version's blob, note
// "rollback of v<n>", metadata copied from the target version.
sf_result sf_cms_rollback(sf_store *s, int64_t tenant_id, int64_t item_id,
                          int64_t target_version_no, const char *created_by,
                          sf_cms_version *out);
sf_result sf_cms_list_versions(sf_store *s, int64_t tenant_id,
                               int64_t item_id, sf_cms_version **out_rows,
                               size_t *out_count);  // newest first
sf_result sf_cms_get_version(sf_store *s, int64_t tenant_id, int64_t item_id,
                             int64_t version_no, sf_cms_version *out);

// ---- Refs ------------------------------------------------------------------
// Create via sf_blob_attach_content_ref (exactly-one-target honored
// there in code and by the table CHECK), then read the row back.
sf_result sf_cms_create_ref(sf_store *s, int64_t tenant_id,
                            int64_t from_item_id, int64_t to_item_id,
                            int64_t to_blob_id, const char *kind,
                            sf_cms_ref *out);
sf_result sf_cms_get_ref(sf_store *s, int64_t tenant_id, int64_t from_item_id,
                         int64_t ref_id, sf_cms_ref *out);
sf_result sf_cms_list_refs(sf_store *s, int64_t tenant_id, int64_t item_id,
                           sf_cms_ref **out_rows, size_t *out_count);
// Delete the ref row and, for a blob target, detach the blob — one
// transaction. The ref must belong to from_item_id in scope.
sf_result sf_cms_delete_ref(sf_store *s, int64_t tenant_id,
                            int64_t from_item_id, int64_t ref_id);

#endif // SFCMS_H
