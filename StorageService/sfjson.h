// sfjson.h — a small, strict JSON model: parser + serializer for the
// exact subset the REST surface uses (design record 03 §8). Objects,
// arrays, strings, numbers, bools, null. Depth-capped and size-capped;
// duplicate object keys are rejected (strictness beats cleverness).
#ifndef SFJSON_H
#define SFJSON_H

#include "sfcommon.h"

typedef enum {
    SFJSON_NULL, SFJSON_BOOL, SFJSON_NUMBER, SFJSON_STRING,
    SFJSON_ARRAY, SFJSON_OBJECT
} sf_json_type;

typedef struct sf_json sf_json;
struct sf_json {
    sf_json_type type;
    bool     boolean;        // SFJSON_BOOL
    double   number;         // SFJSON_NUMBER
    char    *string;         // SFJSON_STRING (owned, UTF-8, NUL-term)
    sf_json **items;         // ARRAY/OBJECT values (owned)
    char    **keys;          // OBJECT keys (owned); NULL for arrays
    size_t   count;
};

// Parse NUL-terminated text. Returns NULL on any malformed input.
// max input 1 MiB, max depth 32 (enforced internally).
sf_json *sf_json_parse(const char *text);
void     sf_json_free(sf_json *v);

// Construction.
sf_json *sf_json_new_null(void);
sf_json *sf_json_new_bool(bool b);
sf_json *sf_json_new_number(double n);
sf_json *sf_json_new_string(const char *s);
sf_json *sf_json_new_array(void);
sf_json *sf_json_new_object(void);
// Takes ownership of `value` on success. For objects, copies `key`.
bool sf_json_array_append(sf_json *arr, sf_json *value);
bool sf_json_object_set(sf_json *obj, const char *key, sf_json *value);

// Access (NULL-safe; return NULL / fallback when type mismatches).
const sf_json *sf_json_object_get(const sf_json *obj, const char *key);
const char    *sf_json_get_string(const sf_json *obj, const char *key);
bool           sf_json_get_bool(const sf_json *obj, const char *key, bool dflt);
bool           sf_json_get_int64(const sf_json *obj, const char *key, int64_t *out);
bool           sf_json_is_null_or_absent(const sf_json *obj, const char *key);

// Serialize. Caller frees. Integers that are integral doubles print
// without a fraction (ids and byte counts must round-trip exactly for
// values < 2^53, which covers this domain).
char *sf_json_stringify(const sf_json *v);

#endif // SFJSON_H
