// sfadapter_fs.c — filesystem adapter (design §7.2).
// Physical name = hex SHA-256 of the logical key; final path is
// <fs_root_base>/<config root>/<tenant_id>/<bucket_id>/<hash>.
// Writes land on a temp sibling and rename into place (atomicity).
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include "sfadapter.h"
#include "sfjson.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

void sf_adapter_key_hash(const char *key, char out[65]);

typedef struct {
    char *dir;      // <base>/<root>/<tenant>/<bucket>
} fs_impl;

static int mkdir_p(const char *path) {
    char tmp[4096];
    size_t n = strlen(path);
    if (n == 0 || n >= sizeof tmp) return -1;
    memcpy(tmp, path, n + 1);
    for (size_t i = 1; i <= n; i++) {
        if (tmp[i] == '/' || tmp[i] == '\0') {
            char save = tmp[i];
            tmp[i] = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
            tmp[i] = save;
        }
    }
    return 0;
}

static void fs_path(const fs_impl *im, const char *key, char *out, size_t cap) {
    char hash[65];
    sf_adapter_key_hash(key, hash);
    snprintf(out, cap, "%s/%s", im->dir, hash);
}

static sf_result fs_put(sf_adapter_ctx *ctx, const char *key,
                        const uint8_t *data, size_t len) {
    fs_impl *im = (fs_impl *)ctx->impl;
    if (mkdir_p(im->dir) != 0) return SF_ERR_IO;
    char final_path[4096];
    fs_path(im, key, final_path, sizeof final_path);
    char tmp_path[4096 + 64];
    static unsigned long counter = 0;
    snprintf(tmp_path, sizeof tmp_path, "%s.tmp-%ld-%lu",
             final_path, (long)getpid(), counter++);
    FILE *f = fopen(tmp_path, "wb");
    if (!f) return SF_ERR_IO;
    if (len > 0 && fwrite(data, 1, len, f) != len) {
        fclose(f);
        unlink(tmp_path);
        return SF_ERR_IO;
    }
    if (fclose(f) != 0) {
        unlink(tmp_path);
        return SF_ERR_IO;
    }
    if (rename(tmp_path, final_path) != 0) {
        unlink(tmp_path);
        return SF_ERR_IO;
    }
    return SF_OK;
}

static sf_result fs_get(sf_adapter_ctx *ctx, const char *key,
                        uint8_t **data_out, size_t *len_out) {
    fs_impl *im = (fs_impl *)ctx->impl;
    char path[4096];
    fs_path(im, key, path, sizeof path);
    FILE *f = fopen(path, "rb");
    if (!f) return errno == ENOENT ? SF_ERR_NOT_FOUND : SF_ERR_IO;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return SF_ERR_IO; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return SF_ERR_IO; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return SF_ERR_IO; }
    uint8_t *buf = (uint8_t *)malloc(sz > 0 ? (size_t)sz : 1);
    if (!buf) { fclose(f); return SF_ERR_NOMEM; }
    if (sz > 0 && fread(buf, 1, (size_t)sz, f) != (size_t)sz) {
        free(buf);
        fclose(f);
        return SF_ERR_IO;
    }
    fclose(f);
    *data_out = buf;
    *len_out = (size_t)sz;
    return SF_OK;
}

static sf_result fs_del(sf_adapter_ctx *ctx, const char *key) {
    fs_impl *im = (fs_impl *)ctx->impl;
    char path[4096];
    fs_path(im, key, path, sizeof path);
    if (unlink(path) != 0)
        return errno == ENOENT ? SF_ERR_NOT_FOUND : SF_ERR_IO;
    return SF_OK;
}

static sf_result fs_exists(sf_adapter_ctx *ctx, const char *key, int *exists_out) {
    fs_impl *im = (fs_impl *)ctx->impl;
    char path[4096];
    fs_path(im, key, path, sizeof path);
    struct stat st;
    *exists_out = (stat(path, &st) == 0 && S_ISREG(st.st_mode)) ? 1 : 0;
    return SF_OK;
}

static void fs_destroy(sf_adapter_ctx *ctx) {
    if (!ctx) return;
    fs_impl *im = (fs_impl *)ctx->impl;
    if (im) {
        free(im->dir);
        free(im);
    }
    free(ctx);
}

static const sf_adapter_vtable fs_vtable = {
    "filesystem", fs_put, fs_get, fs_del, fs_exists, fs_destroy
};

sf_adapter_ctx *sf_adapter_fs_open(const sf_backend *backend,
                                   const char *fs_root_base,
                                   int64_t tenant_id, int64_t bucket_id,
                                   char *errbuf, size_t errbuf_len) {
    const char *root = "fsroot";
    char root_buf[256];
    if (backend->config_json && backend->config_json[0]) {
        sf_json *cfg = sf_json_parse(backend->config_json);
        if (cfg) {
            const char *r = sf_json_get_string(cfg, "root");
            if (r && r[0]) {
                snprintf(root_buf, sizeof root_buf, "%s", r);
                root = root_buf;
            }
            sf_json_free(cfg);
        }
    }
    // The config root is a subpath under the data dir; refuse anything
    // that could escape it.
    if (root[0] == '/' || strstr(root, "..")) {
        if (errbuf && errbuf_len > 0)
            snprintf(errbuf, errbuf_len,
                     "filesystem backend root '%s' is not a safe subpath", root);
        return NULL;
    }
    if (!fs_root_base || !fs_root_base[0]) {
        if (errbuf && errbuf_len > 0)
            snprintf(errbuf, errbuf_len, "no service data dir for filesystem backend");
        return NULL;
    }
    fs_impl *im = (fs_impl *)calloc(1, sizeof *im);
    if (!im) return NULL;
    char dir[4096];
    snprintf(dir, sizeof dir, "%s/%s/%lld/%lld", fs_root_base, root,
             (long long)tenant_id, (long long)bucket_id);
    size_t dn = strlen(dir) + 1;
    im->dir = (char *)malloc(dn);
    if (!im->dir) { free(im); return NULL; }
    memcpy(im->dir, dir, dn);

    sf_adapter_ctx *ctx = (sf_adapter_ctx *)calloc(1, sizeof *ctx);
    if (!ctx) { free(im->dir); free(im); return NULL; }
    ctx->vt = &fs_vtable;
    ctx->tenant_id = tenant_id;
    ctx->bucket_id = bucket_id;
    ctx->impl = im;
    return ctx;
}
