// sfadapter.c — adapter dispatch, object-key grammar (design §7.2),
// and the shared key-hash helper. The filesystem and S3 adapters live
// in sfadapter_fs.c / sfadapter_s3.c behind sf_adapter_open.
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include "sfadapter.h"
#include "sfsha256.h"

#include <ctype.h>
#include <stdio.h>
#include <string.h>

// Implemented by sfadapter_fs.c / sfadapter_s3.c.
sf_adapter_ctx *sf_adapter_fs_open(const sf_backend *backend,
                                   const char *fs_root_base,
                                   int64_t tenant_id, int64_t bucket_id,
                                   char *errbuf, size_t errbuf_len);
sf_adapter_ctx *sf_adapter_s3_open(const sf_backend *backend,
                                   const char *fs_root_base,
                                   int64_t tenant_id, int64_t bucket_id,
                                   char *errbuf, size_t errbuf_len);

// Hex SHA-256 of the logical key: the physical object name on both
// adapters, so a key can never become a path or escape its prefix.
void sf_adapter_key_hash(const char *key, char out[65]);

void sf_adapter_key_hash(const char *key, char out[65]) {
    uint8_t digest[32];
    sf_sha256(key, strlen(key), digest);
    sf_hex_encode(digest, 32, out);
}

int sf_key_valid(const char *key) {
    if (!key) return 0;
    size_t len = strlen(key);
    if (len < 1 || len > 512) return 0;
    unsigned char first = (unsigned char)key[0];
    if (!isalnum(first)) return 0;
    if (key[len - 1] == '/') return 0;
    // Segment scan: allowed chars only, no empty segment ("//" or a
    // leading '/'), no ".." segment, no backslash/control (not in the
    // allowed set anyway).
    size_t seg_start = 0;
    for (size_t i = 0; i <= len; i++) {
        if (key[i] == '/' || key[i] == '\0') {
            size_t seg_len = i - seg_start;
            if (seg_len == 0) return 0; // "//" or leading '/'
            if (seg_len == 2 && key[seg_start] == '.' && key[seg_start + 1] == '.')
                return 0;               // ".." segment
            seg_start = i + 1;
            continue;
        }
        unsigned char c = (unsigned char)key[i];
        if (!(isalnum(c) || c == '.' || c == '_' || c == '-')) return 0;
    }
    return 1;
}

sf_adapter_ctx *sf_adapter_open(const sf_backend *backend,
                                const char *fs_root_base,
                                int64_t tenant_id, int64_t bucket_id,
                                char *errbuf, size_t errbuf_len) {
    if (errbuf && errbuf_len > 0) errbuf[0] = '\0';
    if (!backend) {
        if (errbuf && errbuf_len > 0)
            snprintf(errbuf, errbuf_len, "no backend row");
        return NULL;
    }
    if (strcmp(backend->kind, "filesystem") == 0) {
        return sf_adapter_fs_open(backend, fs_root_base, tenant_id, bucket_id,
                                  errbuf, errbuf_len);
    }
    if (strcmp(backend->kind, "s3") == 0) {
        return sf_adapter_s3_open(backend, fs_root_base, tenant_id, bucket_id,
                                  errbuf, errbuf_len);
    }
    if (errbuf && errbuf_len > 0)
        snprintf(errbuf, errbuf_len, "unknown backend kind '%s'", backend->kind);
    return NULL;
}

void sf_adapter_close(sf_adapter_ctx *ctx) {
    if (!ctx) return;
    if (ctx->vt && ctx->vt->destroy) ctx->vt->destroy(ctx);
}
