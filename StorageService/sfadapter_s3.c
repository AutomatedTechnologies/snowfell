// sfadapter_s3.c — S3-compatible adapter (design §7.3).
// Object name = <prefix><tenant_id>/<bucket_id>/<hex-sha256-of-key>.
// AWS Signature Version 4 over the bundled sfsha256 HMAC chain; the
// payload hash is the SHA-256 of the body. The secret is read from
// getenv(secret_ref) at open and never stored or logged. Transport is
// plain HTTP via sockets; an https:// endpoint fails at open, naming
// the TLS seam (design §7.3).
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include "sfadapter.h"
#include "sfjson.h"
#include "sfsha256.h"

#include <ctype.h>
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

void sf_adapter_key_hash(const char *key, char out[65]);

typedef struct {
    char *host;
    int port;
    char *region;
    char *bucket;
    char *access_key;
    char *secret;       // from the environment at open; memory only
    char *prefix;       // "" when none
    int64_t tenant_id;
    int64_t bucket_id;
} s3_impl;

static char *xstrdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

static void hex_encode(const uint8_t *data, size_t len, char *out) {
    sf_hex_encode(data, len, out);
}

// ------------------------------------------------------------- transport

static int tcp_connect(const char *host, int port) {
    char portstr[16];
    snprintf(portstr, sizeof portstr, "%d", port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res) return -1;
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd >= 0) {
        struct timeval tv;
        tv.tv_sec = 60;
        tv.tv_usec = 0;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    }
    return fd;
}

static int write_all(int fd, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        p += (size_t)n;
        len -= (size_t)n;
    }
    return 0;
}

