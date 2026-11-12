// sfsha256.c — SHA-256 (FIPS 180-4), HMAC-SHA-256 (RFC 2104),
// PBKDF2-HMAC-SHA-256 (RFC 2898), hex + base64url codecs.
// Portable C99, no dependencies.
#include "sfsha256.h"

#include <string.h>
#include <stdlib.h>

#define ROTR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define CH(x, y, z) (((x) & (y)) ^ (~(x) & (z)))
#define MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define EP0(x) (ROTR(x, 2) ^ ROTR(x, 13) ^ ROTR(x, 22))
#define EP1(x) (ROTR(x, 6) ^ ROTR(x, 11) ^ ROTR(x, 25))
#define SIG0(x) (ROTR(x, 7) ^ ROTR(x, 18) ^ ((x) >> 3))
#define SIG1(x) (ROTR(x, 17) ^ ROTR(x, 19) ^ ((x) >> 10))

static const uint32_t k256[64] = {
    0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,
    0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,
    0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
    0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,
    0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,
    0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
    0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,
    0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u
};

static void sha256_transform(sf_sha256_ctx *ctx, const uint8_t data[]) {
    uint32_t m[64];
    uint32_t a, b, c, d, e, f, g, h, t1, t2;
    unsigned i;
    for (i = 0; i < 16; i++)
        m[i] = ((uint32_t)data[i * 4] << 24) | ((uint32_t)data[i * 4 + 1] << 16) |
               ((uint32_t)data[i * 4 + 2] << 8) | ((uint32_t)data[i * 4 + 3]);
    for (i = 16; i < 64; i++)
        m[i] = SIG1(m[i - 2]) + m[i - 7] + SIG0(m[i - 15]) + m[i - 16];
    a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2]; d = ctx->state[3];
    e = ctx->state[4]; f = ctx->state[5]; g = ctx->state[6]; h = ctx->state[7];
    for (i = 0; i < 64; i++) {
        t1 = h + EP1(e) + CH(e, f, g) + k256[i] + m[i];
        t2 = EP0(a) + MAJ(a, b, c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    ctx->state[0] += a; ctx->state[1] += b; ctx->state[2] += c; ctx->state[3] += d;
    ctx->state[4] += e; ctx->state[5] += f; ctx->state[6] += g; ctx->state[7] += h;
}

void sf_sha256_init(sf_sha256_ctx *ctx) {
    ctx->datalen = 0;
    ctx->bitlen = 0;
    ctx->state[0] = 0x6a09e667u; ctx->state[1] = 0xbb67ae85u;
    ctx->state[2] = 0x3c6ef372u; ctx->state[3] = 0xa54ff53au;
    ctx->state[4] = 0x510e527fu; ctx->state[5] = 0x9b05688cu;
    ctx->state[6] = 0x1f83d9abu; ctx->state[7] = 0x5be0cd19u;
}

void sf_sha256_update(sf_sha256_ctx *ctx, const uint8_t *data, size_t len) {
    size_t i;
    for (i = 0; i < len; i++) {
        ctx->data[ctx->datalen] = data[i];
        ctx->datalen++;
        if (ctx->datalen == 64) {
            sha256_transform(ctx, ctx->data);
            ctx->bitlen += 512;
            ctx->datalen = 0;
        }
    }
}

void sf_sha256_final(sf_sha256_ctx *ctx, uint8_t hash[32]) {
    uint32_t i = ctx->datalen;
    unsigned j;
    if (ctx->datalen < 56) {
        ctx->data[i++] = 0x80;
        while (i < 56) ctx->data[i++] = 0x00;
    } else {
        ctx->data[i++] = 0x80;
        while (i < 64) ctx->data[i++] = 0x00;
        sha256_transform(ctx, ctx->data);
        memset(ctx->data, 0, 56);
    }
    ctx->bitlen += (uint64_t)ctx->datalen * 8;
    ctx->data[63] = (uint8_t)(ctx->bitlen);
    ctx->data[62] = (uint8_t)(ctx->bitlen >> 8);
    ctx->data[61] = (uint8_t)(ctx->bitlen >> 16);
    ctx->data[60] = (uint8_t)(ctx->bitlen >> 24);
    ctx->data[59] = (uint8_t)(ctx->bitlen >> 32);
    ctx->data[58] = (uint8_t)(ctx->bitlen >> 40);
    ctx->data[57] = (uint8_t)(ctx->bitlen >> 48);
    ctx->data[56] = (uint8_t)(ctx->bitlen >> 56);
    sha256_transform(ctx, ctx->data);
    for (j = 0; j < 8; j++) {
        hash[j * 4]     = (uint8_t)((ctx->state[j] >> 24) & 0xffu);
        hash[j * 4 + 1] = (uint8_t)((ctx->state[j] >> 16) & 0xffu);
        hash[j * 4 + 2] = (uint8_t)((ctx->state[j] >> 8) & 0xffu);
        hash[j * 4 + 3] = (uint8_t)(ctx->state[j] & 0xffu);
    }
}

void sf_sha256(const void *data, size_t len, uint8_t out[32]) {
    sf_sha256_ctx ctx;
    sf_sha256_init(&ctx);
    sf_sha256_update(&ctx, (const uint8_t *)data, len);
    sf_sha256_final(&ctx, out);
}

// ---------------------------------------------------------------- HMAC

void sf_hmac_sha256(const void *key, size_t keylen,
                    const void *data, size_t datalen, uint8_t out[32]) {
    uint8_t k[64];
    uint8_t tk[32];
    uint8_t pad[64];
    sf_sha256_ctx ctx;
    size_t i;
    memset(k, 0, sizeof k);
    if (keylen > 64) {
        sf_sha256(key, keylen, tk);
        memcpy(k, tk, 32);
    } else if (keylen > 0) {
        memcpy(k, key, keylen);
    }
    for (i = 0; i < 64; i++) pad[i] = (uint8_t)(k[i] ^ 0x36u);
    sf_sha256_init(&ctx);
    sf_sha256_update(&ctx, pad, 64);
    sf_sha256_update(&ctx, (const uint8_t *)data, datalen);
    sf_sha256_final(&ctx, tk);
    for (i = 0; i < 64; i++) pad[i] = (uint8_t)(k[i] ^ 0x5cu);
    sf_sha256_init(&ctx);
    sf_sha256_update(&ctx, pad, 64);
    sf_sha256_update(&ctx, tk, 32);
    sf_sha256_final(&ctx, out);
    memset(k, 0, sizeof k);
    memset(tk, 0, sizeof tk);
    memset(pad, 0, sizeof pad);
}

// ---------------------------------------------------------------- PBKDF2

void sf_pbkdf2_sha256(const void *password, size_t password_len,
                      const uint8_t *salt, size_t salt_len,
                      uint32_t iterations, uint8_t *out, size_t out_len) {
    uint32_t block = 1;
    size_t produced = 0;
    if (!out || out_len == 0) return;
    if (iterations == 0) iterations = 1;
    while (produced < out_len) {
        // U1 = HMAC(password, salt || INT_32_BE(block))
        uint8_t u[32];
        uint8_t t[32];
        uint8_t ctr[4];
        uint32_t it;
        // Build salt||ctr without a variable-size stack buffer: run the
        // HMAC manually over two segments by reusing sf_hmac_sha256 on a
        // concatenated heap copy only when needed; salt_len here is small
        // by contract, but stay general with a heap buffer.
        uint8_t *msg = (uint8_t *)malloc(salt_len + 4);
        if (!msg) { memset(out, 0, out_len); return; }
        if (salt_len) memcpy(msg, salt, salt_len);
        ctr[0] = (uint8_t)(block >> 24);
        ctr[1] = (uint8_t)(block >> 16);
        ctr[2] = (uint8_t)(block >> 8);
        ctr[3] = (uint8_t)(block);
        memcpy(msg + salt_len, ctr, 4);
        sf_hmac_sha256(password, password_len, msg, salt_len + 4, u);
        free(msg);
        memcpy(t, u, 32);
        for (it = 1; it < iterations; it++) {
            size_t j;
            sf_hmac_sha256(password, password_len, u, 32, u);
            for (j = 0; j < 32; j++) t[j] ^= u[j];
        }
        {
            size_t take = out_len - produced;
            if (take > 32) take = 32;
            memcpy(out + produced, t, take);
            produced += take;
        }
        memset(u, 0, sizeof u);
        memset(t, 0, sizeof t);
        block++;
    }
}

// ---------------------------------------------------------------- hex

void sf_hex_encode(const uint8_t *data, size_t len, char *out) {
    static const char hexd[] = "0123456789abcdef";
    size_t i;
    for (i = 0; i < len; i++) {
        out[i * 2]     = hexd[data[i] >> 4];
        out[i * 2 + 1] = hexd[data[i] & 0x0f];
    }
    out[len * 2] = '\0';
}

static int hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

int sf_hex_decode(const char *hex, uint8_t *out, size_t out_cap) {
    size_t len, need, i;
    if (!hex || !out) return -1;
    len = strlen(hex);
    if (len % 2 != 0) return -1;
    need = len / 2;
    if (need > out_cap) return -1;
    for (i = 0; i < need; i++) {
        int hi = hex_val(hex[i * 2]);
        int lo = hex_val(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return (int)need;
}

// ---------------------------------------------------------------- base64url

static const char b64url_tab[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

size_t sf_b64url_encoded_len(size_t len) {
    size_t full = (len / 3) * 4;
    size_t rem = len % 3;
    if (rem) full += rem + 1;
    return full;
}

void sf_b64url_encode(const uint8_t *data, size_t len, char *out) {
    size_t i = 0, o = 0;
    while (i + 3 <= len) {
        uint32_t v = ((uint32_t)data[i] << 16) | ((uint32_t)data[i + 1] << 8) | data[i + 2];
        out[o++] = b64url_tab[(v >> 18) & 63];
        out[o++] = b64url_tab[(v >> 12) & 63];
        out[o++] = b64url_tab[(v >> 6) & 63];
        out[o++] = b64url_tab[v & 63];
        i += 3;
    }
    if (len - i == 1) {
        uint32_t v = ((uint32_t)data[i] << 16);
        out[o++] = b64url_tab[(v >> 18) & 63];
        out[o++] = b64url_tab[(v >> 12) & 63];
    } else if (len - i == 2) {
        uint32_t v = ((uint32_t)data[i] << 16) | ((uint32_t)data[i + 1] << 8);
        out[o++] = b64url_tab[(v >> 18) & 63];
        out[o++] = b64url_tab[(v >> 12) & 63];
        out[o++] = b64url_tab[(v >> 6) & 63];
    }
    out[o] = '\0';
}

static int b64url_val(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '-') return 62;
    if (c == '_') return 63;
    return -1;
}

int sf_b64url_decode(const char *in, uint8_t *out, size_t out_cap) {
    size_t len, rem, need, i = 0, o = 0;
    if (!in || !out) return -1;
    len = strlen(in);
    if (len % 4 == 1) return -1;
    rem = len % 4;
    need = (len / 4) * 3 + (rem == 2 ? 1 : rem == 3 ? 2 : 0);
    if (need > out_cap) return -1;
    while (i + 4 <= len) {
        int a = b64url_val(in[i]), b = b64url_val(in[i + 1]);
        int c = b64url_val(in[i + 2]), d = b64url_val(in[i + 3]);
        uint32_t v;
        if (a < 0 || b < 0 || c < 0 || d < 0) return -1;
        v = ((uint32_t)a << 18) | ((uint32_t)b << 12) | ((uint32_t)c << 6) | (uint32_t)d;
        out[o++] = (uint8_t)(v >> 16);
        out[o++] = (uint8_t)(v >> 8);
        out[o++] = (uint8_t)v;
        i += 4;
    }
    if (rem == 2) {
        int a = b64url_val(in[i]), b = b64url_val(in[i + 1]);
        if (a < 0 || b < 0) return -1;
        if (b & 0x0f) return -1; // non-canonical trailing bits
        out[o++] = (uint8_t)((a << 2) | (b >> 4));
    } else if (rem == 3) {
        int a = b64url_val(in[i]), b = b64url_val(in[i + 1]), c = b64url_val(in[i + 2]);
        if (a < 0 || b < 0 || c < 0) return -1;
        if (c & 0x03) return -1; // non-canonical trailing bits
        out[o++] = (uint8_t)((a << 2) | (b >> 4));
        out[o++] = (uint8_t)(((b & 0x0f) << 4) | (c >> 2));
    }
    return (int)o;
}
