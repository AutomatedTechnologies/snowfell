// sfvectors.c — test harness for sfcommon / sfsha256 / sfjson.
// Build: cc -DSF_VECTORS_MAIN -std=c99 -Wall -Wextra -Werror -I.
//          sfvectors.c sfcommon.c sfsha256.c sfjson.c -o sfvectors
#ifdef SF_VECTORS_MAIN

#include "sfcommon.h"
#include "sfsha256.h"
#include "sfjson.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int g_pass = 0;
static int g_fail = 0;

static void report(int ok, const char *name) {
    if (ok) { g_pass++; printf("PASS %s\n", name); }
    else    { g_fail++; printf("FAIL %s\n", name); }
}

static void check_digest(const char *name, const uint8_t got[32], const char *want_hex) {
    char hex[65];
    sf_hex_encode(got, 32, hex);
    if (strcmp(hex, want_hex) != 0)
        printf("  got  %s\n  want %s\n", hex, want_hex);
    report(strcmp(hex, want_hex) == 0, name);
}

// ------------------------------------------------------------ SHA-256

static void test_sha256(void) {
    uint8_t out[32];
    sf_sha256("", 0, out);
    check_digest("sha256 empty", out,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    sf_sha256("abc", 3, out);
    check_digest("sha256 abc", out,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    {
        const char *m = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
        sf_sha256(m, strlen(m), out);
        check_digest("sha256 56-byte FIPS", out,
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1");
    }
    {
        // 1,000,000 x 'a', fed in chunks to exercise update().
        sf_sha256_ctx ctx;
        uint8_t chunk[1000];
        int i;
        memset(chunk, 'a', sizeof chunk);
        sf_sha256_init(&ctx);
        for (i = 0; i < 1000; i++) sf_sha256_update(&ctx, chunk, sizeof chunk);
        sf_sha256_final(&ctx, out);
        check_digest("sha256 1M x a (streaming)", out,
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
    }
}

// ------------------------------------------------------------ HMAC

static void test_hmac(void) {
    uint8_t out[32];
    {
        uint8_t key[20];
        memset(key, 0x0b, sizeof key);
        sf_hmac_sha256(key, sizeof key, "Hi There", 8, out);
        check_digest("hmac RFC4231 case1", out,
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
    }
    {
        const char *data = "what do ya want for nothing?";
        sf_hmac_sha256("Jefe", 4, data, strlen(data), out);
        check_digest("hmac RFC4231 case2", out,
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
    }
    {
        uint8_t key[20], data[50];
        memset(key, 0xaa, sizeof key);
        memset(data, 0xdd, sizeof data);
        sf_hmac_sha256(key, sizeof key, data, sizeof data, out);
        check_digest("hmac RFC4231 case3", out,
            "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe");
    }
}

// ------------------------------------------------------------ PBKDF2

static void test_pbkdf2(void) {
    uint8_t out[32];
    sf_pbkdf2_sha256("password", 8, (const uint8_t *)"salt", 4, 1, out, 32);
    check_digest("pbkdf2 iter1", out,
        "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");
    sf_pbkdf2_sha256("password", 8, (const uint8_t *)"salt", 4, 2, out, 32);
    check_digest("pbkdf2 iter2", out,
        "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43");
    sf_pbkdf2_sha256("password", 8, (const uint8_t *)"salt", 4, 4096, out, 32);
    check_digest("pbkdf2 iter4096", out,
        "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a");
}

// ------------------------------------------------------------ codecs

static void test_codecs(void) {
    // hex round-trip + rejection
    {
        uint8_t data[4] = {0xde, 0xad, 0xbe, 0xef};
        uint8_t back[4];
        char hex[9];
        sf_hex_encode(data, 4, hex);
        report(strcmp(hex, "deadbeef") == 0 &&
               sf_hex_decode(hex, back, sizeof back) == 4 &&
               memcmp(data, back, 4) == 0, "hex round-trip");
        report(sf_hex_decode("zz", back, sizeof back) == -1 &&
               sf_hex_decode("abc", back, sizeof back) == -1,
               "hex rejects invalid/odd");
    }
    // base64url round-trips, lengths 0..5, bytes chosen to produce - and _
    {
        static const uint8_t src[5] = {0xfb, 0xff, 0xfe, 0x00, 0x3f};
        int len;
        for (len = 0; len <= 5; len++) {
            char enc[16];
            char name[64];
            uint8_t back[8];
            int n;
            sf_b64url_encode(src, (size_t)len, enc);
            snprintf(name, sizeof name, "b64url round-trip len%d", len);
            n = sf_b64url_decode(enc, back, sizeof back);
            report(n == len && (len == 0 || memcmp(src, back, (size_t)len) == 0) &&
                   strlen(enc) == sf_b64url_encoded_len((size_t)len) &&
                   strchr(enc, '+') == NULL && strchr(enc, '/') == NULL &&
                   strchr(enc, '=') == NULL, name);
        }
        report(sf_b64url_decode("a*b", (uint8_t[4]){0}, 4) == -1 &&
               sf_b64url_decode("abcde", (uint8_t[8]){0}, 8) == -1,
               "b64url rejects invalid char / len%4==1");
    }
    // constant-time compare + RNG seam + time helpers
    {
        uint8_t a[16], b[16];
        report(sf_random_bytes(a, sizeof a) == 0, "random_bytes fills");
        memcpy(b, a, sizeof a);
        report(sf_ct_equal(a, b, sizeof a) == 0, "ct_equal equal");
        b[3] ^= 1;
        report(sf_ct_equal(a, b, sizeof a) != 0, "ct_equal unequal");
    }
    {
        char iso[32];
        sf_iso_from_unix(0, iso);
        report(strcmp(iso, "1970-01-01T00:00:00Z") == 0 &&
               sf_unix_from_iso(iso) == 0 &&
               sf_unix_from_iso("2026-11-12T06:30:00Z") == 1794465000LL &&
               sf_unix_from_iso("2026-13-01T00:00:00Z") == -1 &&
               sf_unix_from_iso("garbage") == -1,
               "time iso round-trip + validation");
        sf_now_iso(iso);
        report(strlen(iso) == 20 && sf_unix_from_iso(iso) != -1, "time now iso");
    }
}

// ------------------------------------------------------------ JSON

static void test_json_roundtrip(void) {
    const char *fixture =
        "{\"name\":\"Snowfell\",\"count\":42,\"ok\":true,\"nothing\":null,"
        "\"tags\":[\"a\",\"b\"],\"nested\":{\"x\":1.5,\"y\":[1,2,3],"
        "\"s\":\"hi\\nthere\xc3\xa9\"}}";
    sf_json *v = sf_json_parse(fixture);
    char *s1 = v ? sf_json_stringify(v) : NULL;
    sf_json *v2 = s1 ? sf_json_parse(s1) : NULL;
    char *s2 = v2 ? sf_json_stringify(v2) : NULL;
    report(v && s1 && strcmp(s1, fixture) == 0, "json nested fixture stringify==input");
    report(v2 && s2 && strcmp(s2, fixture) == 0, "json nested fixture re-round-trip");
    if (v) {
        int64_t iv = 0;
        report(sf_json_get_int64(v, "count", &iv) && iv == 42, "json get_int64");
        report(sf_json_get_bool(v, "ok", false) == true, "json get_bool");
        report(sf_json_is_null_or_absent(v, "nothing") &&
               sf_json_is_null_or_absent(v, "missing"), "json null-or-absent");
        {
            const char *nm = sf_json_get_string(v, "name");
            report(nm && strcmp(nm, "Snowfell") == 0, "json get_string");
        }
    } else {
        report(0, "json get_int64");
        report(0, "json get_bool");
        report(0, "json null-or-absent");
        report(0, "json get_string");
    }
    free(s1); free(s2);
    sf_json_free(v); sf_json_free(v2);
}

static void test_json_unicode(void) {
    // "\u0041" + surrogate pair for U+1F600, inside a top-level string.
    sf_json *v = sf_json_parse("\"\\u0041\\ud83d\\ude00\"");
    const char want[] = "A\xf0\x9f\x98\x80";
    report(v && v->type == SFJSON_STRING && v->string &&
           strcmp(v->string, want) == 0, "json \\u + surrogate pair");
    sf_json_free(v);
}

static void test_json_constructors(void) {
    sf_json *o = sf_json_new_object();
    sf_json *arr = sf_json_new_array();
    bool ok = o && arr;
    if (ok) ok = sf_json_array_append(arr, sf_json_new_number(1));
    if (ok) ok = sf_json_array_append(arr, sf_json_new_string("two"));
    if (ok) ok = sf_json_object_set(o, "arr", arr); else sf_json_free(arr);
    if (ok) ok = sf_json_object_set(o, "pi", sf_json_new_number(3.25));
    if (ok) ok = sf_json_object_set(o, "big", sf_json_new_number(9007199254740991.0));
    {
        char *s = ok ? sf_json_stringify(o) : NULL;
        report(s && strcmp(s,
            "{\"arr\":[1,\"two\"],\"pi\":3.25,\"big\":9007199254740991}") == 0,
            "json constructors + integral-double printing");
        free(s);
    }
    sf_json_free(o);
}

static void expect_reject(const char *name, const char *text) {
    sf_json *v = sf_json_parse(text);
    report(v == NULL, name);
    sf_json_free(v);
}

static void test_json_rejections(void) {
    expect_reject("json reject trailing garbage", "{\"a\":1} x");
    expect_reject("json reject duplicate keys", "{\"a\":1,\"a\":2}");
    expect_reject("json reject unterminated string", "{\"a\":\"x}");
    expect_reject("json reject bad escape", "\"\\q\"");
    expect_reject("json reject leading-zero number", "[01]");
    expect_reject("json reject trailing comma", "[1,]");
    expect_reject("json reject lone low surrogate", "\"\\udc00\"");
    expect_reject("json reject lone high surrogate", "\"\\ud83d x\"");
    expect_reject("json reject raw control char", "\"a\x01" "b\"");
    expect_reject("json reject overflow number", "[1e999]");
    expect_reject("json reject empty input", "");
    // Depth: 32 nested arrays parse; 33 are rejected.
    {
        char buf[256];
        int i, n = 32;
        sf_json *v;
        for (i = 0; i < n; i++) buf[i] = '[';
        buf[n] = '0';
        for (i = 0; i < n; i++) buf[n + 1 + i] = ']';
        buf[2 * n + 1] = '\0';
        v = sf_json_parse(buf);
        report(v != NULL, "json depth 32 accepted");
        sf_json_free(v);
        n = 33;
        for (i = 0; i < n; i++) buf[i] = '[';
        buf[n] = '0';
        for (i = 0; i < n; i++) buf[n + 1 + i] = ']';
        buf[2 * n + 1] = '\0';
        expect_reject("json reject depth bomb 33", buf);
    }
}

// ------------------------------------------------------------ timing

static void timing_pbkdf2(void) {
    uint8_t salt[SF_SALT_LEN];
    uint8_t out[SF_DERIVED_KEY_LEN];
    clock_t t0, t1;
    double ms;
    memset(salt, 0x5a, sizeof salt);
    t0 = clock();
    sf_pbkdf2_sha256("timing-password", 15, salt, sizeof salt,
                     SF_PBKDF2_ITERATIONS, out, sizeof out);
    t1 = clock();
    ms = 1000.0 * (double)(t1 - t0) / (double)CLOCKS_PER_SEC;
    printf("TIMING pbkdf2-hmac-sha256 %d iterations: %.1f ms\n",
           SF_PBKDF2_ITERATIONS, ms);
}

int main(void) {
    test_sha256();
    test_hmac();
    test_pbkdf2();
    test_codecs();
    test_json_roundtrip();
    test_json_unicode();
    test_json_constructors();
    test_json_rejections();
    timing_pbkdf2();
    printf("VERDICT: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}

#endif // SF_VECTORS_MAIN