// Read a full HTTP response. On success returns the status code and a
// malloc'd body (possibly empty). -1 on transport/parse failure.
static int read_response(int fd, uint8_t **body_out, size_t *len_out) {
    *body_out = NULL;
    *len_out = 0;
    // Headers: accumulate until CRLFCRLF (cap 64 KiB).
    size_t hcap = 16384, hlen = 0;
    char *hbuf = (char *)malloc(hcap);
    if (!hbuf) return -1;
    size_t body_start = 0;
    int status = -1;
    long content_length = -1;
    int chunked = 0;
    for (;;) {
        if (hlen >= 4) {
            int found = 0;
            for (size_t i = 0; i + 4 <= hlen; i++) {
                if (memcmp(hbuf + i, "\r\n\r\n", 4) == 0) {
                    body_start = i + 4;
                    hbuf[i] = '\0';
                    found = 1;
                    break;
                }
            }
            if (found) break;
        }
        if (hlen >= 65536) { free(hbuf); return -1; }
        if (hlen == hcap) {
            hcap *= 2;
            char *nb = (char *)realloc(hbuf, hcap);
            if (!nb) { free(hbuf); return -1; }
            hbuf = nb;
        }
        ssize_t n = recv(fd, hbuf + hlen, hcap - hlen, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            free(hbuf);
            return -1;
        }
        if (n == 0) { free(hbuf); return -1; }
        hlen += (size_t)n;
    }
    // Status line + the two headers we honor.
    if (sscanf(hbuf, "HTTP/%*d.%*d %d", &status) != 1) { free(hbuf); return -1; }
    const char *p = hbuf;
    while ((p = strchr(p, '\n')) != NULL) {
        p++;
        if (strncasecmp(p, "Content-Length:", 15) == 0)
            content_length = strtol(p + 15, NULL, 10);
        else if (strncasecmp(p, "Transfer-Encoding:", 18) == 0 &&
                 strcasestr(p, "chunked"))
            chunked = 1;
    }
    // Body bytes already buffered past the header terminator.
    size_t bcap = 65536, blen = 0;
    uint8_t *body = (uint8_t *)malloc(bcap);
    if (!body) { free(hbuf); return -1; }
    if (hlen > body_start) {
        size_t extra = hlen - body_start;
        if (extra > bcap) {
            bcap = extra;
            uint8_t *nb = (uint8_t *)realloc(body, bcap);
            if (!nb) { free(body); free(hbuf); return -1; }
            body = nb;
        }
        memcpy(body, hbuf + body_start, extra);
        blen = extra;
    }
    free(hbuf);

    if (chunked) {
        // Decode chunk frames from the buffered + remaining stream.
        size_t rpos = 0;
        uint8_t *decoded = NULL;
        size_t dlen = 0, dcap = 0;
        for (;;) {
            // Ensure a full chunk-size line is buffered.
            for (;;) {
                int eol = 0;
                for (size_t i = rpos; i + 1 < blen; i++) {
                    if (body[i] == '\r' && body[i + 1] == '\n') { eol = 1; break; }
                }
                if (eol) break;
                if (blen == bcap) {
                    bcap *= 2;
                    uint8_t *nb = (uint8_t *)realloc(body, bcap);
                    if (!nb) { free(body); free(decoded); return -1; }
                    body = nb;
                }
                ssize_t n = recv(fd, body + blen, bcap - blen, 0);
                if (n < 0) {
                    if (errno == EINTR) continue;
                    free(body); free(decoded); return -1;
                }
                if (n == 0) { free(body); free(decoded); return -1; }
                blen += (size_t)n;
            }
            char sizebuf[32];
            size_t li = 0;
            while (rpos + li < blen && body[rpos + li] != '\r' && li < sizeof sizebuf - 1) {
                sizebuf[li] = (char)body[rpos + li];
                li++;
            }
            sizebuf[li] = '\0';
            long csize = strtol(sizebuf, NULL, 16);
            rpos += li + 2;
            if (csize <= 0) break;
            // Ensure csize + CRLF buffered.
            while (blen - rpos < (size_t)csize + 2) {
                if (blen == bcap) {
                    bcap *= 2;
                    uint8_t *nb = (uint8_t *)realloc(body, bcap);
                    if (!nb) { free(body); free(decoded); return -1; }
                    body = nb;
                }
                ssize_t n = recv(fd, body + blen, bcap - blen, 0);
                if (n < 0) {
                    if (errno == EINTR) continue;
                    free(body); free(decoded); return -1;
                }
                if (n == 0) { free(body); free(decoded); return -1; }
                blen += (size_t)n;
            }
            if (dlen + (size_t)csize > dcap) {
                dcap = (dlen + (size_t)csize) * 2 + 64;
                uint8_t *nd = (uint8_t *)realloc(decoded, dcap);
                if (!nd) { free(body); free(decoded); return -1; }
                decoded = nd;
            }
            memcpy(decoded + dlen, body + rpos, (size_t)csize);
            dlen += (size_t)csize;
            rpos += (size_t)csize + 2;
        }
        free(body);
        *body_out = decoded;
        *len_out = dlen;
        return status;
    }

    if (content_length >= 0) {
        while (blen < (size_t)content_length) {
            if (blen == bcap) {
                bcap *= 2;
                uint8_t *nb = (uint8_t *)realloc(body, bcap);
                if (!nb) { free(body); return -1; }
                body = nb;
            }
            ssize_t n = recv(fd, body + blen, bcap - blen, 0);
            if (n < 0) {
                if (errno == EINTR) continue;
                free(body);
                return -1;
            }
            if (n == 0) break;
            blen += (size_t)n;
        }
        *body_out = body;
        *len_out = blen;
        return status;
    }
    // Close-delimited body.
    for (;;) {
        if (blen == bcap) {
            bcap *= 2;
            uint8_t *nb = (uint8_t *)realloc(body, bcap);
            if (!nb) { free(body); return -1; }
            body = nb;
        }
        ssize_t n = recv(fd, body + blen, bcap - blen, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            free(body);
            return -1;
        }
        if (n == 0) break;
        blen += (size_t)n;
    }
    *body_out = body;
    *len_out = blen;
    return status;
}

// ---------------------------------------------------------------- SigV4

