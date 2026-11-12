// sfcommon.h — Snowfell Storage Service: shared types and error codes.
// Design record 03 (SF-T12). Portable C99; the only external dependency
// of the whole service is sqlite3. This header is the frozen contract
// every StorageService translation unit builds against.
#ifndef SFCOMMON_H
#define SFCOMMON_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// Result codes returned by store/auth/adapter functions. HTTP mapping
// lives in the route layer; these stay transport-free.
typedef enum {
    SF_OK = 0,
    SF_ERR_NOT_FOUND,     // row/object absent (or not visible in scope)
    SF_ERR_CONFLICT,      // uniqueness or state conflict
    SF_ERR_VALIDATION,    // malformed input, bad key grammar, bad JSON
    SF_ERR_QUOTA,         // quota would be exceeded
    SF_ERR_AUTH,          // bad credentials / bad token / expired
    SF_ERR_LOCKED,        // credential locked out
    SF_ERR_FORBIDDEN,     // authenticated but not permitted
    SF_ERR_TENANT_STATE,  // tenant suspended/closed
    SF_ERR_BACKEND,       // adapter/backend failure
    SF_ERR_IO,            // filesystem / socket / OS failure
    SF_ERR_DB,            // sqlite failure
    SF_ERR_NOMEM,
    SF_ERR_TOO_LARGE      // payload over a stated cap
} sf_result;

// ISO-8601 UTC timestamps are char[32] ("2026-11-12T06:30:00Z" + NUL).
typedef char sf_time[32];

// Fill `out` with the current UTC time in ISO-8601 form; also returns
// the current unix time. Implemented in sfcommon.c.
int64_t sf_now_unix(void);
void sf_now_iso(char out[32]);

// Fill `out` with the ISO-8601 form of a unix timestamp.
void sf_iso_from_unix(int64_t t, char out[32]);

// Parse an ISO-8601 UTC timestamp produced by this service back to unix
// seconds. Returns -1 on malformed input.
int64_t sf_unix_from_iso(const char *iso);

// CSPRNG seam: arc4random_buf on macOS, getrandom//dev/urandom in the
// standalone build. Returns 0 on success. No hand-rolled RNG exists in
// this codebase.
int sf_random_bytes(void *buf, size_t len);

// Constant-time memory compare: 0 iff equal (see sfsha256.c; lives with
// the crypto primitives, declared here for general use).
int sf_ct_equal(const void *a, const void *b, size_t len);

#endif // SFCOMMON_H
