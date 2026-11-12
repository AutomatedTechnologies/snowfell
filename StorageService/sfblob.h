// sfblob.h — the content-addressable blob layer (design record 03
// §13.2/§13.3/§13.6). This is a NEW header (SF-T12h): the frozen
// headers (sfcommon/sfstore/sfadapter/sfauth/sfhttp/sfjson/sfsha256/
// sfroutes) are unchanged; blob functions live here.
//
// Model: a blob is (tenant_id, sha256) — the per-tenant dedup scope
// (§13.4). Payload bytes exist at most once per scope. References are
// cs_objects rows, cs_content_versions rows, and cs_content_refs rows;
// cs_blobs.refcount always equals the live reference count and is
// maintained in the SAME transaction as the reference insert/delete
// (the attach/detach primitives below are that transaction — callers
// never adjust refcounts separately).
//
// Write path (§13.2.1): the caller spools the body and computes the
// SHA-256 digest + size itself, then:
//   1. sf_blob_get_by_digest — hit: NO adapter write may occur.
//   2. miss: caller writes the bytes through the adapter (key = the
//      blob's hex digest), then calls the attach primitive, which
//      get-or-creates the row and links the reference atomically.
//   If an attach fails after a miss-write, the caller compensates with
//   an adapter delete of the digest key (design §7.1 convergence).
//
// Physical placement: the §7 adapters name bytes
// <tenant_id>/<bucket_id>/<hash-of-key>. Blob bytes are written under
// the bucket prefix of the reference that created them (bucket 0 for
// a raw, unreferenced upload). Reads therefore search the candidate
// prefixes — the referencing buckets, then 0 — via
// sf_blob_reference_buckets(); the DB holds exactly one logical blob
// regardless of which prefix holds its bytes.
//
// Integrity: a blob in state 'corrupt' refuses reads — the read
// helpers return SF_ERR_BACKEND and the route layer answers
// 502 blob_integrity (§13.2). SF_BLOB_ERR_CORRUPT names that case at
// this layer for callers that need to distinguish it.
#ifndef SFBLOB_H
#define SFBLOB_H

#include "sfcommon.h"
#include "sfstore.h"
#include "sfadapter.h"

#define SF_BLOB_ERR_CORRUPT SF_ERR_BACKEND

typedef struct {
    int64_t id;
    int64_t tenant_id;
    uint8_t sha256[32];
    char sha256_hex[65];
    int64_t size_bytes;
    int64_t backend_id;
    int64_t refcount;
    char state[16];              // ok | corrupt
    char orphaned_at[32];        // "" when referenced / never orphaned
    char created_at[32];
    char last_verified_at[32];   // "" when never verified
} sf_blob;

typedef struct {
    int64_t logical_bytes;       // sum over live references
    int64_t physical_bytes;      // sum over LIVE blobs (refcount > 0):
                                 // orphaned bytes are transient garbage
                                 // awaiting GC — reported by the sweep's
                                 // bytes_reclaimed, not charged (§13.6)
    int64_t bytes_saved;         // logical - physical
    double dedup_ratio;          // logical/physical; 1.0 when physical=0
    int64_t blob_count;
    int64_t reference_count;     // objects + versions + refs
} sf_dedup_stats;

// Scoped lookups. tenant_id < 0 = any scope (operator paths only);
// a scoped miss is SF_ERR_NOT_FOUND whether absent or cross-tenant.
sf_result sf_blob_get_by_id(sf_store *s, int64_t tenant_id, int64_t blob_id,
                            sf_blob *out);
sf_result sf_blob_get_by_digest(sf_store *s, int64_t tenant_id,
                                const uint8_t sha256[32], sf_blob *out);
sf_result sf_blob_list(sf_store *s, int64_t tenant_id /*-1 = all scopes*/,
                       sf_blob **out_rows, size_t *out_count);
void sf_blob_free_all(sf_blob *rows, size_t count);

// The blob_id linked to an object row; *out = -1 when the row has no
// blob (pre-v2 rows cannot occur after the upgrade backfill).
sf_result sf_blob_object_blob_id(sf_store *s, int64_t object_id, int64_t *out);

// Distinct bucket ids of the object references to a blob (read-path
// candidates, § placement note above). Caller frees *out.
sf_result sf_blob_reference_buckets(sf_store *s, int64_t tenant_id,
                                    int64_t blob_id, int64_t **out,
                                    size_t *out_count);

// Create an UNREFERENCED blob row (raw upload): refcount 0 and
// orphaned_at stamped at creation (§13.3 — the grace period protects
// compose-then-reference flows). Caller writes the adapter bytes
// first and compensates on failure. If the digest already exists in
// scope, returns the existing row with *created_out = 0.
sf_result sf_blob_create_unreferenced(sf_store *s, int64_t tenant_id,
                                      const uint8_t sha256[32],
                                      int64_t size_bytes, int64_t backend_id,
                                      sf_blob *out, int *created_out);