// Perform one signed request. method/object_name identify the object;
// body may be NULL for GET/HEAD/DELETE. Returns the HTTP status or -1.
static int s3_request(s3_impl *im, const char *method, const char *object_name,
                      const uint8_t *body, size_t body_len,
                      uint8_t **resp_body, size_t *resp_len) {
    if (resp_body) *resp_body = NULL;
    if (resp_len) *resp_len = 0;

    char uri[4096];
    snprintf(uri, sizeof uri, "/%s/%s", im->bucket, object_name);

    // Payload hash: SHA-256 of the body (empty body -> hash of "").
    uint8_t payload_hash[32];
    sf_sha256(body ? body : (const uint8_t *)"", body ? body_len : 0, payload_hash);
    char payload_hex[65];
    hex_encode(payload_hash, 32, payload_hex);

    time_t now = (time_t)sf_now_unix();
    struct tm tmv;
    gmtime_r(&now, &tmv);
    char amzdate[32], datestamp[16];
    strftime(amzdate, sizeof amzdate, "%Y%m%dT%H%M%SZ", &tmv);
    strftime(datestamp, sizeof datestamp, "%Y%m%d", &tmv);

    char host_hdr[512];
    if (im->port == 80) snprintf(host_hdr, sizeof host_hdr, "%s", im->host);
    else snprintf(host_hdr, sizeof host_hdr, "%s:%d", im->host, im->port);

    // Canonical request: signed headers host;x-amz-content-sha256;x-amz-date.
    char canonical[8192];
    snprintf(canonical, sizeof canonical,
             "%s\n%s\n\nhost:%s\nx-amz-content-sha256:%s\nx-amz-date:%s\n\n"
             "host;x-amz-content-sha256;x-amz-date\n%s",
             method, uri, host_hdr, payload_hex, amzdate, payload_hex);
    uint8_t canon_hash[32];
    sf_sha256(canonical, strlen(canonical), canon_hash);
    char canon_hex[65];
    hex_encode(canon_hash, 32, canon_hex);

    char scope[256];
    snprintf(scope, sizeof scope, "%s/%s/s3/aws4_request", datestamp, im->region);
    char to_sign[8192];
    snprintf(to_sign, sizeof to_sign, "AWS4-HMAC-SHA256\n%s\n%s\n%s",
             amzdate, scope, canon_hex);

    // Signing-key chain: HMAC("AWS4"+secret, date) -> region -> service -> request.
    char ksecret[1024];
    snprintf(ksecret, sizeof ksecret, "AWS4%s", im->secret);
    uint8_t kdate[32], kregion[32], kservice[32], ksigning[32], signature[32];
    sf_hmac_sha256(ksecret, strlen(ksecret), datestamp, strlen(datestamp), kdate);
    sf_hmac_sha256(kdate, 32, im->region, strlen(im->region), kregion);
    sf_hmac_sha256(kregion, 32, "s3", 2, kservice);
    sf_hmac_sha256(kservice, 32, "aws4_request", strlen("aws4_request"), ksigning);
    sf_hmac_sha256(ksigning, 32, to_sign, strlen(to_sign), signature);
    char sig_hex[65];
    hex_encode(signature, 32, sig_hex);
    // Scrub the intermediate that embeds the secret.
    memset(ksecret, 0, sizeof ksecret);

    char auth[8192];
    snprintf(auth, sizeof auth,
             "AWS4-HMAC-SHA256 Credential=%s/%s, "
             "SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature=%s",
             im->access_key, scope, sig_hex);

    int fd = tcp_connect(im->host, im->port);
    if (fd < 0) return -1;
    char head[8192];
    int hn = snprintf(head, sizeof head,
                      "%s %s HTTP/1.1\r\n"
                      "Host: %s\r\n"
                      "x-amz-date: %s\r\n"
                      "x-amz-content-sha256: %s\r\n"
                      "Authorization: %s\r\n"
                      "Content-Length: %zu\r\n"
                      "Connection: close\r\n\r\n",
                      method, uri, host_hdr, amzdate, payload_hex, auth,
                      body ? body_len : 0);
    if (hn < 0 || write_all(fd, head, (size_t)hn) != 0) { close(fd); return -1; }
    if (body && body_len > 0 && write_all(fd, body, body_len) != 0) {
        close(fd);
        return -1;
    }
    uint8_t *rb = NULL;
    size_t rl = 0;
    int status = read_response(fd, &rb, &rl);
    close(fd);
    if (status < 0) { free(rb); return -1; }
    if (resp_body) { *resp_body = rb; *resp_len = rl; }
    else free(rb);
    return status;
}

