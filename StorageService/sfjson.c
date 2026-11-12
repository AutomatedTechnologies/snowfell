// sfjson.c — strict JSON model per sfjson.h.
// Parser: depth cap 32, input cap 1 MiB, duplicate object keys rejected,
// full string escapes incl. \u with surrogate pairs, strict UTF-8 in raw
// string bytes, strict number grammar. Serializer: integral doubles
// that fit int64 print as integers; other finite numbers print with the
// shortest %.*g precision (1..17) that round-trips.
#include "sfjson.h"

#include <float.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

#define SF_JSON_MAX_INPUT (1024u * 1024u)
#define SF_JSON_MAX_DEPTH 32

static char *sf_strdup(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

// ------------------------------------------------------------ lifecycle

static sf_json *alloc_node(sf_json_type t) {
    sf_json *v = (sf_json *)calloc(1, sizeof(sf_json));
    if (v) v->type = t;
    return v;
}

void sf_json_free(sf_json *v) {
    size_t i;
    if (!v) return;
    free(v->string);
    if (v->items) {
        for (i = 0; i < v->count; i++) sf_json_free(v->items[i]);
        free(v->items);
    }
    if (v->keys) {
        for (i = 0; i < v->count; i++) free(v->keys[i]);
        free(v->keys);
    }
    free(v);
}

sf_json *sf_json_new_null(void)   { return alloc_node(SFJSON_NULL); }
sf_json *sf_json_new_bool(bool b) {
    sf_json *v = alloc_node(SFJSON_BOOL);
    if (v) v->boolean = b;
    return v;
}
sf_json *sf_json_new_number(double n) {
    sf_json *v = alloc_node(SFJSON_NUMBER);
    if (v) v->number = n;
    return v;
}
sf_json *sf_json_new_string(const char *s) {
    sf_json *v;
    if (!s) return NULL;
    v = alloc_node(SFJSON_STRING);
    if (!v) return NULL;
    v->string = sf_strdup(s);
    if (!v->string) { free(v); return NULL; }
    return v;
}
sf_json *sf_json_new_array(void)  { return alloc_node(SFJSON_ARRAY); }
sf_json *sf_json_new_object(void) { return alloc_node(SFJSON_OBJECT); }

bool sf_json_array_append(sf_json *arr, sf_json *value) {
    sf_json **ni;
    if (!arr || arr->type != SFJSON_ARRAY || !value) return false;
    ni = (sf_json **)realloc(arr->items, (arr->count + 1) * sizeof(sf_json *));
    if (!ni) return false;
    arr->items = ni;
    arr->items[arr->count++] = value;
    return true;
}

bool sf_json_object_set(sf_json *obj, const char *key, sf_json *value) {
    size_t i;
    sf_json **ni;
    char **nk;
    char *kc;
    if (!obj || obj->type != SFJSON_OBJECT || !key || !value) return false;
    for (i = 0; i < obj->count; i++) {
        if (strcmp(obj->keys[i], key) == 0) {
            sf_json_free(obj->items[i]);
            obj->items[i] = value;
            return true;
        }
    }
    kc = sf_strdup(key);
    if (!kc) return false;
    ni = (sf_json **)realloc(obj->items, (obj->count + 1) * sizeof(sf_json *));
    if (!ni) { free(kc); return false; }
    obj->items = ni;
    nk = (char **)realloc(obj->keys, (obj->count + 1) * sizeof(char *));
    if (!nk) { free(kc); return false; } // items block grew; count unchanged — harmless
    obj->keys = nk;
    obj->keys[obj->count] = kc;
    obj->items[obj->count] = value;
    obj->count++;
    return true;
}

// ------------------------------------------------------------ accessors

const sf_json *sf_json_object_get(const sf_json *obj, const char *key) {
    size_t i;
    if (!obj || obj->type != SFJSON_OBJECT || !key) return NULL;
    for (i = 0; i < obj->count; i++)
        if (strcmp(obj->keys[i], key) == 0) return obj->items[i];
    return NULL;
}

const char *sf_json_get_string(const sf_json *obj, const char *key) {
    const sf_json *v = sf_json_object_get(obj, key);
    if (!v || v->type != SFJSON_STRING) return NULL;
    return v->string;
}

bool sf_json_get_bool(const sf_json *obj, const char *key, bool dflt) {
    const sf_json *v = sf_json_object_get(obj, key);
    if (!v || v->type != SFJSON_BOOL) return dflt;
    return v->boolean;
}

static bool sf_is_finite(double n) {
    return n == n && n <= DBL_MAX && n >= -DBL_MAX;
}

bool sf_json_get_int64(const sf_json *obj, const char *key, int64_t *out) {
    const sf_json *v = sf_json_object_get(obj, key);
    int64_t iv;
    if (!v || v->type != SFJSON_NUMBER || !out) return false;
    if (!sf_is_finite(v->number)) return false;
    if (v->number < -9223372036854775808.0 || v->number >= 9223372036854775808.0)
        return false;
    iv = (int64_t)v->number; // truncates toward zero
    if ((double)iv != v->number) return false;
    *out = iv;
    return true;
}

bool sf_json_is_null_or_absent(const sf_json *obj, const char *key) {
    const sf_json *v = sf_json_object_get(obj, key);
    return v == NULL || v->type == SFJSON_NULL;
}

// ------------------------------------------------------------ parser

typedef struct {
    const char *s;
    size_t len;
    size_t pos;
} sf_parser;

static void skip_ws(sf_parser *p) {
    while (p->pos < p->len) {
        char c = p->s[p->pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p->pos++;
        else break;
    }
}

// Dynamic byte buffer for string decoding.
typedef struct { char *buf; size_t len; size_t cap; } sf_sbuf;

static bool sbuf_put(sf_sbuf *b, const char *data, size_t n) {
    if (b->len + n + 1 > b->cap) {
        size_t ncap = b->cap ? b->cap : 32;
        char *nb;
        while (ncap < b->len + n + 1) ncap *= 2;
        nb = (char *)realloc(b->buf, ncap);
        if (!nb) return false;
        b->buf = nb;
        b->cap = ncap;
    }
    memcpy(b->buf + b->len, data, n);
    b->len += n;
    b->buf[b->len] = '\0';
    return true;
}
static bool sbuf_putc(sf_sbuf *b, char c) { return sbuf_put(b, &c, 1); }

static bool utf8_encode(sf_sbuf *b, uint32_t cp) {
    char tmp[4];
    size_t n;
    if (cp < 0x80) { tmp[0] = (char)cp; n = 1; }
    else if (cp < 0x800) {
        tmp[0] = (char)(0xC0 | (cp >> 6));
        tmp[1] = (char)(0x80 | (cp & 0x3F));
        n = 2;
    } else if (cp < 0x10000) {
        tmp[0] = (char)(0xE0 | (cp >> 12));
        tmp[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        tmp[2] = (char)(0x80 | (cp & 0x3F));
        n = 3;
    } else {
        tmp[0] = (char)(0xF0 | (cp >> 18));
        tmp[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        tmp[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        tmp[3] = (char)(0x80 | (cp & 0x3F));
        n = 4;
    }
    return sbuf_put(b, tmp, n);
}

static int hex4(sf_parser *p, uint32_t *out) {
    uint32_t v = 0;
    int i;
    if (p->pos + 4 > p->len) return -1;
    for (i = 0; i < 4; i++) {
        char c = p->s[p->pos++];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (uint32_t)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (uint32_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (uint32_t)(c - 'A' + 10);
        else return -1;
    }
    *out = v;
    return 0;
}

// Parse a string starting at the opening quote. Returns owned char*
// or NULL on malformed input / OOM.
static char *parse_string_raw(sf_parser *p) {
    sf_sbuf b;
    b.buf = NULL; b.len = 0; b.cap = 0;
    if (p->pos >= p->len || p->s[p->pos] != '"') return NULL;
    p->pos++;
    while (p->pos < p->len) {
        unsigned char c = (unsigned char)p->s[p->pos];
        if (c == '"') {
            p->pos++;
            if (!b.buf) {
                b.buf = sf_strdup("");
                if (!b.buf) return NULL;
            }
            return b.buf;
        }
        if (c == '\\') {
            p->pos++;
            if (p->pos >= p->len) goto fail;
            {
                char e = p->s[p->pos++];
                switch (e) {
                    case '"':  if (!sbuf_putc(&b, '"')) goto fail; break;
                    case '\\': if (!sbuf_putc(&b, '\\')) goto fail; break;
                    case '/':  if (!sbuf_putc(&b, '/')) goto fail; break;
                    case 'b':  if (!sbuf_putc(&b, '\b')) goto fail; break;
                    case 'f':  if (!sbuf_putc(&b, '\f')) goto fail; break;
                    case 'n':  if (!sbuf_putc(&b, '\n')) goto fail; break;
                    case 'r':  if (!sbuf_putc(&b, '\r')) goto fail; break;
                    case 't':  if (!sbuf_putc(&b, '\t')) goto fail; break;
                    case 'u': {
                        uint32_t cp;
                        if (hex4(p, &cp) != 0) goto fail;
                        if (cp >= 0xD800 && cp <= 0xDBFF) {
                            uint32_t lo;
                            if (p->pos + 2 > p->len ||
                                p->s[p->pos] != '\\' || p->s[p->pos + 1] != 'u')
                                goto fail;
                            p->pos += 2;
                            if (hex4(p, &lo) != 0) goto fail;
                            if (lo < 0xDC00 || lo > 0xDFFF) goto fail;
                            cp = 0x10000u + ((cp - 0xD800u) << 10) + (lo - 0xDC00u);
                        } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                            goto fail; // lone low surrogate
                        }
                        if (cp == 0) goto fail; // NUL cannot live in this model
                        if (!utf8_encode(&b, cp)) goto fail;
                        break;
                    }
                    default: goto fail;
                }
            }
            continue;
        }
        if (c < 0x20) goto fail; // raw control character
        if (c < 0x80) {
            if (!sbuf_putc(&b, (char)c)) goto fail;
            p->pos++;
            continue;
        }
        // Raw multibyte UTF-8: validate strictly (no overlongs, no
        // UTF-16 surrogates, max U+10FFFF).
        {
            size_t rem = p->len - p->pos;
            uint32_t cp;
            size_t need, i;
            if ((c & 0xE0) == 0xC0)      { need = 2; cp = c & 0x1F; if (cp < 2) goto fail; }
            else if ((c & 0xF0) == 0xE0) { need = 3; cp = c & 0x0F; }
            else if ((c & 0xF8) == 0xF0) { need = 4; cp = c & 0x07; if (cp > 4) goto fail; }
            else goto fail;
            if (rem < need) goto fail;
            for (i = 1; i < need; i++) {
                unsigned char cc = (unsigned char)p->s[p->pos + i];
                if ((cc & 0xC0) != 0x80) goto fail;
                cp = (cp << 6) | (uint32_t)(cc & 0x3F);
            }
            if (need == 3) {
                if (cp < 0x800) goto fail;
                if (cp >= 0xD800 && cp <= 0xDFFF) goto fail;
            }
            if (need == 4 && (cp < 0x10000 || cp > 0x10FFFF)) goto fail;
            if (!sbuf_put(&b, p->s + p->pos, need)) goto fail;
            p->pos += need;
            continue;
        }
    }
fail:
    free(b.buf);
    return NULL;
}

static sf_json *parse_value(sf_parser *p, int depth);

static sf_json *parse_number(sf_parser *p) {
    size_t start = p->pos;
    size_t n;
    char *tmp;
    double v;
    sf_json *node;
    if (p->pos < p->len && p->s[p->pos] == '-') p->pos++;
    if (p->pos >= p->len) return NULL;
    if (p->s[p->pos] == '0') {
        p->pos++;
    } else if (p->s[p->pos] >= '1' && p->s[p->pos] <= '9') {
        while (p->pos < p->len && p->s[p->pos] >= '0' && p->s[p->pos] <= '9') p->pos++;
    } else {
        return NULL;
    }
    if (p->pos < p->len && p->s[p->pos] == '.') {
        p->pos++;
        if (p->pos >= p->len || p->s[p->pos] < '0' || p->s[p->pos] > '9') return NULL;
        while (p->pos < p->len && p->s[p->pos] >= '0' && p->s[p->pos] <= '9') p->pos++;
    }
    if (p->pos < p->len && (p->s[p->pos] == 'e' || p->s[p->pos] == 'E')) {
        p->pos++;
        if (p->pos < p->len && (p->s[p->pos] == '+' || p->s[p->pos] == '-')) p->pos++;
        if (p->pos >= p->len || p->s[p->pos] < '0' || p->s[p->pos] > '9') return NULL;
        while (p->pos < p->len && p->s[p->pos] >= '0' && p->s[p->pos] <= '9') p->pos++;
    }
    n = p->pos - start;
    tmp = (char *)malloc(n + 1);
    if (!tmp) return NULL;
    memcpy(tmp, p->s + start, n);
    tmp[n] = '\0';
    errno = 0;
    v = strtod(tmp, NULL);
    free(tmp);
    if (errno == ERANGE) return NULL;
    if (!sf_is_finite(v)) return NULL;
    node = sf_json_new_number(v);
    return node;
}

static bool consume_lit(sf_parser *p, const char *lit) {
    size_t n = strlen(lit);
    if (p->pos + n > p->len) return false;
    if (memcmp(p->s + p->pos, lit, n) != 0) return false;
    p->pos += n;
    return true;
}

static sf_json *parse_value(sf_parser *p, int depth) {
    char c;
    skip_ws(p);
    if (p->pos >= p->len) return NULL;
    c = p->s[p->pos];
    if (c == '{') {
        sf_json *obj;
        if (depth >= SF_JSON_MAX_DEPTH) return NULL;
        obj = sf_json_new_object();
        if (!obj) return NULL;
        p->pos++;
        skip_ws(p);
        if (p->pos < p->len && p->s[p->pos] == '}') { p->pos++; return obj; }
        for (;;) {
            char *key;
            sf_json *val;
            size_t i;
            skip_ws(p);
            if (p->pos >= p->len || p->s[p->pos] != '"') { sf_json_free(obj); return NULL; }
            key = parse_string_raw(p);
            if (!key) { sf_json_free(obj); return NULL; }
            for (i = 0; i < obj->count; i++) {
                if (strcmp(obj->keys[i], key) == 0) {
                    free(key); sf_json_free(obj); return NULL; // duplicate key
                }
            }
            skip_ws(p);
            if (p->pos >= p->len || p->s[p->pos] != ':') {
                free(key); sf_json_free(obj); return NULL;
            }
            p->pos++;
            val = parse_value(p, depth + 1);
            if (!val) { free(key); sf_json_free(obj); return NULL; }
            if (!sf_json_object_set(obj, key, val)) {
                free(key); sf_json_free(val); sf_json_free(obj); return NULL;
            }
            free(key);
            skip_ws(p);
            if (p->pos < p->len && p->s[p->pos] == ',') { p->pos++; continue; }
            if (p->pos < p->len && p->s[p->pos] == '}') { p->pos++; return obj; }
            sf_json_free(obj); return NULL;
        }
    }
    if (c == '[') {
        sf_json *arr;
        if (depth >= SF_JSON_MAX_DEPTH) return NULL;
        arr = sf_json_new_array();
        if (!arr) return NULL;
        p->pos++;
        skip_ws(p);
        if (p->pos < p->len && p->s[p->pos] == ']') { p->pos++; return arr; }
        for (;;) {
            sf_json *val = parse_value(p, depth + 1);
            if (!val) { sf_json_free(arr); return NULL; }
            if (!sf_json_array_append(arr, val)) {
                sf_json_free(val); sf_json_free(arr); return NULL;
            }
            skip_ws(p);
            if (p->pos < p->len && p->s[p->pos] == ',') { p->pos++; continue; }
            if (p->pos < p->len && p->s[p->pos] == ']') { p->pos++; return arr; }
            sf_json_free(arr); return NULL;
        }
    }
    if (c == '"') {
        char *s = parse_string_raw(p);
        sf_json *node;
        if (!s) return NULL;
        node = alloc_node(SFJSON_STRING);
        if (!node) { free(s); return NULL; }
        node->string = s;
        return node;
    }
    if (c == 't') {
        if (!consume_lit(p, "true")) return NULL;
        return sf_json_new_bool(true);
    }
    if (c == 'f') {
        if (!consume_lit(p, "false")) return NULL;
        return sf_json_new_bool(false);
    }
    if (c == 'n') {
        if (!consume_lit(p, "null")) return NULL;
        return sf_json_new_null();
    }
    if (c == '-' || (c >= '0' && c <= '9')) return parse_number(p);
    return NULL;
}

sf_json *sf_json_parse(const char *text) {
    sf_parser p;
    sf_json *v;
    if (!text) return NULL;
    p.len = strlen(text);
    if (p.len > SF_JSON_MAX_INPUT) return NULL;
    p.s = text;
    p.pos = 0;
    v = parse_value(&p, 0);
    if (!v) return NULL;
    skip_ws(&p);
    if (p.pos != p.len) { sf_json_free(v); return NULL; } // trailing garbage
    return v;
}

// ------------------------------------------------------------ serializer

typedef struct { char *buf; size_t len; size_t cap; bool oom; } sf_obuf;

static void obuf_put(sf_obuf *b, const char *data, size_t n) {
    if (b->oom) return;
    if (b->len + n + 1 > b->cap) {
        size_t ncap = b->cap ? b->cap : 64;
        char *nb;
        while (ncap < b->len + n + 1) ncap *= 2;
        nb = (char *)realloc(b->buf, ncap);
        if (!nb) { b->oom = true; return; }
        b->buf = nb;
        b->cap = ncap;
    }
    memcpy(b->buf + b->len, data, n);
    b->len += n;
    b->buf[b->len] = '\0';
}
static void obuf_puts(sf_obuf *b, const char *s) { obuf_put(b, s, strlen(s)); }
static void obuf_putc(sf_obuf *b, char c) { obuf_put(b, &c, 1); }

static void ser_string(sf_obuf *b, const char *s) {
    const unsigned char *u = (const unsigned char *)s;
    obuf_putc(b, '"');
    while (*u) {
        unsigned char c = *u++;
        switch (c) {
            case '"':  obuf_puts(b, "\\\""); break;
            case '\\': obuf_puts(b, "\\\\"); break;
            case '\b': obuf_puts(b, "\\b"); break;
            case '\f': obuf_puts(b, "\\f"); break;
            case '\n': obuf_puts(b, "\\n"); break;
            case '\r': obuf_puts(b, "\\r"); break;
            case '\t': obuf_puts(b, "\\t"); break;
            default:
                if (c < 0x20) {
                    char tmp[8];
                    snprintf(tmp, sizeof tmp, "\\u%04x", c);
                    obuf_puts(b, tmp);
                } else {
                    obuf_putc(b, (char)c);
                }
                break;
        }
    }
    obuf_putc(b, '"');
}

static void ser_number(sf_obuf *b, double n) {
    char tmp[64];
    if (!sf_is_finite(n)) { b->oom = true; return; } // signal failure via oom flag
    if (n >= -9223372036854775808.0 && n < 9223372036854775808.0) {
        int64_t iv = (int64_t)n;
        if ((double)iv == n) {
            snprintf(tmp, sizeof tmp, "%lld", (long long)iv);
            obuf_puts(b, tmp);
            return;
        }
    }
    {
        int prec;
        for (prec = 1; prec <= 17; prec++) {
            snprintf(tmp, sizeof tmp, "%.*g", prec, n);
            if (strtod(tmp, NULL) == n) break;
        }
        obuf_puts(b, tmp);
    }
}

static void ser_value(sf_obuf *b, const sf_json *v) {
    size_t i;
    if (b->oom) return;
    switch (v->type) {
        case SFJSON_NULL: obuf_puts(b, "null"); break;
        case SFJSON_BOOL: obuf_puts(b, v->boolean ? "true" : "false"); break;
        case SFJSON_NUMBER: ser_number(b, v->number); break;
        case SFJSON_STRING: ser_string(b, v->string ? v->string : ""); break;
        case SFJSON_ARRAY:
            obuf_putc(b, '[');
            for (i = 0; i < v->count; i++) {
                if (i) obuf_putc(b, ',');
                ser_value(b, v->items[i]);
            }
            obuf_putc(b, ']');
            break;
        case SFJSON_OBJECT:
            obuf_putc(b, '{');
            for (i = 0; i < v->count; i++) {
                if (i) obuf_putc(b, ',');
                ser_string(b, v->keys[i]);
                obuf_putc(b, ':');
                ser_value(b, v->items[i]);
            }
            obuf_putc(b, '}');
            break;
    }
}

char *sf_json_stringify(const sf_json *v) {
    sf_obuf b;
    if (!v) return NULL;
    b.buf = NULL; b.len = 0; b.cap = 0; b.oom = false;
    ser_value(&b, v);
    if (b.oom || !b.buf) { free(b.buf); return NULL; }
    return b.buf;
}
