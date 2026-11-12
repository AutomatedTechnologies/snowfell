// sfsha256.h — SHA-256, HMAC-SHA-256, PBKDF2-HMAC-SHA-256, hex and
// base64url codecs. Bundled implementations (design record 03 §5.1):
// the shipped bytes are the tested bytes on every platform. Proven
// against FIPS 180-4 / RFC 4231 / published PBKDF2 vectors by the
// vector harness (sfvectors.c, built only for tests).
#ifndef SFSHA256_H
#define SFSHA256_H

#include "sfcommon.h"

typedef struct {
    uint32_t state[8];
    uint64_t bitlen;
    uint8_t  data[64];
    uint32_t datalen;
} sf_sha256_ctx;

void sf_sha256_init(sf_sha256_ctx *ctx);
void sf_sha256_update(sf_sha256_ctx *ctx, const uint8_t *data, size_t len);
void sf_sha256_final(sf_sha256_ctx *ctx, uint8_t hash[32]);

// One-shot SHA-256.
void sf_sha256(const void *data, size_t len, uint8_t out[32]);

// HMAC-SHA-256 (RFC 2104).
void sf_hmac_sha256(const void *key, size_t keylen,
                    const void *data, size_t datalen, uint8_t out[32]);

// PBKDF2-HMAC-SHA-256 (RFC 2898). Design parameters of record:
// iterations = SF_PBKDF2_ITERATIONS, salt 16 bytes, derived key 32.
#define SF_PBKDF2_ITERATIONS 210000
#define SF_SALT_LEN 16
#define SF_DERIVED_KEY_LEN 32
void sf_pbkdf2_sha256(const void *password, size_t password_len,
                      const uint8_t *salt, size_t salt_len,
                      uint32_t iterations, uint8_t *out, size_t out_len);

// Hex: out needs 2*len+1 bytes. hex_decode returns bytes written or -1.
void sf_hex_encode(const uint8_t *data, size_t len, char *out);
int  sf_hex_decode(const char *hex, uint8_t *out, size_t out_cap);

// base64url (RFC 4648 §5, no padding). encoded_len excludes the NUL.
size_t sf_b64url_encoded_len(size_t len);
void   sf_b64url_encode(const uint8_t *data, size_t len, char *out);
// Returns bytes written, or -1 on invalid input.
int    sf_b64url_decode(const char *in, uint8_t *out, size_t out_cap);

#endif // SFSHA256_H