// Attach: insert-or-replace the cs_objects reference for
// (bucket_id, key) AND get-or-create + refcount the blob, in ONE
// transaction. Replacing an object whose blob differs detaches the
// old blob in the same transaction (orphan-stamped when its count
// reaches 0). Bucket counters keep their reference-side meaning:
// object_count/total_bytes count references (logical bytes), exactly
// as in schema v1; tenant physical truth comes from cs_blobs (§13.6).
// *hit_out = 1 when the blob row already existed in scope.
sf_result sf_blob_put_object_ref(sf_store *s, int64_t tenant_id,
                                 int64_t bucket_id, const char *key,
                                 int64_t size_bytes, const uint8_t sha256[32],
                                 const char *content_type,
                                 const char *metadata_json,
                                 int64_t backend_id,
                                 sf_object *out, sf_blob *blob_out,
                                 int *hit_out);

// Detach: delete the cs_objects reference for (bucket_id, key) AND
// decrement/orphan its blob, in ONE transaction (bucket counters
// adjusted as in sf_store_delete_object). *detached_blob_id_out
// receives the blob that lost the reference (-1 when none).
sf_result sf_blob_delete_object_ref(sf_store *s, int64_t tenant_id,
                                    int64_t bucket_id, const char *key,
                                    int64_t *detached_blob_id_out);

// Version attach (SF-T12i): insert the next cs_content_versions row
// for (tenant_id, item_id) referencing blob_id AND increment the
// blob's refcount AND advance the item's current_version_id, in ONE
// transaction. Item and blob must both exist in the tenant scope
// (a cross-tenant id is SF_ERR_NOT_FOUND, indistinguishable from
// absent). version_no is MAX(existing)+1 — history is append-only.
// The item's first version is created by the CMS store inside its
// item-creation transaction; this primitive serves every later
// version (appends and rollbacks alike).
sf_result sf_blob_attach_version(sf_store *s, int64_t tenant_id,
                                 int64_t item_id, int64_t blob_id,
                                 const char *note, const char *metadata_json,
                                 const char *created_by,
                                 int64_t *version_id_out,
                                 int64_t *version_no_out);

// Ref attach (SF-T12i): insert a cs_content_refs row from from_item_id
// to exactly one target (to_item_id >= 0 XOR to_blob_id >= 0; both in
// the caller's tenant scope) AND, for a blob target, increment the
// blob's refcount — in ONE transaction. Violating the exactly-one-
// target rule (the table's CHECK, honored here in code) is
// SF_ERR_VALIDATION before any SQL runs.
sf_result sf_blob_attach_content_ref(sf_store *s, int64_t tenant_id,
                                     int64_t from_item_id,
                                     int64_t to_item_id, int64_t to_blob_id,
                                     const char *kind, int64_t *ref_id_out);

// Standalone detach of one reference to a blob (used by the CMS layer
// and tests): refcount-1, orphan-stamped at 0. *now_orphan_out = 1
// when this detach dropped the count to 0.
sf_result sf_blob_detach(sf_store *s, int64_t tenant_id, int64_t blob_id,
                         int *now_orphan_out);

// Recompute a blob's refcount from the reference tables (objects +
// content versions + content refs), store the recomputed value, and
// keep orphaned_at consistent (stamped when the count is 0 and no
// stamp exists; cleared when references exist). The GC sweep trusts
// this recomputation, never the stored counter (§13.3).
sf_result sf_blob_recompute_refcount(sf_store *s, int64_t tenant_id,
                                     int64_t blob_id, int64_t *out_count);

sf_result sf_blob_set_state(sf_store *s, int64_t tenant_id, int64_t blob_id,
                            const char *state /* ok | corrupt */);
sf_result sf_blob_delete_row(sf_store *s, int64_t tenant_id, int64_t blob_id);

// Read a blob's bytes through an adapter context opened for one
// candidate bucket prefix (the caller iterates candidates). Returns
// SF_BLOB_ERR_CORRUPT (SF_ERR_BACKEND) without touching the adapter
// when the blob is corrupt.
sf_result sf_blob_read(sf_adapter_ctx *actx, const sf_blob *blob,
                       uint8_t **data_out, size_t *len_out);

// Verify: read the bytes back via `actx`, recompute SHA-256, compare
// digest AND size (§13.9). Match: last_verified_at stamped,
// *verified_out = 1. Mismatch (or unreadable): state set to corrupt,
// *verified_out = 0, SF_OK returned — the verdict is data, the route
// layer audits it. Adapter/DB failures return an error code.
sf_result sf_blob_verify(sf_store *s, sf_adapter_ctx *actx, sf_blob *blob,
                         int *verified_out);

// Dedup accounting for one scope (§13.6). Physical totals derive from
// cs_blobs; logical totals are the sum over live references.
sf_result sf_blob_accounting(sf_store *s, int64_t tenant_id,
                             sf_dedup_stats *out);

#endif // SFBLOB_H