static void s3_object_name(const s3_impl *im, const char *key,
                           char *out, size_t cap) {
    char hash[65];
    sf_adapter_key_hash(key, hash);
    snprintf(out, cap, "%s%lld/%lld/%s", im->prefix,
             (long long)im->tenant_id, (long long)im->bucket_id, hash);
}

static sf_result s3_put(sf_adapter_ctx *ctx, const char *key,
                        const uint8_t *data, size_t len) {
    s3_impl *im = (s3_impl *)ctx->impl;
    char name[4096];
    s3_object_name(im, key, name, sizeof name);
    int status = s3_request(im, "PUT", name, data, len, NULL, NULL);
    if (status < 0) return SF_ERR_BACKEND;
    if (status >= 200 && status < 300) return SF_OK;
    return SF_ERR_BACKEND;
}

static sf_result s3_get(sf_adapter_ctx *ctx, const char *key,
                        uint8_t **data_out, size_t *len_out) {
    s3_impl *im = (s3_impl *)ctx->impl;
    char name[4096];
    s3_object_name(im, key, name, sizeof name);
    uint8_t *body = NULL;
    size_t blen = 0;
    int status = s3_request(im, "GET", name, NULL, 0, &body, &blen);
    if (status < 0) { free(body); return SF_ERR_BACKEND; }
    if (status == 404) { free(body); return SF_ERR_NOT_FOUND; }
    if (status < 200 || status >= 300) { free(body); return SF_ERR_BACKEND; }
    if (!body) {
        body = (uint8_t *)malloc(1);
        if (!body) return SF_ERR_NOMEM;
        blen = 0;
    }
    *data_out = body;
    *len_out = blen;
    return SF_OK;
}

static sf_result s3_del(sf_adapter_ctx *ctx, const char *key) {
    s3_impl *im = (s3_impl *)ctx->impl;
    char name[4096];
    s3_object_name(im, key, name, sizeof name);
    int status = s3_request(im, "DELETE", name, NULL, 0, NULL, NULL);
    if (status < 0) return SF_ERR_BACKEND;
    // S3 delete is idempotent: 200/204 (and a racing 404) all mean gone.
    if ((status >= 200 && status < 300) || status == 404) return SF_OK;
    return SF_ERR_BACKEND;
}

static sf_result s3_exists(sf_adapter_ctx *ctx, const char *key, int *exists_out) {
    s3_impl *im = (s3_impl *)ctx->impl;
    char name[4096];
    s3_object_name(im, key, name, sizeof name);
    int status = s3_request(im, "HEAD", name, NULL, 0, NULL, NULL);
    if (status < 0) return SF_ERR_BACKEND;
    if (status >= 200 && status < 300) { *exists_out = 1; return SF_OK; }
    if (status == 404) { *exists_out = 0; return SF_OK; }
    return SF_ERR_BACKEND;
}

static void s3_destroy(sf_adapter_ctx *ctx) {
    if (!ctx) return;
    s3_impl *im = (s3_impl *)ctx->impl;
    if (im) {
        free(im->host);
        free(im->region);
        free(im->bucket);
        free(im->access_key);
        if (im->secret) {
            memset(im->secret, 0, strlen(im->secret));
            free(im->secret);
        }
        free(im->prefix);
        free(im);
    }
    free(ctx);
}

static const sf_adapter_vtable s3_vtable = {
    "s3", s3_put, s3_get, s3_del, s3_exists, s3_destroy
};

