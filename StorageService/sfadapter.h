// sfadapter.h — storage backends behind one vtable (design record 03
// §7). The context of every call carries the tenant and bucket ids:
// bytes are tenant-addressed, and an adapter cannot be asked for
// another tenant's bytes without that tenant's ids in hand (§3.2
// wall 3). The `key` argument is the object's logical key; adapters
// map it to their own physical naming and must never let it escape
// the tenant/bucket prefix.
#ifndef SFADAPTER_H
#define SFADAPTER_H

#include "sfcommon.h"
#include "sfstore.h"

typedef struct sf_adapter_ctx sf_adapter_ctx;

typedef struct {
    const char *kind;  // "filesystem" | "s3"
    // Store `len` bytes for key; compute nothing (the route layer
    // hashes). SF_ERR_TOO_LARGE when the adapter cannot take len.
    sf_result (*put)(sf_adapter_ctx *ctx, const char *key,
                     const uint8_t *data, size_t len);
    // Read the whole object. *data_out is malloc'd; caller frees.
    // (v1 object cap is 256 MiB; whole-object reads are the model.)
    sf_result (*get)(sf_adapter_ctx *ctx, const char *key,
                     uint8_t **data_out, size_t *len_out);
    sf_result (*del)(sf_adapter_ctx *ctx, const char *key);
    sf_result (*exists)(sf_adapter_ctx *ctx, const char *key, int *exists_out);
    void      (*destroy)(sf_adapter_ctx *ctx);
} sf_adapter_vtable;

struct sf_adapter_ctx {
    const sf_adapter_vtable *vt;
    int64_t tenant_id;
    int64_t bucket_id;
    void *impl;  // adapter-private state
};

// Construct a context for one (backend, tenant, bucket) triple.
// filesystem: config_json = {"root": "<subpath under data dir>"} —
//   `fs_root_base` is the service data dir; final path is
//   <fs_root_base>/<root>/<tenant_id>/<bucket_id>/<object_id-ish>.
//   The physical file name is derived from the key's SHA-256 — the
//   key itself never becomes a path component.
// s3: config_json = {"endpoint": "http://host:port", "region": "us-east-1",
//   "bucket": "name", "access_key_id": "...", "prefix": ""} — secret
//   from the environment variable named by secret_ref (never config).
//   Object name = <prefix><tenant_id>/<bucket_id>/<sha256-of-key>.
//   Transport is HTTP (design §7.3); SigV4 signed.
sf_adapter_ctx *sf_adapter_open(const sf_backend *backend,
                                const char *fs_root_base,
                                int64_t tenant_id, int64_t bucket_id,
                                char *errbuf, size_t errbuf_len);
void sf_adapter_close(sf_adapter_ctx *ctx);

// Object-key grammar (design §7.2): 1..512 chars from [A-Za-z0-9._/-],
// first char alphanumeric, no ".." segment, no leading/trailing '/',
// no "//" run, no backslash or control characters.
int sf_key_valid(const char *key);

#endif // SFADAPTER_H