sf_adapter_ctx *sf_adapter_s3_open(const sf_backend *backend,
                                   const char *fs_root_base,
                                   int64_t tenant_id, int64_t bucket_id,
                                   char *errbuf, size_t errbuf_len) {
    (void)fs_root_base;
    if (!backend->secret_ref[0]) {
        if (errbuf && errbuf_len > 0)
            snprintf(errbuf, errbuf_len,
                     "s3 backend '%s' has no secret_ref (env var name)", backend->name);
        return NULL;
    }
    const char *secret = getenv(backend->secret_ref);
    if (!secret || !secret[0]) {
        if (errbuf && errbuf_len > 0)
            snprintf(errbuf, errbuf_len,
                     "s3 secret env var '%s' is not set; backend '%s' unavailable",
                     backend->secret_ref, backend->name);
        return NULL;
    }
    sf_json *cfg = backend->config_json ? sf_json_parse(backend->config_json) : NULL;
    if (!cfg) {
        if (errbuf && errbuf_len > 0)
            snprintf(errbuf, errbuf_len, "s3 backend '%s' has invalid config_json",
                     backend->name);
        return NULL;
    }
    const char *endpoint = sf_json_get_string(cfg, "endpoint");
    const char *region = sf_json_get_string(cfg, "region");
    const char *bucket = sf_json_get_string(cfg, "bucket");
    const char *access_key = sf_json_get_string(cfg, "access_key_id");
    const char *prefix = sf_json_get_string(cfg, "prefix");
    if (!endpoint || !endpoint[0] || !bucket || !bucket[0] ||
        !access_key || !access_key[0]) {
        if (errbuf && errbuf_len > 0)
            snprintf(errbuf, errbuf_len,
                     "s3 backend '%s' config requires endpoint, bucket, access_key_id",
                     backend->name);
        sf_json_free(cfg);
        return NULL;
    }
    if (strncmp(endpoint, "https://", 8) == 0) {
        if (errbuf && errbuf_len > 0)
            snprintf(errbuf, errbuf_len,
                     "s3 backend '%s': https endpoints are not supported in v1 "
                     "(TLS seam, design §7.3); use an http:// endpoint",
                     backend->name);
        sf_json_free(cfg);
        return NULL;
    }
    if (strncmp(endpoint, "http://", 7) != 0) {
        if (errbuf && errbuf_len > 0)
            snprintf(errbuf, errbuf_len,
                     "s3 backend '%s': endpoint must start with http://", backend->name);
        sf_json_free(cfg);
        return NULL;
    }
    // Parse host[:port] out of the endpoint (any path is ignored).
    const char *hp = endpoint + 7;
    const char *slash = strchr(hp, '/');
    size_t host_len = slash ? (size_t)(slash - hp) : strlen(hp);
    char hostport[512];
    if (host_len == 0 || host_len >= sizeof hostport) {
        if (errbuf && errbuf_len > 0)
            snprintf(errbuf, errbuf_len, "s3 backend '%s': bad endpoint host",
                     backend->name);
        sf_json_free(cfg);
        return NULL;
    }
    memcpy(hostport, hp, host_len);
    hostport[host_len] = '\0';
    char *host = hostport;
    int port = 80;
    char *colon = strrchr(hostport, ':');
    if (colon && colon != hostport) {
        *colon = '\0';
        port = atoi(colon + 1);
        if (port <= 0 || port > 65535) port = 80;
    }

    s3_impl *im = (s3_impl *)calloc(1, sizeof *im);
    if (!im) { sf_json_free(cfg); return NULL; }
    im->host = xstrdup(host);
    im->port = port;
    im->region = xstrdup(region && region[0] ? region : "us-east-1");
    im->bucket = xstrdup(bucket);
    im->access_key = xstrdup(access_key);
    im->secret = xstrdup(secret);
    im->prefix = xstrdup(prefix ? prefix : "");
    im->tenant_id = tenant_id;
    im->bucket_id = bucket_id;
    sf_json_free(cfg);
    if (!im->host || !im->region || !im->bucket || !im->access_key ||
        !im->secret || !im->prefix) {
        s3_impl *hold = im;
        free(hold->host); free(hold->region); free(hold->bucket);
        free(hold->access_key); free(hold->secret); free(hold->prefix);
        free(hold);
        return NULL;
    }
    sf_adapter_ctx *ctx = (sf_adapter_ctx *)calloc(1, sizeof *ctx);
    if (!ctx) {
        free(im->host); free(im->region); free(im->bucket);
        free(im->access_key); free(im->secret); free(im->prefix); free(im);
        return NULL;
    }
    ctx->vt = &s3_vtable;
    ctx->tenant_id = tenant_id;
    ctx->bucket_id = bucket_id;
    ctx->impl = im;
    return ctx;
}
