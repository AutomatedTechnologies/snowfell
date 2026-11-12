// sfroutes.c — the complete /v1 REST surface (design record 03 §8).
// Per-method handlers are registered for the /v1 tree and dispatch
// internally by path segments. Discipline enforced here:
//   - bearer resolution via sfauth; 401 unauthenticated
//   - rate limiting (login + per-token API)
//   - role/scope rules; a non-operator {tid} must equal the caller's
//     tenant, checked before any tenant-data store call; cross-tenant
//     misses are 404 not_found with the standard body
//   - success/error envelopes and error codes exactly per §8
//   - cursor pagination (limit 1..200, default 50, meta.next_cursor)
//   - audit rows for every mutation and every denied attempt
// Object PUT is the one raw-body route: the body is spooled to a temp
// file in the data dir (64 KiB chunks, SHA-256 while spooling), quota
// is pre-checked from Content-Length with overwrite credit, and a
// store failure after the byte write is compensated by an adapter
// delete (design §7.1).
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE 1

#include "sfroutes.h"

#include "sfadapter.h"
#include "sfauth.h"
#include "sfblob.h"
#include "sfcms.h"
#include "sfjson.h"
#include "sfsha256.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

// ------------------------------------------------------------ app ctx

sf_app_ctx *sf_app_ctx_new(sf_store *store, const char *data_dir) {
    sf_app_ctx *ctx = (sf_app_ctx *)calloc(1, sizeof *ctx);
    if (!ctx) return NULL;
    ctx->store = store;
    size_t dn = strlen(data_dir) + 1;
    ctx->data_dir = (char *)malloc(dn);
    if (!ctx->data_dir) { free(ctx); return NULL; }
    memcpy(ctx->data_dir, data_dir, dn);
    char bp[4096];
    snprintf(bp, sizeof bp, "%s/bootstrap-operator-token.txt", data_dir);
    size_t bn = strlen(bp) + 1;
    ctx->bootstrap_path = (char *)malloc(bn);
    if (ctx->bootstrap_path) memcpy(ctx->bootstrap_path, bp, bn);
    snprintf(ctx->bind_label, sizeof ctx->bind_label, "127.0.0.1:8471");
    ctx->start_unix = sf_now_unix();
    return ctx;
}

void sf_app_ctx_free(sf_app_ctx *ctx) {
    if (!ctx) return;
    free(ctx->data_dir);
    free(ctx->bootstrap_path);
    free(ctx);
}

// ------------------------------------------------------------- helpers

static char *xstrdup(const char *s) {
    if (!s) return NULL;
    size_t n = strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (p) memcpy(p, s, n);
    return p;
}

// Actor of the request currently being handled (single-threaded core).
static char g_actor_ref[160] = "-";

static void log_line(sf_app_ctx *ctx, const char *method, const char *path,
                     int status) {
    if (!ctx || !ctx->data_dir) return;
    char lp[4096];
    snprintf(lp, sizeof lp, "%s/service.log", ctx->data_dir);
    FILE *f = fopen(lp, "a");
    if (!f) return;
    sf_time ts;
    sf_now_iso(ts);
    // Method, path, status, actor ref only — never headers, tokens,
    // passwords, or bodies (design §5 / task logging rule).
    fprintf(f, "%s %s %s -> %d actor=%s\n", ts, method ? method : "?",
            path ? path : "?", status, g_actor_ref);
    fclose(f);
}

static void jset(sf_json *obj, const char *key, sf_json *val) {
    if (!val) return;
    if (!sf_json_object_set(obj, key, val)) sf_json_free(val);
}
static void jstr(sf_json *obj, const char *key, const char *s) {
    jset(obj, key, sf_json_new_string(s ? s : ""));
}
static void jnum(sf_json *obj, const char *key, int64_t v) {
    jset(obj, key, sf_json_new_number((double)v));
}
static void jbool(sf_json *obj, const char *key, int b) {
    jset(obj, key, sf_json_new_bool(b != 0));
}
static void jnull(sf_json *obj, const char *key) {
    jset(obj, key, sf_json_new_null());
}
static void jtime_or_null(sf_json *obj, const char *key, const char *t) {
    if (t && t[0]) jstr(obj, key, t);
    else jnull(obj, key);
}

// The respond_* helpers BORROW the caller's sf_json nodes: they
// serialize without taking ownership, and the caller frees its nodes
// after the call. (Attaching the node to an envelope tree and freeing
// the tree would free the caller's node too — a double-free at every
// call site that also frees, which is all of them.)
static void respond_body_text(sf_http_response *resp, int status, char *text) {
    resp->status = status;
    snprintf(resp->content_type, sizeof resp->content_type, "application/json");
    if (!text) text = xstrdup("{\"error\":{\"code\":\"internal\",\"message\":\"internal error\",\"detail\":{}}}");
    sf_http_response_set_body(resp, (uint8_t *)text, strlen(text));
}

static void respond_data(sf_http_response *resp, int status, sf_json *data) {
    char *inner = data ? sf_json_stringify(data) : NULL;
    if (!inner) inner = xstrdup("null");
    size_t cap = strlen(inner) + 16;
    char *out = (char *)malloc(cap);
    if (!out) { free(inner); respond_body_text(resp, 500, NULL); return; }
    snprintf(out, cap, "{\"data\":%s}", inner);
    free(inner);
    respond_body_text(resp, status, out);
}

static void respond_list(sf_http_response *resp, sf_json *arr,
                         const char *next_cursor) {
    char *inner = arr ? sf_json_stringify(arr) : NULL;
    if (!inner) inner = xstrdup("[]");
    size_t cap = strlen(inner) + 128;
    char *out = (char *)malloc(cap);
    if (!out) { free(inner); respond_body_text(resp, 500, NULL); return; }
    if (next_cursor) {
        // next_cursor is a numeric id string built by page_cursor.
        snprintf(out, cap, "{\"data\":%s,\"meta\":{\"next_cursor\":\"%s\"}}",
                 inner, next_cursor);
    } else {
        snprintf(out, cap, "{\"data\":%s,\"meta\":{\"next_cursor\":null}}", inner);
    }
    free(inner);
    respond_body_text(resp, 200, out);
}

static void respond_error(sf_http_response *resp, int status, const char *code,
                          const char *message, sf_json *detail) {
    // code/message are internal constants (no characters needing escape).
    char *det = detail ? sf_json_stringify(detail) : NULL;
    if (!det) det = xstrdup("{}");
    size_t cap = strlen(det) + strlen(code) + strlen(message) + 64;
    char *out = (char *)malloc(cap);
    if (!out) { free(det); respond_body_text(resp, 500, NULL); return; }
    snprintf(out, cap, "{\"error\":{\"code\":\"%s\",\"message\":\"%s\",\"detail\":%s}}",
             code, message, det);
    free(det);
    respond_body_text(resp, status, out);
}

// Map a store/auth result to the §8 error envelope.
static void respond_result_error(sf_http_response *resp, sf_result r) {
    switch (r) {
        case SF_ERR_NOT_FOUND:
            respond_error(resp, 404, "not_found", "not found", NULL); break;
        case SF_ERR_CONFLICT:
            respond_error(resp, 409, "conflict", "conflict", NULL); break;
        case SF_ERR_VALIDATION:
            respond_error(resp, 400, "validation", "validation failed", NULL); break;
        case SF_ERR_QUOTA:
            respond_error(resp, 409, "quota_exceeded", "quota exceeded", NULL); break;
        case SF_ERR_AUTH:
            respond_error(resp, 401, "unauthenticated", "unauthenticated", NULL); break;
        case SF_ERR_LOCKED:
            respond_error(resp, 429, "account_locked", "account locked", NULL); break;
        case SF_ERR_FORBIDDEN:
            respond_error(resp, 403, "forbidden", "forbidden", NULL); break;
        case SF_ERR_TENANT_STATE:
            respond_error(resp, 403, "tenant_not_active", "tenant not active", NULL); break;
        case SF_ERR_BACKEND:
            respond_error(resp, 502, "backend_unavailable", "backend unavailable", NULL); break;
        case SF_ERR_TOO_LARGE:
            respond_error(resp, 413, "payload_too_large", "payload too large", NULL); break;
        default:
            respond_error(resp, 500, "internal", "internal error", NULL); break;
    }
}

static void audit(sf_app_ctx *ctx, int64_t tenant_id,
                  const sf_caller *caller, const char *action,
                  const char *object_ref, const char *result,
                  const char *detail_json, const char *ip) {
    const char *kind = "system";
    const char *ref = "system";
    // §13.8: actor_ref is opaque — `login:<id>`, never a username.
    char refbuf[64];
    if (caller) {
        if (caller->is_operator) { kind = "operator"; ref = "operator"; }
        else {
            kind = "login";
            snprintf(refbuf, sizeof refbuf, "login:%lld",
                     (long long)caller->login_id);
            ref = refbuf;
        }
    }
    sf_store_audit(ctx->store, tenant_id, kind, ref, action,
                   object_ref ? object_ref : "", result,
                   detail_json ? detail_json : "{}", ip);
}

static void audit_system(sf_app_ctx *ctx, int64_t tenant_id, const char *action,
                         const char *object_ref, const char *result,
                         const char *detail_json, const char *ip) {
    sf_store_audit(ctx->store, tenant_id, "system", "system", action,
                   object_ref ? object_ref : "", result,
                   detail_json ? detail_json : "{}", ip);
}

// Parse the request JSON body; NULL (with a 400 invalid_json response
// already written) on failure.
static sf_json *parse_body(sf_http_response *resp, const sf_http_request *req) {
    if (!req->body || req->body_len == 0) {
        respond_error(resp, 400, "invalid_json", "request body must be a JSON object", NULL);
        return NULL;
    }
    char *text = (char *)malloc(req->body_len + 1);
    if (!text) {
        respond_error(resp, 500, "internal", "out of memory", NULL);
        return NULL;
    }
    memcpy(text, req->body, req->body_len);
    text[req->body_len] = '\0';
    sf_json *v = sf_json_parse(text);
    free(text);
    if (!v) {
        respond_error(resp, 400, "invalid_json", "malformed JSON body", NULL);
        return NULL;
    }
    if (v->type != SFJSON_OBJECT) {
        sf_json_free(v);
        respond_error(resp, 400, "invalid_json", "request body must be a JSON object", NULL);
        return NULL;
    }
    return v;
}

static int parse_pagination(const sf_http_request *req, sf_http_response *resp,
                            int *limit_out, int64_t *cursor_out) {
    char buf[64];
    *limit_out = 50;
    *cursor_out = 0;
    if (sf_http_query(req, "limit", buf, sizeof buf)) {
        char *endp = NULL;
        long v = strtol(buf, &endp, 10);
        if (endp == buf || *endp != '\0' || v < 1 || v > 200) {
            respond_error(resp, 400, "validation", "limit must be 1..200", NULL);
            return 0;
        }
        *limit_out = (int)v;
    }
    if (sf_http_query(req, "cursor", buf, sizeof buf)) {
        char *endp = NULL;
        long long v = strtoll(buf, &endp, 10);
        if (endp == buf || *endp != '\0' || v < 0) {
            respond_error(resp, 400, "validation", "cursor must be a non-negative id", NULL);
            return 0;
        }
        *cursor_out = (int64_t)v;
    }
    return 1;
}

// next_cursor value when a page came back full, else NULL.
static const char *page_cursor(size_t count, int limit, int64_t last_id,
                               char *buf, size_t cap) {
    if ((int)count < limit) return NULL;
    snprintf(buf, cap, "%lld", (long long)last_id);
    return buf;
}

// Extract the bearer token ( malloc'd ) or NULL.
static char *bearer_token(const sf_http_request *req) {
    const char *auth = sf_http_header(req, "Authorization");
    if (!auth) return NULL;
    if (strncasecmp(auth, "Bearer ", 7) != 0) return NULL;
    const char *tok = auth + 7;
    while (*tok == ' ') tok++;
    if (!*tok) return NULL;
    return xstrdup(tok);
}

// Resolve the caller. On failure the error response is written and 0
// returned. Options: allow_any_state skips the tenant-state gate
// (logout). API rate limiting is applied here for every caller.
static int require_auth(sf_app_ctx *ctx, const sf_http_request *req,
                        sf_http_response *resp, sf_caller *caller,
                        int allow_any_state) {
    char *tok = bearer_token(req);
    if (!tok) {
        respond_error(resp, 401, "unauthenticated", "missing bearer token", NULL);
        return 0;
    }
    sf_result r = sf_auth_resolve_token(ctx->store, tok, caller);
    free(tok);
    if (r != SF_OK) {
        respond_error(resp, 401, "unauthenticated", "invalid or expired token", NULL);
        return 0;
    }
    if (caller->is_operator) {
        snprintf(g_actor_ref, sizeof g_actor_ref, "operator");
        if (sf_auth_note_operator_authenticated() == 1 && ctx->bootstrap_path) {
            unlink(ctx->bootstrap_path); // bootstrap file's job is done (§5.5)
        }
    } else {
        // §13.8: log lines carry the opaque actor id, not slug/username.
        snprintf(g_actor_ref, sizeof g_actor_ref, "login:%lld",
                 (long long)caller->login_id);
    }
    int retry = 0;
    if (!sf_rate_allow_api(caller->token_id, &retry)) {
        char ra[24];
        snprintf(ra, sizeof ra, "%d", retry > 0 ? retry : 60);
        sf_http_response_set_header(resp, "Retry-After", ra);
        sf_json *d = sf_json_new_object();
        jnum(d, "retry_after_seconds", retry > 0 ? retry : 60);
        respond_error(resp, 429, "rate_limited", "rate limit exceeded", d);
        sf_json_free(d);
        audit(ctx, caller->is_operator ? -1 : caller->tenant_id, caller,
              "api.rate_limited", "", "denied", "{}", req->remote_ip);
        return 0;
    }
    if (!caller->is_operator && !allow_any_state) {
        sf_tenant t;
        if (sf_store_get_tenant(ctx->store, caller->tenant_id, &t) == SF_OK) {
            int is_write = strcmp(req->method, "GET") != 0 &&
                           strcmp(req->method, "HEAD") != 0;
            if (strcmp(t.state, "closed") == 0) {
                respond_error(resp, 403, "tenant_not_active", "tenant is closed", NULL);
                return 0;
            }
            if (strcmp(t.state, "suspended") == 0 &&
                (is_write || strcmp(caller->role, "tenant_admin") != 0)) {
                respond_error(resp, 403, "tenant_not_active", "tenant is suspended", NULL);
                return 0;
            }
        }
    }
    return 1;
}

// Resolve a {tid} path segment (integer id or slug). On success *out
// is filled and 1 returned. For non-operators a tenant other than
// their own is a 404 — checked here, before any tenant-data call.
static int resolve_tenant(sf_app_ctx *ctx, const sf_http_request *req,
                          sf_http_response *resp, const sf_caller *caller,
                          const char *segment, sf_tenant *out) {
    int all_digits = segment && segment[0];
    if (all_digits) {
        for (const char *p = segment; *p; p++) {
            if (!isdigit((unsigned char)*p)) { all_digits = 0; break; }
        }
    }
    sf_result r;
    if (all_digits) r = sf_store_get_tenant(ctx->store, strtoll(segment, NULL, 10), out);
    else r = sf_store_get_tenant_by_slug(ctx->store, segment, out);
    if (r != SF_OK) {
        respond_error(resp, 404, "not_found", "tenant not found", NULL);
        return 0;
    }
    if (!caller->is_operator && out->id != caller->tenant_id) {
        respond_error(resp, 404, "not_found", "tenant not found", NULL);
        audit(ctx, caller->tenant_id, caller, "tenant.cross_tenant_probe",
              segment, "denied", "{}", req->remote_ip);
        return 0;
    }
    return 1;
}

static int require_operator(const sf_http_request *req, sf_http_response *resp,
                            sf_app_ctx *ctx, const sf_caller *caller,
                            const char *action) {
    if (caller->is_operator) return 1;
    respond_error(resp, 403, "forbidden", "operator only", NULL);
    audit(ctx, caller->tenant_id, caller, action, "", "denied", "{}", req->remote_ip);
    return 0;
}

static int require_tenant_admin_or_operator(const sf_http_request *req,
                                            sf_http_response *resp,
                                            sf_app_ctx *ctx, const sf_caller *caller,
                                            const char *action) {
    if (caller->is_operator) return 1;
    if (strcmp(caller->role, "tenant_admin") == 0) return 1;
    respond_error(resp, 403, "forbidden", "tenant admin or operator only", NULL);
    audit(ctx, caller->tenant_id, caller, action, "", "denied", "{}", req->remote_ip);
    return 0;
}

// ----------------------------------------------------------- serializers

static sf_json *tenant_json(const sf_tenant *t) {
    sf_json *o = sf_json_new_object();
    jnum(o, "id", t->id);
    jstr(o, "slug", t->slug);
    jstr(o, "display_name", t->display_name);
    jstr(o, "state", t->state);
    jnum(o, "quota_bytes", t->quota_bytes);
    jnum(o, "quota_objects", t->quota_objects);
    jnum(o, "quota_buckets", t->quota_buckets);
    jstr(o, "contact_note", t->contact_note);
    jstr(o, "created_at", t->created_at);
    jstr(o, "updated_at", t->updated_at);
    return o;
}

static sf_json *login_json(const sf_login *l) {
    sf_json *o = sf_json_new_object();
    jnum(o, "id", l->id);
    jnum(o, "tenant_id", l->tenant_id);
    jstr(o, "username", l->username);
    jstr(o, "display_name", l->display_name);
    jstr(o, "role", l->role);
    jstr(o, "state", l->state);
    jtime_or_null(o, "last_login_at", l->last_login_at);
    jbool(o, "locked", l->locked);
    jstr(o, "created_at", l->created_at);
    jstr(o, "updated_at", l->updated_at);
    return o;
}

static sf_json *backend_json(const sf_backend *b) {
    sf_json *o = sf_json_new_object();
    jnum(o, "id", b->id);
    jstr(o, "name", b->name);
    jstr(o, "kind", b->kind);
    sf_json *cfg = b->config_json ? sf_json_parse(b->config_json) : NULL;
    if (cfg && cfg->type == SFJSON_OBJECT) jset(o, "config", cfg);
    else {
        if (cfg) sf_json_free(cfg);
        jset(o, "config", sf_json_new_object());
    }
    jstr(o, "secret_ref", b->secret_ref); // the env var NAME, never a value
    jstr(o, "state", b->state);
    jstr(o, "created_at", b->created_at);
    jstr(o, "updated_at", b->updated_at);
    return o;
}

static sf_json *bucket_json(const sf_bucket *b) {
    sf_json *o = sf_json_new_object();
    jnum(o, "id", b->id);
    jnum(o, "tenant_id", b->tenant_id);
    jstr(o, "name", b->name);
    jnum(o, "backend_id", b->backend_id);
    jnum(o, "quota_bytes", b->quota_bytes);
    jnum(o, "object_count", b->object_count);
    jnum(o, "total_bytes", b->total_bytes);
    jstr(o, "created_at", b->created_at);
    jstr(o, "updated_at", b->updated_at);
    return o;
}

static sf_json *object_json(const sf_object *ob) {
    sf_json *o = sf_json_new_object();
    jnum(o, "id", ob->id);
    jnum(o, "bucket_id", ob->bucket_id);
    jnum(o, "tenant_id", ob->tenant_id);
    jstr(o, "key", ob->key ? ob->key : "");
    jnum(o, "size_bytes", ob->size_bytes);
    char hex[65];
    sf_hex_encode(ob->sha256, 32, hex);
    jstr(o, "sha256", hex);
    jstr(o, "content_type", ob->content_type);
    sf_json *md = ob->metadata_json ? sf_json_parse(ob->metadata_json) : NULL;
    if (md && md->type == SFJSON_OBJECT) jset(o, "metadata", md);
    else {
        if (md) sf_json_free(md);
        jset(o, "metadata", sf_json_new_object());
    }
    jstr(o, "created_at", ob->created_at);
    jstr(o, "updated_at", ob->updated_at);
    return o;
}

static void free_backend_row(sf_backend *b) {
    if (!b) return;
    free(b->config_json);
    b->config_json = NULL;
}

// ------------------------------------------------------------ validation

static int slug_valid(const char *s) {
    if (!s) return 0;
    size_t n = strlen(s);
    if (n < 1 || n > 64) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!(islower(c) || isdigit(c) || c == '-' || c == '_')) return 0;
    }
    return isalnum((unsigned char)s[0]) != 0;
}

static int username_valid(const char *s) {
    if (!s) return 0;
    size_t n = strlen(s);
    if (n < 1 || n > 64) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!(isalnum(c) || c == '.' || c == '_' || c == '-')) return 0;
    }
    return 1;
}

static int bucket_name_valid(const char *s) {
    if (!s) return 0;
    size_t n = strlen(s);
    if (n < 1 || n > 128) return 0;
    if (!isalnum((unsigned char)s[0])) return 0;
    for (size_t i = 0; i < n; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!(isalnum(c) || c == '.' || c == '_' || c == '-')) return 0;
    }
    return 1;
}

// Quota field: absent -> keep sentinel `dflt`; JSON null -> -1; number -> value.
static int64_t quota_field(const sf_json *body, const char *key, int64_t dflt, int *ok) {
    const sf_json *v = sf_json_object_get(body, key);
    if (!v) return dflt;
    if (v->type == SFJSON_NULL) return -1;
    int64_t out = 0;
    if (!sf_json_get_int64(body, key, &out) || out < -1) { *ok = 0; return dflt; }
    return out;
}

// -------------------------------------------------------------- auth routes

static void h_login(sf_app_ctx *ctx, const sf_http_request *req,
                    sf_http_response *resp) {
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *slug = sf_json_get_string(body, "tenant");
    const char *username = sf_json_get_string(body, "username");
    const char *password = sf_json_get_string(body, "password");
    if (!slug || !slug[0] || !username || !username[0] || !password || !password[0]) {
        sf_json_free(body);
        respond_error(resp, 400, "validation",
                      "tenant, username and password are required", NULL);
        return;
    }
    // Copies: body is freed before the auth calls below return.
    char slug_buf[65], user_buf[65];
    snprintf(slug_buf, sizeof slug_buf, "%s", slug);
    snprintf(user_buf, sizeof user_buf, "%s", username);
    char *pw = xstrdup(password);
    sf_json_free(body);
    if (!pw) { respond_error(resp, 500, "internal", "out of memory", NULL); return; }

    int retry = 0;
    if (!sf_rate_allow_login(req->remote_ip, slug_buf, user_buf, &retry)) {
        char ra[24];
        snprintf(ra, sizeof ra, "%d", retry > 0 ? retry : 60);
        sf_http_response_set_header(resp, "Retry-After", ra);
        sf_json *d = sf_json_new_object();
        jnum(d, "retry_after_seconds", retry > 0 ? retry : 60);
        respond_error(resp, 429, "rate_limited", "login rate limit exceeded", d);
        sf_json_free(d);
        sf_tenant t;
        int64_t tid = (sf_store_get_tenant_by_slug(ctx->store, slug_buf, &t) == SF_OK)
                          ? t.id : -1;
        audit_system(ctx, tid, "auth.login", user_buf, "denied",
                     "{\"reason\":\"rate_limited\"}", req->remote_ip);
        free(pw);
        return;
    }

    sf_login login;
    sf_tenant tenant;
    memset(&login, 0, sizeof login);
    memset(&tenant, 0, sizeof tenant);
    sf_result r = sf_auth_verify_password(ctx->store, slug_buf, user_buf, pw,
                                          req->remote_ip, &login, &tenant);
    memset(pw, 0, strlen(pw));
    free(pw);
    if (r == SF_ERR_LOCKED) {
        char ra[24];
        snprintf(ra, sizeof ra, "%d", SF_LOCK_MINUTES * 60);
        sf_http_response_set_header(resp, "Retry-After", ra);
        sf_json *d = sf_json_new_object();
        jnum(d, "retry_after_seconds", SF_LOCK_MINUTES * 60);
        respond_error(resp, 429, "account_locked",
                      "account is locked after repeated failures", d);
        sf_json_free(d);
        audit_system(ctx, tenant.id > 0 ? tenant.id : -1, "auth.login",
                     user_buf, "denied", "{\"reason\":\"account_locked\"}",
                     req->remote_ip);
        return;
    }
    if (r == SF_ERR_TENANT_STATE) {
        respond_error(resp, 403, "tenant_not_active",
                      "tenant is suspended or closed, or the login is disabled", NULL);
        audit_system(ctx, tenant.id > 0 ? tenant.id : -1, "auth.login",
                     user_buf, "denied", "{\"reason\":\"tenant_not_active\"}",
                     req->remote_ip);
        return;
    }
    if (r != SF_OK) {
        // Wrong password and unknown login are indistinguishable (§5.3).
        respond_error(resp, 401, "invalid_credentials", "invalid credentials", NULL);
        sf_tenant t;
        int64_t tid = (sf_store_get_tenant_by_slug(ctx->store, slug_buf, &t) == SF_OK)
                          ? t.id : -1;
        audit_system(ctx, tid, "auth.login", user_buf, "denied",
                     "{\"reason\":\"invalid_credentials\"}", req->remote_ip);
        return;
    }

    char token[256];
    int64_t token_id = 0;
    sf_time expires;
    expires[0] = '\0';
    r = sf_auth_issue_token(ctx->store, tenant.id, login.id, "session", "", 0,
                            token, sizeof token, &token_id, expires);
    if (r != SF_OK) { respond_result_error(resp, r); return; }

    sf_caller caller;
    memset(&caller, 0, sizeof caller);
    caller.tenant_id = tenant.id;
    caller.login_id = login.id;
    snprintf(caller.username, sizeof caller.username, "%s", login.username);
    snprintf(caller.tenant_slug, sizeof caller.tenant_slug, "%s", tenant.slug);
    char ref[300];
    snprintf(ref, sizeof ref, "login:%lld", (long long)login.id);
    audit(ctx, tenant.id, &caller, "auth.login", ref, "ok", "{}", req->remote_ip);
    snprintf(g_actor_ref, sizeof g_actor_ref, "login:%lld", (long long)login.id);

    sf_json *data = sf_json_new_object();
    jstr(data, "token", token);
    memset(token, 0, sizeof token);
    jnum(data, "token_id", token_id);
    jtime_or_null(data, "expires_at", expires);
    jset(data, "login", login_json(&login));
    jset(data, "tenant", tenant_json(&tenant));
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_logout(sf_app_ctx *ctx, const sf_http_request *req,
                     sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 1)) return;
    char *tok = bearer_token(req);
    if (tok) {
        sf_auth_revoke_presented(ctx->store, tok);
        memset(tok, 0, strlen(tok));
        free(tok);
    }
    audit(ctx, caller.is_operator ? -1 : caller.tenant_id, &caller,
          "auth.logout", "", "ok", "{}", req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "revoked", 1);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_me(sf_app_ctx *ctx, const sf_http_request *req,
                 sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_json *data = sf_json_new_object();
    jbool(data, "is_operator", caller.is_operator);
    if (caller.is_operator) { jnull(data, "tenant_id"); jnull(data, "login_id"); }
    else { jnum(data, "tenant_id", caller.tenant_id); jnum(data, "login_id", caller.login_id); }
    jnum(data, "token_id", caller.token_id);
    jstr(data, "role", caller.role);
    jstr(data, "username", caller.username);
    jstr(data, "tenant_slug", caller.tenant_slug);
    if (!caller.is_operator) {
        sf_login l;
        if (sf_store_get_login(ctx->store, caller.tenant_id, caller.login_id, &l) == SF_OK)
            jset(data, "login", login_json(&l));
        sf_tenant t;
        if (sf_store_get_tenant(ctx->store, caller.tenant_id, &t) == SF_OK)
            jset(data, "tenant", tenant_json(&t));
    }
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_password_change(sf_app_ctx *ctx, const sf_http_request *req,
                              sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (caller.is_operator) {
        respond_error(resp, 403, "forbidden", "operator has no password", NULL);
        return;
    }
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *cur = sf_json_get_string(body, "current_password");
    const char *newp = sf_json_get_string(body, "new_password");
    if (!cur || !cur[0] || !newp || !newp[0]) {
        sf_json_free(body);
        respond_error(resp, 400, "validation",
                      "current_password and new_password are required", NULL);
        return;
    }
    char *cur_dup = xstrdup(cur);
    char *new_dup = xstrdup(newp);
    sf_json_free(body);
    if (!cur_dup || !new_dup) {
        free(cur_dup); free(new_dup);
        respond_error(resp, 500, "internal", "out of memory", NULL);
        return;
    }
    sf_login login;
    sf_tenant tenant;
    sf_result r = sf_auth_verify_password(ctx->store, caller.tenant_slug,
                                          caller.username, cur_dup,
                                          req->remote_ip, &login, &tenant);
    memset(cur_dup, 0, strlen(cur_dup));
    free(cur_dup);
    if (r == SF_ERR_LOCKED) {
        respond_error(resp, 429, "account_locked", "account locked", NULL);
        free(new_dup);
        return;
    }
    if (r != SF_OK) {
        respond_error(resp, 401, "invalid_credentials",
                      "current password is incorrect", NULL);
        audit(ctx, caller.tenant_id, &caller, "auth.password", "", "denied",
              "{\"reason\":\"invalid_credentials\"}", req->remote_ip);
        free(new_dup);
        return;
    }
    r = sf_auth_set_password(ctx->store, caller.tenant_id, caller.login_id, new_dup);
    memset(new_dup, 0, strlen(new_dup));
    free(new_dup);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    // Revoke other sessions, then mint a fresh one so the caller is not
    // stranded (§5.2: password change revokes other sessions).
    sf_auth_revoke_login_tokens(ctx->store, caller.tenant_id, caller.login_id, "session");
    char token[256];
    int64_t token_id = 0;
    sf_time expires;
    expires[0] = '\0';
    r = sf_auth_issue_token(ctx->store, caller.tenant_id, caller.login_id,
                            "session", "", 0, token, sizeof token, &token_id, expires);
    audit(ctx, caller.tenant_id, &caller, "auth.password", "", "ok", "{}", req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "changed", 1);
    if (r == SF_OK) {
        jstr(data, "token", token);
        jnum(data, "token_id", token_id);
        jtime_or_null(data, "expires_at", expires);
    }
    memset(token, 0, sizeof token);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_tokens_create(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (caller.is_operator) {
        respond_error(resp, 403, "forbidden", "operator token is bootstrapped, not minted", NULL);
        return;
    }
    const char *label = "";
    char label_buf[129] = "";
    int64_t ttl = 0;
    if (req->body && req->body_len > 0) {
        sf_json *body = parse_body(resp, req);
        if (!body) return;
        const char *lb = sf_json_get_string(body, "label");
        if (lb) snprintf(label_buf, sizeof label_buf, "%s", lb);
        label = label_buf;
        int64_t days = 0;
        if (sf_json_get_int64(body, "expires_in_days", &days)) {
            if (days <= 0 || days > 3650) {
                sf_json_free(body);
                respond_error(resp, 400, "validation",
                              "expires_in_days must be positive", NULL);
                return;
            }
            ttl = days * 86400;
        }
        sf_json_free(body);
    }
    char token[256];
    int64_t token_id = 0;
    sf_time expires;
    expires[0] = '\0';
    sf_result r = sf_auth_issue_token(ctx->store, caller.tenant_id, caller.login_id,
                                      "api", label, ttl, token, sizeof token,
                                      &token_id, expires);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    audit(ctx, caller.tenant_id, &caller, "auth.token_create", "", "ok", "{}",
          req->remote_ip);
    sf_json *data = sf_json_new_object();
    jstr(data, "token", token);
    memset(token, 0, sizeof token);
    jnum(data, "token_id", token_id);
    jstr(data, "label", label);
    jtime_or_null(data, "expires_at", expires);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

static void h_tokens_list(sf_app_ctx *ctx, const sf_http_request *req,
                          sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (caller.is_operator) {
        respond_error(resp, 403, "forbidden", "operator has no API token list", NULL);
        return;
    }
    sf_token_info *rows = NULL;
    size_t count = 0;
    sf_result r = sf_auth_list_tokens(ctx->store, caller.tenant_id, caller.login_id,
                                      &rows, &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    for (size_t i = 0; i < count; i++) {
        sf_json *o = sf_json_new_object();
        jnum(o, "id", rows[i].id);
        jstr(o, "kind", rows[i].kind);
        jstr(o, "label", rows[i].label);
        jstr(o, "created_at", rows[i].created_at);
        jtime_or_null(o, "expires_at", rows[i].expires_at);
        jtime_or_null(o, "revoked_at", rows[i].revoked_at);
        jtime_or_null(o, "last_used_at", rows[i].last_used_at);
        if (!sf_json_array_append(arr, o)) sf_json_free(o);
    }
    sf_token_info_free_all(rows, count);
    respond_list(resp, arr, NULL);
    sf_json_free(arr);
}

static void h_tokens_delete(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp, const char *id_segment) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (caller.is_operator) {
        respond_error(resp, 403, "forbidden", "operator token is not revocable here", NULL);
        return;
    }
    char *endp = NULL;
    long long id = strtoll(id_segment, &endp, 10);
    if (endp == id_segment || *endp != '\0' || id <= 0) {
        respond_error(resp, 404, "not_found", "token not found", NULL);
        return;
    }
    sf_result r = sf_auth_revoke_token(ctx->store, &caller, (int64_t)id);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    audit(ctx, caller.tenant_id, &caller, "auth.token_revoke", id_segment, "ok", "{}",
          req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "revoked", 1);
    jnum(data, "token_id", (int64_t)id);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_reset_complete(sf_app_ctx *ctx, const sf_http_request *req,
                             sf_http_response *resp) {
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *tok = sf_json_get_string(body, "token");
    const char *newp = sf_json_get_string(body, "new_password");
    if (!tok || !tok[0] || !newp || !newp[0]) {
        sf_json_free(body);
        respond_error(resp, 400, "validation", "token and new_password are required", NULL);
        return;
    }
    char *tok_dup = xstrdup(tok);
    char *new_dup = xstrdup(newp);
    sf_json_free(body);
    if (!tok_dup || !new_dup) {
        free(tok_dup); free(new_dup);
        respond_error(resp, 500, "internal", "out of memory", NULL);
        return;
    }
    sf_result r = sf_auth_complete_reset(ctx->store, tok_dup, new_dup, req->remote_ip);
    memset(tok_dup, 0, strlen(tok_dup));
    memset(new_dup, 0, strlen(new_dup));
    free(tok_dup);
    free(new_dup);
    if (r != SF_OK) {
        audit_system(ctx, -1, "auth.password_reset_complete", "", "denied",
                     "{\"reason\":\"invalid_or_expired_token\"}", req->remote_ip);
        // §13.7 ruling: a reset token is a credential — an unknown,
        // expired, or replayed token is 401 invalid_credentials, not
        // 400 validation. (A malformed JSON body still 400s in
        // parse_body above.)
        if (r == SF_ERR_AUTH) {
            respond_error(resp, 401, "invalid_credentials",
                          "reset token is invalid, expired, or already used", NULL);
        } else {
            respond_result_error(resp, r);
        }
        return;
    }
    audit_system(ctx, -1, "auth.password_reset_complete", "", "ok", "{}", req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "reset", 1);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

// ------------------------------------------------------------ tenant routes

static void revoke_tenant_tokens(sf_app_ctx *ctx, int64_t tenant_id) {
    int64_t cursor = 0;
    for (;;) {
        sf_login *rows = NULL;
        size_t count = 0;
        if (sf_store_list_logins(ctx->store, tenant_id, cursor, 200, &rows, &count) != SF_OK)
            return;
        if (count == 0) { sf_login_free_all(rows, 0); return; }
        for (size_t i = 0; i < count; i++) {
            sf_auth_revoke_login_tokens(ctx->store, tenant_id, rows[i].id, NULL);
            cursor = rows[i].id;
        }
        sf_login_free_all(rows, count);
        if (count < 200) return;
    }
}

static void h_tenants_create(sf_app_ctx *ctx, const sf_http_request *req,
                             sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (!require_operator(req, resp, ctx, &caller, "tenant.create")) return;
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *slug = sf_json_get_string(body, "slug");
    const char *display = sf_json_get_string(body, "display_name");
    const char *note = sf_json_get_string(body, "contact_note");
    if (!slug_valid(slug) || !display || !display[0]) {
        sf_json_free(body);
        respond_error(resp, 400, "validation",
                      "slug (lowercase url-safe) and display_name are required", NULL);
        return;
    }
    int ok = 1;
    int64_t qb = quota_field(body, "quota_bytes", -1, &ok);
    int64_t qo = quota_field(body, "quota_objects", -1, &ok);
    int64_t qk = quota_field(body, "quota_buckets", -1, &ok);
    if (!ok) {
        sf_json_free(body);
        respond_error(resp, 400, "validation", "quota values must be integers >= -1", NULL);
        return;
    }
    // Copy the slug BEFORE the body is freed: the conflict-path audit
    // below needs it after sf_json_free(body) (SF-T12g use-after-free —
    // `slug` points into the parsed body).
    char slug_buf[65];
    snprintf(slug_buf, sizeof slug_buf, "%s", slug);
    sf_tenant t;
    sf_result r = sf_store_create_tenant(ctx->store, slug, display, qb, qo, qk,
                                         note ? note : "", &t);
    sf_json_free(body);
    if (r == SF_ERR_CONFLICT) {
        respond_error(resp, 409, "conflict", "a tenant with that slug already exists", NULL);
        audit(ctx, -1, &caller, "tenant.create", slug_buf, "denied",
              "{\"reason\":\"duplicate_slug\"}", req->remote_ip);
        return;
    }
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "tenant:%lld", (long long)t.id);
    audit(ctx, t.id, &caller, "tenant.create", ref, "ok", "{}", req->remote_ip);
    sf_json *data = tenant_json(&t);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

static void h_tenants_list(sf_app_ctx *ctx, const sf_http_request *req,
                           sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (!require_operator(req, resp, ctx, &caller, "tenant.list")) return;
    int limit;
    int64_t cursor;
    if (!parse_pagination(req, resp, &limit, &cursor)) return;
    sf_tenant *rows = NULL;
    size_t count = 0;
    sf_result r = sf_store_list_tenants(ctx->store, cursor, limit, &rows, &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    int64_t last = 0;
    for (size_t i = 0; i < count; i++) {
        if (!sf_json_array_append(arr, tenant_json(&rows[i]))) break;
        last = rows[i].id;
    }
    sf_tenant_free_all(rows, count);
    char cbuf[32];
    respond_list(resp, arr, page_cursor(count, limit, last, cbuf, sizeof cbuf));
    sf_json_free(arr);
}

static void h_tenant_get(sf_app_ctx *ctx, const sf_http_request *req,
                         sf_http_response *resp, const char *tid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_operator(req, resp, ctx, &caller, "tenant.get")) return;
    sf_json *data = tenant_json(&t);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_tenant_patch(sf_app_ctx *ctx, const sf_http_request *req,
                           sf_http_response *resp, const char *tid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_operator(req, resp, ctx, &caller, "tenant.update")) return;
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *display = sf_json_get_string(body, "display_name");
    const char *state = sf_json_get_string(body, "state");
    const char *note = sf_json_get_string(body, "contact_note");
    if (state && strcmp(state, "active") != 0 && strcmp(state, "suspended") != 0 &&
        strcmp(state, "closed") != 0) {
        sf_json_free(body);
        respond_error(resp, 400, "validation",
                      "state must be active, suspended, or closed", NULL);
        return;
    }
    char state_buf[16] = "";
    if (state) snprintf(state_buf, sizeof state_buf, "%s", state);
    sf_result r = sf_store_update_tenant(ctx->store, t.id, display,
                                         state ? state_buf : NULL, note);
    sf_json_free(body);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    if (state && strcmp(state_buf, "active") != 0 &&
        strcmp(t.state, state_buf) != 0) {
        revoke_tenant_tokens(ctx, t.id);
    }
    char ref[300];
    snprintf(ref, sizeof ref, "tenant:%lld", (long long)t.id);
    audit(ctx, t.id, &caller, "tenant.update", ref, "ok", "{}", req->remote_ip);
    sf_tenant after;
    if (sf_store_get_tenant(ctx->store, t.id, &after) == SF_OK) {
        sf_json *data = tenant_json(&after);
        respond_data(resp, 200, data);
        sf_json_free(data);
    } else {
        sf_json *data = sf_json_new_object();
        jnum(data, "id", t.id);
        respond_data(resp, 200, data);
        sf_json_free(data);
    }
}

static void h_tenant_delete(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp, const char *tid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_operator(req, resp, ctx, &caller, "tenant.close")) return;
    // DELETE = close only; tenants are never hard-deleted with data (§8).
    sf_result r = sf_store_update_tenant(ctx->store, t.id, NULL, "closed", NULL);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    revoke_tenant_tokens(ctx, t.id);
    char ref[300];
    snprintf(ref, sizeof ref, "tenant:%lld", (long long)t.id);
    audit(ctx, t.id, &caller, "tenant.close", ref, "ok", "{}", req->remote_ip);
    sf_tenant after;
    if (sf_store_get_tenant(ctx->store, t.id, &after) == SF_OK) {
        sf_json *data = tenant_json(&after);
        respond_data(resp, 200, data);
        sf_json_free(data);
    } else {
        sf_json *data = sf_json_new_object();
        jnum(data, "id", t.id);
        jstr(data, "state", "closed");
        respond_data(resp, 200, data);
        sf_json_free(data);
    }
}

static void h_tenant_usage(sf_app_ctx *ctx, const sf_http_request *req,
                           sf_http_response *resp, const char *tid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!caller.is_operator && strcmp(caller.role, "tenant_admin") != 0) {
        respond_error(resp, 403, "forbidden", "tenant admin or operator only", NULL);
        audit(ctx, t.id, &caller, "tenant.usage", "", "denied", "{}", req->remote_ip);
        return;
    }
    // Bucket counters (sf_store_tenant_usage) are reference-side
    // figures: they count object references and their logical bytes,
    // exactly as in schema v1. The tenant's physical truth — and the
    // quota truth (§13.6) — derives from cs_blobs: used_bytes below
    // is physical, and the dedup block carries both sides.
    int64_t logical_bytes = 0, used_objects = 0, bucket_rows = 0;
    sf_result r = sf_store_tenant_usage(ctx->store, t.id, &logical_bytes,
                                        &used_objects, &bucket_rows);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_dedup_stats dedup;
    memset(&dedup, 0, sizeof dedup);
    dedup.dedup_ratio = 1.0;
    sf_blob_accounting(ctx->store, t.id, &dedup);
    int64_t eb, eo, ek;
    sf_tenant_effective_quota(&t, &eb, &eo, &ek);
    sf_json *data = sf_json_new_object();
    jnum(data, "tenant_id", t.id);
    jnum(data, "quota_bytes", eb);
    jnum(data, "quota_objects", eo);
    jnum(data, "quota_buckets", ek);
    jnum(data, "used_bytes", dedup.physical_bytes);
    jnum(data, "used_objects", used_objects);
    jnum(data, "bucket_count", bucket_rows);
    sf_json *dd = sf_json_new_object();
    jnum(dd, "logical_bytes", dedup.logical_bytes);
    jnum(dd, "physical_bytes", dedup.physical_bytes);
    jnum(dd, "bytes_saved", dedup.bytes_saved);
    jset(dd, "dedup_ratio", sf_json_new_number(dedup.dedup_ratio));
    jnum(dd, "blob_count", dedup.blob_count);
    jnum(dd, "reference_count", dedup.reference_count);
    jset(data, "dedup", dd);
    sf_json *barr = sf_json_new_array();
    int64_t cursor = 0;
    for (;;) {
        sf_bucket *rows = NULL;
        size_t count = 0;
        if (sf_store_list_buckets(ctx->store, t.id, cursor, 200, &rows, &count) != SF_OK)
            break;
        for (size_t i = 0; i < count; i++) {
            sf_json *b = sf_json_new_object();
            jnum(b, "bucket_id", rows[i].id);
            jstr(b, "name", rows[i].name);
            jnum(b, "object_count", rows[i].object_count);
            jnum(b, "total_bytes", rows[i].total_bytes);
            jnum(b, "quota_bytes", rows[i].quota_bytes);
            if (!sf_json_array_append(barr, b)) sf_json_free(b);
            cursor = rows[i].id;
        }
        sf_bucket_free_all(rows, count);
        if (count < 200) break;
    }
    jset(data, "buckets", barr);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_tenant_quota(sf_app_ctx *ctx, const sf_http_request *req,
                           sf_http_response *resp, const char *tid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_operator(req, resp, ctx, &caller, "tenant.quota")) return;
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    int ok = 1;
    int64_t qb = quota_field(body, "quota_bytes", -1, &ok);
    int64_t qo = quota_field(body, "quota_objects", -1, &ok);
    int64_t qk = quota_field(body, "quota_buckets", -1, &ok);
    sf_json_free(body);
    if (!ok) {
        respond_error(resp, 400, "validation", "quota values must be integers >= -1", NULL);
        return;
    }
    sf_result r = sf_store_set_tenant_quota(ctx->store, t.id, qb, qo, qk);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char detail[160];
    snprintf(detail, sizeof detail,
             "{\"quota_bytes\":%lld,\"quota_objects\":%lld,\"quota_buckets\":%lld}",
             (long long)qb, (long long)qo, (long long)qk);
    char ref[300];
    snprintf(ref, sizeof ref, "tenant:%lld", (long long)t.id);
    audit(ctx, t.id, &caller, "tenant.quota", ref, "ok", detail, req->remote_ip);
    sf_tenant after;
    if (sf_store_get_tenant(ctx->store, t.id, &after) == SF_OK) {
        sf_json *data = tenant_json(&after);
        respond_data(resp, 200, data);
        sf_json_free(data);
    } else {
        respond_result_error(resp, SF_ERR_NOT_FOUND);
    }
}

// ------------------------------------------------------------- login routes

static int parse_login_id(const char *seg, int64_t *out) {
    char *endp = NULL;
    long long v = strtoll(seg, &endp, 10);
    if (endp == seg || *endp != '\0' || v <= 0) return 0;
    *out = (int64_t)v;
    return 1;
}

static void h_logins_create(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp, const char *tid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_tenant_admin_or_operator(req, resp, ctx, &caller, "login.create")) return;
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *username = sf_json_get_string(body, "username");
    const char *display = sf_json_get_string(body, "display_name");
    const char *role = sf_json_get_string(body, "role");
    const char *password = sf_json_get_string(body, "password");
    if (!username_valid(username) || !role ||
        (strcmp(role, "tenant_admin") != 0 && strcmp(role, "tenant_user") != 0) ||
        !password || !password[0]) {
        sf_json_free(body);
        respond_error(resp, 400, "validation",
                      "username, role (tenant_admin|tenant_user) and password are required",
                      NULL);
        return;
    }
    char user_buf[65], role_buf[16];
    snprintf(user_buf, sizeof user_buf, "%s", username);
    snprintf(role_buf, sizeof role_buf, "%s", role);
    char display_buf[129];
    snprintf(display_buf, sizeof display_buf, "%s", display ? display : "");
    char *pw = xstrdup(password);
    sf_json_free(body);
    if (!pw) { respond_error(resp, 500, "internal", "out of memory", NULL); return; }

    sf_login l;
    sf_result r = sf_store_create_login(ctx->store, t.id, user_buf, display_buf,
                                        role_buf, &l);
    if (r == SF_ERR_CONFLICT) {
        free(pw);
        respond_error(resp, 409, "conflict", "username already exists in this tenant", NULL);
        audit(ctx, t.id, &caller, "login.create", user_buf, "denied",
              "{\"reason\":\"duplicate_username\"}", req->remote_ip);
        return;
    }
    if (r != SF_OK) { free(pw); respond_result_error(resp, r); return; }
    r = sf_auth_set_password(ctx->store, t.id, l.id, pw);
    memset(pw, 0, strlen(pw));
    free(pw);
    if (r != SF_OK) {
        sf_store_delete_login(ctx->store, t.id, l.id); // compensation
        respond_result_error(resp, r);
        return;
    }
    char ref[300];
    snprintf(ref, sizeof ref, "login:%lld", (long long)l.id);
    audit(ctx, t.id, &caller, "login.create", ref, "ok", "{}", req->remote_ip);
    sf_json *data = login_json(&l);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

static void h_logins_list(sf_app_ctx *ctx, const sf_http_request *req,
                          sf_http_response *resp, const char *tid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_tenant_admin_or_operator(req, resp, ctx, &caller, "login.list")) return;
    int limit;
    int64_t cursor;
    if (!parse_pagination(req, resp, &limit, &cursor)) return;
    sf_login *rows = NULL;
    size_t count = 0;
    sf_result r = sf_store_list_logins(ctx->store, t.id, cursor, limit, &rows, &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    int64_t last = 0;
    for (size_t i = 0; i < count; i++) {
        if (!sf_json_array_append(arr, login_json(&rows[i]))) break;
        last = rows[i].id;
    }
    sf_login_free_all(rows, count);
    char cbuf[32];
    respond_list(resp, arr, page_cursor(count, limit, last, cbuf, sizeof cbuf));
    sf_json_free(arr);
}

static void h_login_get(sf_app_ctx *ctx, const sf_http_request *req,
                        sf_http_response *resp, const char *tid_seg,
                        const char *lid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_tenant_admin_or_operator(req, resp, ctx, &caller, "login.get")) return;
    int64_t lid;
    if (!parse_login_id(lid_seg, &lid)) {
        respond_error(resp, 404, "not_found", "login not found", NULL);
        return;
    }
    sf_login l;
    sf_result r = sf_store_get_login(ctx->store, t.id, lid, &l);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *data = login_json(&l);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_login_patch(sf_app_ctx *ctx, const sf_http_request *req,
                          sf_http_response *resp, const char *tid_seg,
                          const char *lid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_tenant_admin_or_operator(req, resp, ctx, &caller, "login.update")) return;
    int64_t lid;
    if (!parse_login_id(lid_seg, &lid)) {
        respond_error(resp, 404, "not_found", "login not found", NULL);
        return;
    }
    sf_login existing;
    if (sf_store_get_login(ctx->store, t.id, lid, &existing) != SF_OK) {
        respond_error(resp, 404, "not_found", "login not found", NULL);
        return;
    }
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *display = sf_json_get_string(body, "display_name");
    const char *role = sf_json_get_string(body, "role");
    const char *state = sf_json_get_string(body, "state");
    if (role && strcmp(role, "tenant_admin") != 0 && strcmp(role, "tenant_user") != 0) {
        sf_json_free(body);
        respond_error(resp, 400, "validation", "role must be tenant_admin or tenant_user", NULL);
        return;
    }
    if (state && strcmp(state, "active") != 0 && strcmp(state, "disabled") != 0) {
        sf_json_free(body);
        respond_error(resp, 400, "validation", "state must be active or disabled", NULL);
        return;
    }
    sf_result r = sf_store_update_login(ctx->store, t.id, lid, display, role, state);
    int disabling = state && strcmp(state, "disabled") == 0;
    sf_json_free(body);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    if (disabling)
        sf_auth_revoke_login_tokens(ctx->store, t.id, lid, NULL);
    char ref[300];
    snprintf(ref, sizeof ref, "login:%lld", (long long)lid);
    audit(ctx, t.id, &caller, "login.update", ref, "ok", "{}", req->remote_ip);
    sf_login after;
    if (sf_store_get_login(ctx->store, t.id, lid, &after) == SF_OK) {
        sf_json *data = login_json(&after);
        respond_data(resp, 200, data);
        sf_json_free(data);
    } else {
        respond_result_error(resp, SF_ERR_NOT_FOUND);
    }
}

static void h_login_delete(sf_app_ctx *ctx, const sf_http_request *req,
                           sf_http_response *resp, const char *tid_seg,
                           const char *lid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_tenant_admin_or_operator(req, resp, ctx, &caller, "login.delete")) return;
    int64_t lid;
    if (!parse_login_id(lid_seg, &lid)) {
        respond_error(resp, 404, "not_found", "login not found", NULL);
        return;
    }
    sf_login target;
    if (sf_store_get_login(ctx->store, t.id, lid, &target) != SF_OK) {
        respond_error(resp, 404, "not_found", "login not found", NULL);
        return;
    }
    // A tenant must always retain an active admin (§5.2).
    if (strcmp(target.role, "tenant_admin") == 0 &&
        strcmp(target.state, "active") == 0) {
        int64_t admins = 0;
        if (sf_store_count_active_admins(ctx->store, t.id, &admins) == SF_OK &&
            admins <= 1) {
            respond_error(resp, 409, "conflict",
                          "cannot delete the tenant's last active admin", NULL);
            audit(ctx, t.id, &caller, "login.delete", lid_seg, "denied",
                  "{\"reason\":\"last_active_admin\"}", req->remote_ip);
            return;
        }
    }
    sf_result r = sf_store_delete_login(ctx->store, t.id, lid);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "login:%lld", (long long)lid);
    audit(ctx, t.id, &caller, "login.delete", ref, "ok", "{}", req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "deleted", 1);
    jnum(data, "id", lid);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_login_password_set(sf_app_ctx *ctx, const sf_http_request *req,
                                 sf_http_response *resp, const char *tid_seg,
                                 const char *lid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_tenant_admin_or_operator(req, resp, ctx, &caller,
                                          "login.password_set_by_admin")) return;
    int64_t lid;
    if (!parse_login_id(lid_seg, &lid)) {
        respond_error(resp, 404, "not_found", "login not found", NULL);
        return;
    }
    sf_login target;
    if (sf_store_get_login(ctx->store, t.id, lid, &target) != SF_OK) {
        respond_error(resp, 404, "not_found", "login not found", NULL);
        return;
    }
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *newp = sf_json_get_string(body, "new_password");
    if (!newp || !newp[0]) {
        sf_json_free(body);
        respond_error(resp, 400, "validation", "new_password is required", NULL);
        return;
    }
    char *pw = xstrdup(newp);
    sf_json_free(body);
    if (!pw) { respond_error(resp, 500, "internal", "out of memory", NULL); return; }
    sf_result r = sf_auth_set_password(ctx->store, t.id, lid, pw);
    memset(pw, 0, strlen(pw));
    free(pw);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_auth_revoke_login_tokens(ctx->store, t.id, lid, "session");
    char ref[300];
    snprintf(ref, sizeof ref, "login:%lld", (long long)lid);
    audit(ctx, t.id, &caller, "login.password_set_by_admin", ref, "ok", "{}",
          req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "set", 1);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_login_reset_issue(sf_app_ctx *ctx, const sf_http_request *req,
                                sf_http_response *resp, const char *tid_seg,
                                const char *lid_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_tenant t;
    if (!resolve_tenant(ctx, req, resp, &caller, tid_seg, &t)) return;
    if (!require_tenant_admin_or_operator(req, resp, ctx, &caller,
                                          "login.password_reset_issue")) return;
    int64_t lid;
    if (!parse_login_id(lid_seg, &lid)) {
        respond_error(resp, 404, "not_found", "login not found", NULL);
        return;
    }
    sf_login target;
    if (sf_store_get_login(ctx->store, t.id, lid, &target) != SF_OK) {
        respond_error(resp, 404, "not_found", "login not found", NULL);
        return;
    }
    char actor_ref[160];
    if (caller.is_operator) snprintf(actor_ref, sizeof actor_ref, "operator");
    else snprintf(actor_ref, sizeof actor_ref, "login:%lld",
                  (long long)caller.login_id);
    char token[256];
    sf_result r = sf_auth_issue_reset(ctx->store, t.id, lid, actor_ref,
                                      req->remote_ip, token, sizeof token);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "login:%lld", (long long)lid);
    // The token itself is never audited (§4: detail carries refs only).
    audit(ctx, t.id, &caller, "login.password_reset_issue", ref, "ok", "{}",
          req->remote_ip);
    sf_time exp;
    sf_iso_from_unix(sf_now_unix() + SF_RESET_TTL_SECONDS, exp);
    sf_json *data = sf_json_new_object();
    // Returned once, in this response only — the admin channel (§5.4).
    jstr(data, "reset_token", token);
    memset(token, 0, sizeof token);
    jnum(data, "login_id", lid);
    jstr(data, "expires_at", exp);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

// ----------------------------------------------------------- backend routes

static void h_backends_list(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (!require_operator(req, resp, ctx, &caller, "backend.list")) return;
    sf_backend *rows = NULL;
    size_t count = 0;
    sf_result r = sf_store_list_backends(ctx->store, &rows, &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    for (size_t i = 0; i < count; i++) {
        if (!sf_json_array_append(arr, backend_json(&rows[i]))) break;
    }
    sf_backend_free_all(rows, count);
    respond_list(resp, arr, NULL);
    sf_json_free(arr);
}

static void h_backends_create(sf_app_ctx *ctx, const sf_http_request *req,
                              sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (!require_operator(req, resp, ctx, &caller, "backend.create")) return;
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *name = sf_json_get_string(body, "name");
    const char *kind = sf_json_get_string(body, "kind");
    const char *secret_ref = sf_json_get_string(body, "secret_ref");
    if (!name || !name[0] || !kind ||
        (strcmp(kind, "filesystem") != 0 && strcmp(kind, "s3") != 0)) {
        sf_json_free(body);
        respond_error(resp, 400, "validation",
                      "name and kind (filesystem|s3) are required", NULL);
        return;
    }
    char *config_json = NULL;
    const sf_json *cfg = sf_json_object_get(body, "config");
    const char *cfg_str = sf_json_get_string(body, "config_json");
    if (cfg && cfg->type == SFJSON_OBJECT) {
        config_json = sf_json_stringify(cfg);
    } else if (cfg_str) {
        sf_json *probe = sf_json_parse(cfg_str);
        if (!probe || probe->type != SFJSON_OBJECT) {
            if (probe) sf_json_free(probe);
            sf_json_free(body);
            respond_error(resp, 400, "validation", "config_json must be a JSON object", NULL);
            return;
        }
        sf_json_free(probe);
        config_json = xstrdup(cfg_str);
    } else {
        config_json = xstrdup("{}");
    }
    if (!config_json) {
        sf_json_free(body);
        respond_error(resp, 500, "internal", "out of memory", NULL);
        return;
    }
    sf_backend b;
    memset(&b, 0, sizeof b);
    sf_result r = sf_store_create_backend(ctx->store, name, kind, config_json,
                                          secret_ref ? secret_ref : "", &b);
    free(config_json);
    sf_json_free(body);
    if (r == SF_ERR_CONFLICT) {
        respond_error(resp, 409, "conflict", "a backend with that name already exists", NULL);
        return;
    }
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "backend:%lld", (long long)b.id);
    audit(ctx, -1, &caller, "backend.create", ref, "ok", "{}", req->remote_ip);
    sf_json *data = backend_json(&b);
    free_backend_row(&b);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

static void h_backend_patch(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (!require_operator(req, resp, ctx, &caller, "backend.update")) return;
    int64_t bid;
    if (!parse_login_id(id_seg, &bid)) {
        respond_error(resp, 404, "not_found", "backend not found", NULL);
        return;
    }
    sf_backend existing;
    memset(&existing, 0, sizeof existing);
    if (sf_store_get_backend(ctx->store, bid, &existing) != SF_OK) {
        respond_error(resp, 404, "not_found", "backend not found", NULL);
        return;
    }
    free_backend_row(&existing);
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *state = sf_json_get_string(body, "state");
    if (state && strcmp(state, "active") != 0 && strcmp(state, "disabled") != 0) {
        sf_json_free(body);
        respond_error(resp, 400, "validation", "state must be active or disabled", NULL);
        return;
    }
    char *config_json = NULL;
    const sf_json *cfg = sf_json_object_get(body, "config");
    const char *cfg_str = sf_json_get_string(body, "config_json");
    if (cfg && cfg->type == SFJSON_OBJECT) config_json = sf_json_stringify(cfg);
    else if (cfg_str) config_json = xstrdup(cfg_str);
    sf_result r = sf_store_update_backend(ctx->store, bid, config_json, state);
    free(config_json);
    sf_json_free(body);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "backend:%lld", (long long)bid);
    audit(ctx, -1, &caller, "backend.update", ref, "ok", "{}", req->remote_ip);
    sf_backend after;
    memset(&after, 0, sizeof after);
    if (sf_store_get_backend(ctx->store, bid, &after) == SF_OK) {
        sf_json *data = backend_json(&after);
        free_backend_row(&after);
        respond_data(resp, 200, data);
        sf_json_free(data);
    } else {
        respond_result_error(resp, SF_ERR_NOT_FOUND);
    }
}

// ------------------------------------------------------------ bucket routes
// Buckets/objects live in the caller's own tenant; the operator has no
// tenant scope and does not use these routes.

static int require_login_caller(sf_app_ctx *ctx, const sf_http_request *req,
                                sf_http_response *resp, sf_caller *caller,
                                const char *action) {
    if (!require_auth(ctx, req, resp, caller, 0)) return 0;
    if (caller->is_operator) {
        respond_error(resp, 403, "forbidden",
                      "buckets are tenant-scoped; use a tenant login", NULL);
        audit(ctx, -1, caller, action, "", "denied", "{\"reason\":\"operator_scope\"}",
              req->remote_ip);
        return 0;
    }
    return 1;
}

static void h_buckets_create(sf_app_ctx *ctx, const sf_http_request *req,
                             sf_http_response *resp) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "bucket.create")) return;
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *name = sf_json_get_string(body, "name");
    if (!bucket_name_valid(name)) {
        sf_json_free(body);
        respond_error(resp, 400, "validation", "invalid bucket name", NULL);
        return;
    }
    char name_buf[129];
    snprintf(name_buf, sizeof name_buf, "%s", name);
    int ok = 1;
    int64_t bucket_quota = quota_field(body, "quota_bytes", -1, &ok);
    int64_t backend_id = 0;
    int has_backend = sf_json_get_int64(body, "backend_id", &backend_id);
    sf_json_free(body);
    if (!ok) {
        respond_error(resp, 400, "validation", "quota_bytes must be an integer >= -1", NULL);
        return;
    }
    // Tenant bucket-count quota (§7.4).
    sf_tenant t;
    if (sf_store_get_tenant(ctx->store, caller.tenant_id, &t) != SF_OK) {
        respond_error(resp, 500, "internal", "caller tenant missing", NULL);
        return;
    }
    int64_t ub = 0, uo = 0, bc = 0;
    sf_store_tenant_usage(ctx->store, caller.tenant_id, &ub, &uo, &bc);
    int64_t eb, eo, ek;
    sf_tenant_effective_quota(&t, &eb, &eo, &ek);
    if (bc + 1 > ek) {
        sf_json *d = sf_json_new_object();
        jnum(d, "quota_buckets", ek);
        jnum(d, "used_buckets", bc);
        respond_error(resp, 409, "quota_exceeded", "bucket quota exceeded", d);
        sf_json_free(d);
        audit(ctx, caller.tenant_id, &caller, "bucket.create", name_buf, "denied",
              "{\"reason\":\"quota_buckets\"}", req->remote_ip);
        return;
    }
    // Backend: named, or the first active one.
    sf_backend backend;
    memset(&backend, 0, sizeof backend);
    int have_backend = 0;
    if (has_backend) {
        if (sf_store_get_backend(ctx->store, backend_id, &backend) == SF_OK) {
            have_backend = 1;
            if (strcmp(backend.state, "active") != 0) {
                free_backend_row(&backend);
                respond_error(resp, 409, "conflict", "backend is disabled", NULL);
                return;
            }
        } else {
            respond_error(resp, 404, "not_found", "backend not found", NULL);
            return;
        }
    } else {
        sf_backend *rows = NULL;
        size_t count = 0;
        if (sf_store_list_backends(ctx->store, &rows, &count) == SF_OK) {
            for (size_t i = 0; i < count && !have_backend; i++) {
                if (strcmp(rows[i].state, "active") == 0) {
                    backend = rows[i]; // takes over config_json ownership
                    rows[i].config_json = NULL;
                    have_backend = 1;
                }
            }
            sf_backend_free_all(rows, count);
        }
        if (!have_backend) {
            respond_error(resp, 502, "backend_unavailable", "no active backend", NULL);
            return;
        }
    }
    sf_bucket b;
    sf_result r = sf_store_create_bucket(ctx->store, caller.tenant_id, name_buf,
                                         backend.id, bucket_quota, &b);
    free_backend_row(&backend);
    if (r == SF_ERR_CONFLICT) {
        respond_error(resp, 409, "conflict", "bucket name already exists in this tenant", NULL);
        audit(ctx, caller.tenant_id, &caller, "bucket.create", name_buf, "denied",
              "{\"reason\":\"duplicate_name\"}", req->remote_ip);
        return;
    }
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    audit(ctx, caller.tenant_id, &caller, "bucket.create", name_buf, "ok", "{}",
          req->remote_ip);
    sf_json *data = bucket_json(&b);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

static void h_buckets_list(sf_app_ctx *ctx, const sf_http_request *req,
                           sf_http_response *resp) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "bucket.list")) return;
    int limit;
    int64_t cursor;
    if (!parse_pagination(req, resp, &limit, &cursor)) return;
    sf_bucket *rows = NULL;
    size_t count = 0;
    sf_result r = sf_store_list_buckets(ctx->store, caller.tenant_id, cursor, limit,
                                        &rows, &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    int64_t last = 0;
    for (size_t i = 0; i < count; i++) {
        if (!sf_json_array_append(arr, bucket_json(&rows[i]))) break;
        last = rows[i].id;
    }
    sf_bucket_free_all(rows, count);
    char cbuf[32];
    respond_list(resp, arr, page_cursor(count, limit, last, cbuf, sizeof cbuf));
    sf_json_free(arr);
}

// Shared bucket lookup for the {name} routes; writes the 404 itself.
static int load_bucket(sf_app_ctx *ctx, const sf_caller *caller,
                       sf_http_response *resp, const char *name, sf_bucket *out) {
    if (sf_store_get_bucket_by_name(ctx->store, caller->tenant_id, name, out) != SF_OK) {
        respond_error(resp, 404, "not_found", "bucket not found", NULL);
        return 0;
    }
    return 1;
}

static void h_bucket_get(sf_app_ctx *ctx, const sf_http_request *req,
                         sf_http_response *resp, const char *name) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "bucket.get")) return;
    sf_bucket b;
    if (!load_bucket(ctx, &caller, resp, name, &b)) return;
    sf_json *data = bucket_json(&b);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_bucket_patch(sf_app_ctx *ctx, const sf_http_request *req,
                           sf_http_response *resp, const char *name) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "bucket.update")) return;
    sf_bucket b;
    if (!load_bucket(ctx, &caller, resp, name, &b)) return;
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    int ok = 1;
    int64_t q = quota_field(body, "quota_bytes", b.quota_bytes, &ok);
    sf_json_free(body);
    if (!ok) {
        respond_error(resp, 400, "validation", "quota_bytes must be an integer >= -1", NULL);
        return;
    }
    sf_result r = sf_store_update_bucket_quota(ctx->store, caller.tenant_id, b.id, q);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    audit(ctx, caller.tenant_id, &caller, "bucket.update", name, "ok", "{}",
          req->remote_ip);
    sf_bucket after;
    if (sf_store_get_bucket_by_id(ctx->store, caller.tenant_id, b.id, &after) == SF_OK) {
        sf_json *data = bucket_json(&after);
        respond_data(resp, 200, data);
        sf_json_free(data);
    } else {
        respond_result_error(resp, SF_ERR_NOT_FOUND);
    }
}

static void h_bucket_delete(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp, const char *name) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "bucket.delete")) return;
    sf_bucket b;
    if (!load_bucket(ctx, &caller, resp, name, &b)) return;
    if (b.object_count > 0) {
        sf_json *d = sf_json_new_object();
        jnum(d, "object_count", b.object_count);
        respond_error(resp, 409, "conflict", "bucket is not empty", d);
        sf_json_free(d);
        audit(ctx, caller.tenant_id, &caller, "bucket.delete", name, "denied",
              "{\"reason\":\"not_empty\"}", req->remote_ip);
        return;
    }
    sf_result r = sf_store_delete_bucket(ctx->store, caller.tenant_id, b.id);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    audit(ctx, caller.tenant_id, &caller, "bucket.delete", name, "ok", "{}",
          req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "deleted", 1);
    jstr(data, "name", name);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

// ------------------------------------------------------------ object routes

static void h_objects_list(sf_app_ctx *ctx, const sf_http_request *req,
                           sf_http_response *resp, const char *bucket_name) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "object.list")) return;
    sf_bucket b;
    if (!load_bucket(ctx, &caller, resp, bucket_name, &b)) return;
    int limit;
    int64_t cursor;
    if (!parse_pagination(req, resp, &limit, &cursor)) return;
    char prefix[512] = "";
    int has_prefix = sf_http_query(req, "prefix", prefix, sizeof prefix);
    sf_object *rows = NULL;
    size_t count = 0;
    sf_result r = sf_store_list_objects(ctx->store, caller.tenant_id, b.id,
                                        has_prefix ? prefix : NULL, cursor, limit,
                                        &rows, &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    int64_t last = 0;
    for (size_t i = 0; i < count; i++) {
        if (!sf_json_array_append(arr, object_json(&rows[i]))) break;
        last = rows[i].id;
    }
    sf_object_free_all(rows, count);
    char cbuf[32];
    respond_list(resp, arr, page_cursor(count, limit, last, cbuf, sizeof cbuf));
    sf_json_free(arr);
}

// Open the adapter for an explicit (backend, tenant, bucket-prefix)
// triple — the blob layer addresses bytes under the creating
// reference's bucket prefix (sfblob.h placement note).
static sf_adapter_ctx *open_adapter_at(sf_app_ctx *ctx, int64_t tenant_id,
                                       int64_t backend_id, int64_t bucket_prefix,
                                       char *err, size_t errcap) {
    sf_backend backend;
    memset(&backend, 0, sizeof backend);
    if (sf_store_get_backend(ctx->store, backend_id, &backend) != SF_OK) {
        snprintf(err, errcap, "backend row missing");
        return NULL;
    }
    sf_adapter_ctx *actx = sf_adapter_open(&backend, ctx->data_dir,
                                           tenant_id, bucket_prefix, err, errcap);
    free_backend_row(&backend);
    return actx;
}

// Candidate bucket prefixes for a blob's bytes, in probe order:
// preferred first, then the referencing buckets, then 0 (raw-upload
// prefix). Returns the count written into `out`.
static size_t blob_candidates(sf_app_ctx *ctx, const sf_blob *blob,
                              int64_t preferred, int64_t *out, size_t cap) {
    size_t n = 0;
    if (preferred >= 0 && n < cap) out[n++] = preferred;
    int64_t *refs = NULL;
    size_t ref_count = 0;
    if (sf_blob_reference_buckets(ctx->store, blob->tenant_id, blob->id,
                                  &refs, &ref_count) == SF_OK) {
        for (size_t i = 0; i < ref_count && n < cap; i++) {
            int dup = 0;
            for (size_t j = 0; j < n; j++) if (out[j] == refs[i]) dup = 1;
            if (!dup) out[n++] = refs[i];
        }
        free(refs);
    }
    // All of the tenant's bucket ids are also candidates: an orphaned
    // blob has no references left to hint its prefix, but its bytes
    // can only live under one of the tenant's own bucket prefixes
    // (or 0). GC deletion depends on this.
    {
        int64_t cursor = 0;
        for (;;) {
            sf_bucket *brows = NULL;
            size_t bcount = 0;
            if (sf_store_list_buckets(ctx->store, blob->tenant_id, cursor, 200,
                                      &brows, &bcount) != SF_OK) break;
            for (size_t i = 0; i < bcount && n < cap; i++) {
                int dup = 0;
                for (size_t j = 0; j < n; j++) if (out[j] == brows[i].id) dup = 1;
                if (!dup) out[n++] = brows[i].id;
                cursor = brows[i].id;
            }
            sf_bucket_free_all(brows, bcount);
            if (bcount < 200) break;
        }
    }
    {
        int dup = 0;
        for (size_t j = 0; j < n; j++) if (out[j] == 0) dup = 1;
        if (!dup && n < cap) out[n++] = 0;
    }
    return n;
}

// Find an adapter context under which the blob's bytes exist.
// Caller closes the returned context. SF_ERR_NOT_FOUND when no
// candidate holds the bytes; SF_ERR_BACKEND on adapter-open failure.
static sf_result blob_open_readable(sf_app_ctx *ctx, const sf_blob *blob,
                                    int64_t preferred, sf_adapter_ctx **out) {
    int64_t cand[64];
    size_t n = blob_candidates(ctx, blob, preferred, cand, 64);
    char err[256] = "";
    int saw_open_error = 0;
    *out = NULL;
    for (size_t i = 0; i < n; i++) {
        sf_adapter_ctx *actx = open_adapter_at(ctx, blob->tenant_id,
                                               blob->backend_id, cand[i],
                                               err, sizeof err);
        if (!actx) { saw_open_error = 1; continue; }
        int exists = 0;
        if (actx->vt->exists &&
            actx->vt->exists(actx, blob->sha256_hex, &exists) == SF_OK && exists) {
            *out = actx;
            return SF_OK;
        }
        sf_adapter_close(actx);
    }
    return saw_open_error ? SF_ERR_BACKEND : SF_ERR_NOT_FOUND;
}

static sf_result blob_read_any(sf_app_ctx *ctx, const sf_blob *blob,
                               int64_t preferred, uint8_t **data_out,
                               size_t *len_out) {
    if (strcmp(blob->state, "corrupt") == 0) return SF_BLOB_ERR_CORRUPT;
    sf_adapter_ctx *actx = NULL;
    sf_result r = blob_open_readable(ctx, blob, preferred, &actx);
    if (r != SF_OK) return r;
    r = sf_blob_read(actx, blob, data_out, len_out);
    sf_adapter_close(actx);
    return r;
}

// Delete a blob's bytes under EVERY candidate prefix (idempotent;
// used by GC and manual purge so no copy survives anywhere).
static void blob_delete_everywhere(sf_app_ctx *ctx, const sf_blob *blob) {
    int64_t cand[64];
    size_t n = blob_candidates(ctx, blob, -1, cand, 64);
    char err[256] = "";
    for (size_t i = 0; i < n; i++) {
        sf_adapter_ctx *actx = open_adapter_at(ctx, blob->tenant_id,
                                               blob->backend_id, cand[i],
                                               err, sizeof err);
        if (!actx) continue;
        actx->vt->del(actx, blob->sha256_hex);
        sf_adapter_close(actx);
    }
}

// Open the adapter for a bucket row. On failure *err carries the reason.
static sf_adapter_ctx *open_adapter(sf_app_ctx *ctx, const sf_caller *caller,
                                    const sf_bucket *b, char *err, size_t errcap) {
    sf_backend backend;
    memset(&backend, 0, sizeof backend);
    if (sf_store_get_backend(ctx->store, b->backend_id, &backend) != SF_OK) {
        snprintf(err, errcap, "backend row missing");
        return NULL;
    }
    sf_adapter_ctx *actx = sf_adapter_open(&backend, ctx->data_dir,
                                           caller->tenant_id, b->id, err, errcap);
    free_backend_row(&backend);
    return actx;
}

static void h_object_get(sf_app_ctx *ctx, const sf_http_request *req,
                         sf_http_response *resp, const char *bucket_name,
                         const char *key, int head_only) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "object.get")) return;
    if (!sf_key_valid(key)) {
        respond_error(resp, 400, "invalid_key", "invalid object key", NULL);
        return;
    }
    sf_bucket b;
    if (!load_bucket(ctx, &caller, resp, bucket_name, &b)) return;
    sf_object ob;
    memset(&ob, 0, sizeof ob);
    if (sf_store_get_object(ctx->store, caller.tenant_id, b.id, key, &ob) != SF_OK) {
        respond_error(resp, 404, "not_found", "object not found", NULL);
        return;
    }
    if (head_only) {
        // HEAD returns the metadata JSON (§8 table via task spec).
        sf_json *data = object_json(&ob);
        int64_t hb_id = -1;
        if (sf_blob_object_blob_id(ctx->store, ob.id, &hb_id) == SF_OK && hb_id >= 0)
            jnum(data, "blob_id", hb_id);
        sf_object_free(&ob);
        respond_data(resp, 200, data);
        sf_json_free(data);
        return;
    }
    // §13.2: reads resolve reference -> blob -> adapter bytes under
    // the blob's digest name. A corrupt blob refuses with 502.
    int64_t blob_id = -1;
    sf_blob_object_blob_id(ctx->store, ob.id, &blob_id);
    uint8_t *data = NULL;
    size_t len = 0;
    if (blob_id >= 0) {
        sf_blob blob;
        if (sf_blob_get_by_id(ctx->store, caller.tenant_id, blob_id, &blob) != SF_OK) {
            sf_object_free(&ob);
            respond_error(resp, 502, "backend_unavailable",
                          "object blob row missing", NULL);
            return;
        }
        if (strcmp(blob.state, "corrupt") == 0) {
            sf_object_free(&ob);
            sf_json *d = sf_json_new_object();
            jnum(d, "blob_id", blob.id);
            jstr(d, "state", "corrupt");
            respond_error(resp, 502, "blob_integrity",
                          "blob failed integrity verification", d);
            sf_json_free(d);
            return;
        }
        sf_result r = blob_read_any(ctx, &blob, b.id, &data, &len);
        if (r != SF_OK) {
            sf_object_free(&ob);
            free(data);
            if (r == SF_ERR_NOT_FOUND)
                respond_error(resp, 404, "not_found", "object bytes not found", NULL);
            else
                respond_error(resp, 502, "backend_unavailable", "storage backend error", NULL);
            return;
        }
    } else {
        // Pre-blob row (cannot occur after the v2 backfill): legacy
        // key-addressed read.
        char err[256] = "";
        sf_adapter_ctx *actx = open_adapter(ctx, &caller, &b, err, sizeof err);
        if (!actx) {
            sf_object_free(&ob);
            sf_json *d = sf_json_new_object();
            jstr(d, "reason", err);
            respond_error(resp, 502, "backend_unavailable", "storage backend unavailable", d);
            sf_json_free(d);
            return;
        }
        sf_result r = actx->vt->get(actx, key, &data, &len);
        sf_adapter_close(actx);
        if (r != SF_OK) {
            sf_object_free(&ob);
            free(data);
            if (r == SF_ERR_NOT_FOUND)
                respond_error(resp, 404, "not_found", "object bytes not found", NULL);
            else
                respond_error(resp, 502, "backend_unavailable", "storage backend error", NULL);
            return;
        }
    }
    char hex[65];
    sf_hex_encode(ob.sha256, 32, hex);
    resp->status = 200;
    {
        const char *ct = ob.content_type[0] ? ob.content_type
                                            : "application/octet-stream";
        size_t ctl = strlen(ct);
        if (ctl >= sizeof resp->content_type) ctl = sizeof resp->content_type - 1;
        memcpy(resp->content_type, ct, ctl);
        resp->content_type[ctl] = '\0';
    }
    sf_http_response_set_header(resp, "X-Snowfell-SHA256", hex);
    sf_object_free(&ob);
    sf_http_response_set_body(resp, data, len);
}

static void h_object_delete(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp, const char *bucket_name,
                            const char *key) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "object.delete")) return;
    if (!sf_key_valid(key)) {
        respond_error(resp, 400, "invalid_key", "invalid object key", NULL);
        return;
    }
    sf_bucket b;
    if (!load_bucket(ctx, &caller, resp, bucket_name, &b)) return;
    sf_object ob;
    memset(&ob, 0, sizeof ob);
    if (sf_store_get_object(ctx->store, caller.tenant_id, b.id, key, &ob) != SF_OK) {
        respond_error(resp, 404, "not_found", "object not found", NULL);
        return;
    }
    sf_object_free(&ob);
    // §13.2/§13.3: deleting an object deletes the REFERENCE only —
    // the blob row refcount drops in the same transaction and the
    // blob's bytes survive until GC if this was the last reference.
    int64_t detached_blob = -1;
    sf_result r = sf_blob_delete_object_ref(ctx->store, caller.tenant_id, b.id,
                                            key, &detached_blob);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char oref[1024];
    snprintf(oref, sizeof oref, "%s/%s", bucket_name, key);
    audit(ctx, caller.tenant_id, &caller, "object.delete", oref, "ok", "{}",
          req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "deleted", 1);
    jstr(data, "key", key);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

// Spool a raw body to a temp file in the data dir, hashing as we go,
// then read it back into one buffer (<= the 256 MiB cap by
// construction). Shared by the object PUT and blob upload paths
// (§13.2.1: the digest is computed from the spooled bytes themselves).
// On failure returns an sf_result and nothing is allocated.
static sf_result spool_body(sf_app_ctx *ctx, sf_body_reader read_body,
                            void *rctx, uint8_t **buf_out, int64_t *len_out,
                            uint8_t digest_out[32]) {
    static unsigned long spool_counter = 0;
    char spool_path[4096];
    snprintf(spool_path, sizeof spool_path, "%s/.spool-%ld-%lu.tmp",
             ctx->data_dir, (long)getpid(), spool_counter++);
    FILE *spool = fopen(spool_path, "wb");
    if (!spool) return SF_ERR_IO;
    sf_sha256_ctx hctx;
    sf_sha256_init(&hctx);
    uint8_t chunk[65536];
    int64_t spooled = 0;
    int spool_error = 0;
    for (;;) {
        size_t nread = 0;
        if (read_body(rctx, chunk, sizeof chunk, &nread) != 0) { spool_error = 1; break; }
        if (nread == 0) break;
        sf_sha256_update(&hctx, chunk, nread);
        if (fwrite(chunk, 1, nread, spool) != nread) { spool_error = 1; break; }
        spooled += (int64_t)nread;
        if (spooled > SF_MAX_OBJECT_BYTES) { spool_error = 2; break; }
    }
    if (fclose(spool) != 0 && spool_error == 0) spool_error = 1;
    if (spool_error) {
        unlink(spool_path);
        return spool_error == 2 ? SF_ERR_TOO_LARGE : SF_ERR_IO;
    }
    sf_sha256_final(&hctx, digest_out);
    uint8_t *buf = (uint8_t *)malloc(spooled > 0 ? (size_t)spooled : 1);
    if (!buf) { unlink(spool_path); return SF_ERR_NOMEM; }
    FILE *in = fopen(spool_path, "rb");
    if (!in || (spooled > 0 && fread(buf, 1, (size_t)spooled, in) != (size_t)spooled)) {
        if (in) fclose(in);
        free(buf);
        unlink(spool_path);
        return SF_ERR_IO;
    }
    fclose(in);
    unlink(spool_path);
    *buf_out = buf;
    *len_out = spooled;
    return SF_OK;
}

// Raw-body PUT (§13.2.1 dedup-aware write path): spool (digest while
// spooling) -> scope lookup -> quota pre-check on INCREMENTAL physical
// bytes -> adapter write on a miss only -> attach reference + blob in
// one transaction (§13.6: quota charges physical bytes; a dedup hit
// adds 0 and cannot be quota-denied; a replaced blob keeps occupying
// physical bytes as an orphan until GC, so no replacement credit is
// taken against the tenant quota — the bucket cap stays a logical,
// reference-side check and does take the replaced size as credit,
// matching the bucket counters' meaning).
static void h_object_put_raw(void *vctx, const sf_http_request *req,
                             sf_body_reader read_body, void *rctx,
                             sf_http_response *resp) {
    sf_app_ctx *ctx = (sf_app_ctx *)vctx;
    snprintf(g_actor_ref, sizeof g_actor_ref, "-");
    // Path: /v1/buckets/{name}/objects/{key...}
    const char *rest = sf_http_path_suffix(req, "/v1/buckets/");
    if (!rest) {
        respond_error(resp, 404, "not_found", "route not found", NULL);
        return;
    }
    const char *slash = strchr(rest, '/');
    if (!slash) {
        respond_error(resp, 404, "not_found", "route not found", NULL);
        return;
    }
    char bucket_name[129];
    size_t bn = (size_t)(slash - rest);
    if (bn == 0 || bn >= sizeof bucket_name) {
        respond_error(resp, 404, "not_found", "bucket not found", NULL);
        return;
    }
    memcpy(bucket_name, rest, bn);
    bucket_name[bn] = '\0';
    const char *tail = slash + 1;
    if (strncmp(tail, "objects/", 8) != 0 || tail[8] == '\0') {
        respond_error(resp, 404, "not_found", "route not found", NULL);
        return;
    }
    const char *key = tail + 8;

    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "object.put")) return;

    const char *cl = sf_http_header(req, "Content-Length");
    if (!cl) {
        respond_error(resp, 411, "length_required",
                      "Content-Length is required for object PUT", NULL);
        audit(ctx, caller.tenant_id, &caller, "object.put", key, "denied",
              "{\"reason\":\"length_required\"}", req->remote_ip);
        return;
    }
    char *endp = NULL;
    long long clen_ll = strtoll(cl, &endp, 10);
    if (endp == cl || *endp != '\0' || clen_ll < 0) {
        respond_error(resp, 400, "validation", "invalid Content-Length", NULL);
        return;
    }
    int64_t clen = (int64_t)clen_ll;
    if (clen > SF_MAX_OBJECT_BYTES) {
        sf_json *d = sf_json_new_object();
        jnum(d, "max_bytes", SF_MAX_OBJECT_BYTES);
        jnum(d, "requested_bytes", clen);
        respond_error(resp, 413, "payload_too_large",
                      "object exceeds the 256 MiB cap", d);
        sf_json_free(d);
        audit(ctx, caller.tenant_id, &caller, "object.put", key, "denied",
              "{\"reason\":\"payload_too_large\"}", req->remote_ip);
        return;
    }
    if (!sf_key_valid(key)) {
        respond_error(resp, 400, "invalid_key", "invalid object key", NULL);
        audit(ctx, caller.tenant_id, &caller, "object.put", key, "denied",
              "{\"reason\":\"invalid_key\"}", req->remote_ip);
        return;
    }

    // §13.7 metadata transport: X-Snowfell-Metadata header carrying a
    // JSON object of at most 4 KB. Validated before any byte is
    // spooled; anything else is 400 validation.
    char *metadata_json = NULL;
    const char *meta_hdr = sf_http_header(req, "X-Snowfell-Metadata");
    if (meta_hdr) {
        if (strlen(meta_hdr) > 4096) {
            respond_error(resp, 400, "validation",
                          "X-Snowfell-Metadata exceeds 4 KB", NULL);
            audit(ctx, caller.tenant_id, &caller, "object.put", key, "denied",
                  "{\"reason\":\"metadata_too_large\"}", req->remote_ip);
            return;
        }
        sf_json *probe = sf_json_parse(meta_hdr);
        if (!probe || probe->type != SFJSON_OBJECT) {
            if (probe) sf_json_free(probe);
            respond_error(resp, 400, "validation",
                          "X-Snowfell-Metadata must be a JSON object", NULL);
            audit(ctx, caller.tenant_id, &caller, "object.put", key, "denied",
                  "{\"reason\":\"metadata_invalid\"}", req->remote_ip);
            return;
        }
        metadata_json = sf_json_stringify(probe);
        sf_json_free(probe);
        if (!metadata_json) {
            respond_error(resp, 500, "internal", "out of memory", NULL);
            return;
        }
    }

    sf_bucket b;
    if (!load_bucket(ctx, &caller, resp, bucket_name, &b)) { free(metadata_json); return; }

    uint8_t *buf = NULL;
    int64_t spooled = 0;
    uint8_t digest[32];
    sf_result sr = spool_body(ctx, read_body, rctx, &buf, &spooled, digest);
    if (sr == SF_ERR_TOO_LARGE) {
        free(metadata_json);
        respond_error(resp, 413, "payload_too_large",
                      "object exceeds the 256 MiB cap", NULL);
        audit(ctx, caller.tenant_id, &caller, "object.put", key, "denied",
              "{\"reason\":\"payload_too_large\"}", req->remote_ip);
        return;
    }
    if (sr != SF_OK) {
        free(metadata_json);
        respond_error(resp, 400, "validation",
                      "request body was truncated or unreadable", NULL);
        return;
    }
    if (spooled != clen) {
        free(buf);
        free(metadata_json);
        respond_error(resp, 400, "validation",
                      "request body length does not match Content-Length", NULL);
        return;
    }
    char hex[65];
    sf_hex_encode(digest, 32, hex);

    // Dedup scope lookup (§13.2.1): a hit requires digest AND size
    // agreement (§13.9) — the digest is the lookup key, computed from
    // the spooled bytes, so size equality is the second factor.
    sf_blob blob;
    int have_blob = 0;
    if (sf_blob_get_by_digest(ctx->store, caller.tenant_id, digest, &blob) == SF_OK &&
        blob.size_bytes == spooled) have_blob = 1;

    sf_object existing;
    memset(&existing, 0, sizeof existing);
    int have_existing =
        (sf_store_get_object(ctx->store, caller.tenant_id, b.id, key, &existing) == SF_OK);
    int64_t replaced = have_existing ? existing.size_bytes : 0;
    if (have_existing) sf_object_free(&existing);

    // Quota pre-check (§13.6): tenant bytes are PHYSICAL (live blobs,
    // refcount > 0) — incremental is 0 on a hit, the full size on a
    // miss, with no credit for a replaced blob: at check time the old
    // blob is still referenced, so current physical includes it; once
    // detached it becomes orphan garbage for GC, no longer charged.
    sf_tenant t;
    if (sf_store_get_tenant(ctx->store, caller.tenant_id, &t) != SF_OK) {
        free(buf); free(metadata_json);
        respond_error(resp, 500, "internal", "caller tenant missing", NULL);
        return;
    }
    int64_t eb, eo, ek;
    sf_tenant_effective_quota(&t, &eb, &eo, &ek);
    sf_dedup_stats stats;
    memset(&stats, 0, sizeof stats);
    sf_blob_accounting(ctx->store, caller.tenant_id, &stats);
    int64_t incremental = have_blob ? 0 : spooled;
    int64_t ub = 0, uo = 0, bc = 0;
    sf_store_tenant_usage(ctx->store, caller.tenant_id, &ub, &uo, &bc);
    int quota_fail = 0;
    const char *quota_what = "";
    int64_t quota_limit = eb, quota_used = stats.physical_bytes;
    if (stats.physical_bytes + incremental > eb) { quota_fail = 1; quota_what = "tenant_bytes"; }
    else if (!have_existing && uo + 1 > eo) { quota_fail = 1; quota_what = "tenant_objects"; quota_limit = eo; quota_used = uo; }
    else if (b.quota_bytes >= 0 && b.total_bytes - replaced + clen > b.quota_bytes) {
        quota_fail = 1; quota_what = "bucket_bytes";
        quota_limit = b.quota_bytes; quota_used = b.total_bytes;
    }
    if (quota_fail) {
        free(buf); free(metadata_json);
        sf_json *d = sf_json_new_object();
        jstr(d, "quota", quota_what);
        jnum(d, "quota_bytes", quota_limit);
        jnum(d, "used_bytes", quota_used);
        jnum(d, "requested_bytes", clen);
        jnum(d, "incremental_bytes", incremental);
        jnum(d, "replaced_bytes", replaced);
        respond_error(resp, 409, "quota_exceeded", "quota exceeded", d);
        sf_json_free(d);
        char detail[256];
        snprintf(detail, sizeof detail,
                 "{\"quota\":\"%s\",\"used_bytes\":%lld,\"requested_bytes\":%lld,\"incremental_bytes\":%lld}",
                 quota_what, (long long)quota_used, (long long)clen,
                 (long long)incremental);
        audit(ctx, caller.tenant_id, &caller, "object.put", key, "denied", detail,
              req->remote_ip);
        return;
    }

    const char *ctype = sf_http_header(req, "Content-Type");
    char ctype_buf[129];
    snprintf(ctype_buf, sizeof ctype_buf, "%s",
             (ctype && ctype[0]) ? ctype : "application/octet-stream");

    // Miss (or a corrupt hit, healed by rewriting its bytes from the
    // spooled copy whose digest matches by construction): one adapter
    // write under the digest name, in this bucket's prefix.
    int wrote_bytes = 0;
    if (!have_blob || strcmp(blob.state, "corrupt") == 0) {
        char err[256] = "";
        sf_adapter_ctx *actx = open_adapter_at(ctx, caller.tenant_id,
                                               b.backend_id, b.id, err, sizeof err);
        if (!actx) {
            free(buf); free(metadata_json);
            sf_json *d = sf_json_new_object();
            jstr(d, "reason", err);
            respond_error(resp, 502, "backend_unavailable", "storage backend unavailable", d);
            sf_json_free(d);
            audit(ctx, caller.tenant_id, &caller, "object.put", key, "error",
                  "{\"reason\":\"adapter_open_failed\"}", req->remote_ip);
            return;
        }
        sf_result pr = actx->vt->put(actx, hex, buf, (size_t)spooled);
        sf_adapter_close(actx);
        if (pr != SF_OK) {
            free(buf); free(metadata_json);
            respond_error(resp, 502, "backend_unavailable", "storage backend write failed", NULL);
            audit(ctx, caller.tenant_id, &caller, "object.put", key, "error",
                  "{\"reason\":\"adapter_put_failed\"}", req->remote_ip);
            return;
        }
        wrote_bytes = 1;
        if (have_blob && strcmp(blob.state, "corrupt") == 0)
            sf_blob_set_state(ctx->store, caller.tenant_id, blob.id, "ok");
    }
    free(buf);

    sf_object out;
    memset(&out, 0, sizeof out);
    sf_blob attached;
    int hit = 0;
    sf_result ar = sf_blob_put_object_ref(ctx->store, caller.tenant_id, b.id, key,
                                          spooled, digest, ctype_buf,
                                          metadata_json ? metadata_json : "{}",
                                          b.backend_id, &out, &attached, &hit);
    free(metadata_json);
    if (ar != SF_OK) {
        // Compensating delete: byte write whose DB commit failed (§7.1).
        if (wrote_bytes) {
            char err[256] = "";
            sf_adapter_ctx *actx = open_adapter_at(ctx, caller.tenant_id,
                                                   b.backend_id, b.id, err, sizeof err);
            if (actx) { actx->vt->del(actx, hex); sf_adapter_close(actx); }
        }
        respond_result_error(resp, ar);
        audit(ctx, caller.tenant_id, &caller, "object.put", key, "error",
              "{\"reason\":\"store_failed_compensated\"}", req->remote_ip);
        return;
    }
    char detail[256];
    snprintf(detail, sizeof detail,
             "{\"size_bytes\":%lld,\"sha256\":\"%s\",\"blob_id\":%lld,\"deduplicated\":%s}",
             (long long)spooled, hex, (long long)attached.id, hit ? "true" : "false");
    char oref[1024];
    snprintf(oref, sizeof oref, "%s/%s", bucket_name, key);
    audit(ctx, caller.tenant_id, &caller, "object.put", oref, "ok", detail,
          req->remote_ip);
    sf_json *data = object_json(&out);
    jnum(data, "blob_id", attached.id);
    sf_object_free(&out);
    respond_data(resp, have_existing ? 200 : 201, data);
    sf_json_free(data);
    log_line(ctx, req->method, req->path, resp->status);
}

// ------------------------------------------------------------ blob routes
// §13.7. All surfaces here are anonymized per §13.8: responses and
// audit rows carry opaque ids and figures only — no slugs, no names.

static sf_json *blob_json(const sf_blob *bl) {
    sf_json *o = sf_json_new_object();
    jnum(o, "blob_id", bl->id);
    jnum(o, "tenant_id", bl->tenant_id);
    jstr(o, "sha256", bl->sha256_hex);
    jnum(o, "size_bytes", bl->size_bytes);
    jnum(o, "backend_id", bl->backend_id);
    jnum(o, "refcount", bl->refcount);
    jstr(o, "state", bl->state);
    jtime_or_null(o, "orphaned_at", bl->orphaned_at);
    jstr(o, "created_at", bl->created_at);
    jtime_or_null(o, "last_verified_at", bl->last_verified_at);
    return o;
}

// Resolve a blob for a caller: operator = any scope; a login = own
// scope only (cross-scope is 404, §3.2). Returns 1 on success.
static int resolve_blob(sf_app_ctx *ctx, const sf_http_request *req,
                        sf_http_response *resp, const sf_caller *caller,
                        const char *id_seg, sf_blob *out) {
    int64_t bid;
    if (!parse_login_id(id_seg, &bid)) {
        respond_error(resp, 404, "not_found", "blob not found", NULL);
        return 0;
    }
    int64_t scope = caller->is_operator ? -1 : caller->tenant_id;
    if (sf_blob_get_by_id(ctx->store, scope, bid, out) != SF_OK) {
        respond_error(resp, 404, "not_found", "blob not found", NULL);
        return 0;
    }
    (void)req;
    return 1;
}

static void h_blob_get(sf_app_ctx *ctx, const sf_http_request *req,
                       sf_http_response *resp, const char *id_seg, int meta_only) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    sf_blob blob;
    if (!resolve_blob(ctx, req, resp, &caller, id_seg, &blob)) return;
    if (meta_only) {
        sf_json *data = blob_json(&blob);
        respond_data(resp, 200, data);
        sf_json_free(data);
        return;
    }
    if (strcmp(blob.state, "corrupt") == 0) {
        sf_json *d = sf_json_new_object();
        jnum(d, "blob_id", blob.id);
        jstr(d, "state", "corrupt");
        respond_error(resp, 502, "blob_integrity",
                      "blob failed integrity verification", d);
        sf_json_free(d);
        return;
    }
    uint8_t *data = NULL;
    size_t len = 0;
    sf_result r = blob_read_any(ctx, &blob, -1, &data, &len);
    if (r != SF_OK) {
        free(data);
        if (r == SF_ERR_NOT_FOUND)
            respond_error(resp, 404, "not_found", "blob bytes not found", NULL);
        else
            respond_error(resp, 502, "backend_unavailable", "storage backend error", NULL);
        return;
    }
    resp->status = 200;
    snprintf(resp->content_type, sizeof resp->content_type,
             "application/octet-stream");
    sf_http_response_set_header(resp, "X-Snowfell-SHA256", blob.sha256_hex);
    sf_http_response_set_body(resp, data, len);
}

static void h_blob_verify(sf_app_ctx *ctx, const sf_http_request *req,
                          sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (!require_tenant_admin_or_operator(req, resp, ctx, &caller, "blob.verify"))
        return;
    sf_blob blob;
    if (!resolve_blob(ctx, req, resp, &caller, id_seg, &blob)) return;
    int verified = 0;
    sf_adapter_ctx *actx = NULL;
    sf_result r = blob_open_readable(ctx, &blob, -1, &actx);
    if (r == SF_OK) {
        sf_blob_verify(ctx->store, actx, &blob, &verified);
        sf_adapter_close(actx);
    } else if (r == SF_ERR_NOT_FOUND) {
        // Bytes are gone: that is an integrity verdict, not a 404.
        sf_blob_set_state(ctx->store, blob.tenant_id, blob.id, "corrupt");
    } else {
        respond_error(resp, 502, "backend_unavailable",
                      "storage backend unavailable", NULL);
        return;
    }
    char ref[300];
    snprintf(ref, sizeof ref, "blob:%lld", (long long)blob.id);
    char detail[160];
    snprintf(detail, sizeof detail, "{\"blob_id\":%lld,\"verified\":%s}",
             (long long)blob.id, verified ? "true" : "false");
    audit(ctx, blob.tenant_id, &caller, "blob.verify", ref,
          verified ? "ok" : "error", detail, req->remote_ip);
    sf_json *data = sf_json_new_object();
    jnum(data, "blob_id", blob.id);
    jbool(data, "verified", verified);
    jstr(data, "sha256", blob.sha256_hex);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_blob_delete(sf_app_ctx *ctx, const sf_http_request *req,
                          sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (!require_tenant_admin_or_operator(req, resp, ctx, &caller, "blob.delete"))
        return;
    sf_blob blob;
    if (!resolve_blob(ctx, req, resp, &caller, id_seg, &blob)) return;
    // §13.3: purge is refused while referenced; the sweep's rule —
    // trust the recomputation, not the stored counter — applies here.
    int64_t live = 0;
    if (sf_blob_recompute_refcount(ctx->store, blob.tenant_id, blob.id, &live) != SF_OK) {
        respond_error(resp, 500, "internal", "refcount recompute failed", NULL);
        return;
    }
    if (live > 0) {
        sf_json *d = sf_json_new_object();
        jnum(d, "blob_id", blob.id);
        jnum(d, "refcount", live);
        respond_error(resp, 409, "conflict", "blob is still referenced", d);
        sf_json_free(d);
        char ref[300];
        snprintf(ref, sizeof ref, "blob:%lld", (long long)blob.id);
        char detail[160];
        snprintf(detail, sizeof detail, "{\"refcount\":%lld}", (long long)live);
        audit(ctx, blob.tenant_id, &caller, "blob.delete", ref, "denied",
              detail, req->remote_ip);
        return;
    }
    blob_delete_everywhere(ctx, &blob);
    sf_blob_delete_row(ctx->store, blob.tenant_id, blob.id);
    char ref[300];
    snprintf(ref, sizeof ref, "blob:%lld", (long long)blob.id);
    audit(ctx, blob.tenant_id, &caller, "blob.delete", ref, "ok", "{}",
          req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "deleted", 1);
    jnum(data, "blob_id", blob.id);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

// Raw upload: POST /v1/blobs (spooled exactly like an object PUT).
// This raw handler also claims POST /v1/blobs/{id}/verify (the raw
// prefix match runs before buffered dispatch), so it delegates that
// one path to the verify handler, which needs no body.
static void h_blob_raw(void *vctx, const sf_http_request *req,
                       sf_body_reader read_body, void *rctx,
                       sf_http_response *resp) {
    sf_app_ctx *ctx = (sf_app_ctx *)vctx;
    snprintf(g_actor_ref, sizeof g_actor_ref, "-");
    if (strcmp(req->path, "/v1/blobs") != 0) {
        const char *sfx = sf_http_path_suffix(req, "/v1/blobs/");
        if (sfx) {
            char idbuf[32];
            const char *slash = strchr(sfx, '/');
            if (slash && strcmp(slash, "/verify") == 0 &&
                (size_t)(slash - sfx) < sizeof idbuf) {
                memcpy(idbuf, sfx, (size_t)(slash - sfx));
                idbuf[slash - sfx] = '\0';
                h_blob_verify(ctx, req, resp, idbuf);
                log_line(ctx, req->method, req->path, resp->status);
                return;
            }
        }
        respond_error(resp, 404, "not_found", "route not found", NULL);
        return;
    }

    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "blob.create")) return;
    const char *cl = sf_http_header(req, "Content-Length");
    if (!cl) {
        respond_error(resp, 411, "length_required",
                      "Content-Length is required for blob upload", NULL);
        return;
    }
    char *endp = NULL;
    long long clen_ll = strtoll(cl, &endp, 10);
    if (endp == cl || *endp != '\0' || clen_ll < 0) {
        respond_error(resp, 400, "validation", "invalid Content-Length", NULL);
        return;
    }
    if ((int64_t)clen_ll > SF_MAX_OBJECT_BYTES) {
        sf_json *d = sf_json_new_object();
        jnum(d, "max_bytes", SF_MAX_OBJECT_BYTES);
        jnum(d, "requested_bytes", (int64_t)clen_ll);
        respond_error(resp, 413, "payload_too_large",
                      "blob exceeds the 256 MiB cap", d);
        sf_json_free(d);
        return;
    }
    uint8_t *buf = NULL;
    int64_t spooled = 0;
    uint8_t digest[32];
    sf_result sr = spool_body(ctx, read_body, rctx, &buf, &spooled, digest);
    if (sr == SF_ERR_TOO_LARGE) {
        respond_error(resp, 413, "payload_too_large",
                      "blob exceeds the 256 MiB cap", NULL);
        return;
    }
    if (sr != SF_OK || spooled != (int64_t)clen_ll) {
        free(buf);
        respond_error(resp, 400, "validation",
                      "request body was truncated or unreadable", NULL);
        return;
    }
    char hex[65];
    sf_hex_encode(digest, 32, hex);

    sf_blob blob;
    int have_blob = 0;
    if (sf_blob_get_by_digest(ctx->store, caller.tenant_id, digest, &blob) == SF_OK &&
        blob.size_bytes == spooled) have_blob = 1;

    int64_t backend_id = -1;
    if (have_blob) {
        backend_id = blob.backend_id;
    } else {
        sf_backend *rows = NULL;
        size_t count = 0;
        if (sf_store_list_backends(ctx->store, &rows, &count) == SF_OK) {
            for (size_t i = 0; i < count && backend_id < 0; i++)
                if (strcmp(rows[i].state, "active") == 0) backend_id = rows[i].id;
            sf_backend_free_all(rows, count);
        }
        if (backend_id < 0) {
            free(buf);
            respond_error(resp, 502, "backend_unavailable", "no active backend", NULL);
            return;
        }
    }

    int wrote_bytes = 0;
    if (!have_blob || strcmp(blob.state, "corrupt") == 0) {
        char err[256] = "";
        // Raw uploads live under the tenant's bucket-0 prefix.
        sf_adapter_ctx *actx = open_adapter_at(ctx, caller.tenant_id,
                                               backend_id, 0, err, sizeof err);
        if (!actx) {
            free(buf);
            sf_json *d = sf_json_new_object();
            jstr(d, "reason", err);
            respond_error(resp, 502, "backend_unavailable",
                          "storage backend unavailable", d);
            sf_json_free(d);
            return;
        }
        sf_result pr = actx->vt->put(actx, hex, buf, (size_t)spooled);
        sf_adapter_close(actx);
        if (pr != SF_OK) {
            free(buf);
            respond_error(resp, 502, "backend_unavailable",
                          "storage backend write failed", NULL);
            return;
        }
        wrote_bytes = 1;
        if (have_blob) sf_blob_set_state(ctx->store, caller.tenant_id, blob.id, "ok");
    }
    free(buf);

    if (!have_blob) {
        int created = 0;
        sf_result cr = sf_blob_create_unreferenced(ctx->store, caller.tenant_id,
                                                   digest, spooled, backend_id,
                                                   &blob, &created);
        if (cr != SF_OK) {
            if (wrote_bytes) {
                char err[256] = "";
                sf_adapter_ctx *actx = open_adapter_at(ctx, caller.tenant_id,
                                                       backend_id, 0, err, sizeof err);
                if (actx) { actx->vt->del(actx, hex); sf_adapter_close(actx); }
            }
            respond_result_error(resp, cr);
            return;
        }
        (void)created;
    }
    char ref[300];
    snprintf(ref, sizeof ref, "blob:%lld", (long long)blob.id);
    char detail[256];
    snprintf(detail, sizeof detail,
             "{\"size_bytes\":%lld,\"sha256\":\"%s\",\"deduplicated\":%s}",
             (long long)spooled, hex, have_blob ? "true" : "false");
    audit(ctx, caller.tenant_id, &caller, "blob.create", ref, "ok", detail,
          req->remote_ip);
    sf_json *data = sf_json_new_object();
    jnum(data, "blob_id", blob.id);
    jstr(data, "sha256", hex);
    jnum(data, "size_bytes", spooled);
    // Own scope only (§13.4/§13.8): this flag can never leak another
    // tenant's holdings — the lookup above consulted this tenant's
    // index alone.
    jbool(data, "deduplicated", have_blob);
    respond_data(resp, 201, data);
    sf_json_free(data);
    log_line(ctx, req->method, req->path, resp->status);
}

// ------------------------------------------------------------ GC / verify sweeps / stats

static int64_t gc_grace_seconds(void) {
    const char *e = getenv("SNOWFELL_GC_GRACE_SECONDS");
    if (!e || !*e) e = getenv("SF_GC_GRACE_SECONDS");
    if (e && *e) {
        char *endp = NULL;
        long v = strtol(e, &endp, 10);
        if (endp != e && *endp == '\0' && v >= 0) return (int64_t)v;
    }
    return 3600;  // SF_GC_GRACE_SECONDS default (§13.3)
}

// Parse an optional JSON body ({dry_run?, tenant_id?}); empty body is
// defaults, malformed body is a 400 already written.
static int parse_sweep_body(const sf_http_request *req, sf_http_response *resp,
                            int *dry_run_out, int64_t *tenant_out,
                            int *has_tenant_out) {
    *dry_run_out = 0;
    *tenant_out = -1;
    *has_tenant_out = 0;
    if (!req->body || req->body_len == 0) return 1;
    sf_json *body = parse_body(resp, req);
    if (!body) return 0;
    *dry_run_out = sf_json_get_bool(body, "dry_run", false) ? 1 : 0;
    int64_t tid = 0;
    if (sf_json_get_int64(body, "tenant_id", &tid)) {
        *tenant_out = tid;
        *has_tenant_out = 1;
    }
    sf_json_free(body);
    return 1;
}

static void run_gc(sf_app_ctx *ctx, const sf_http_request *req,
                   sf_http_response *resp, const sf_caller *caller,
                   int64_t scope_tenant, int dry_run) {
    sf_blob *rows = NULL;
    size_t count = 0;
    if (sf_blob_list(ctx->store, scope_tenant, &rows, &count) != SF_OK) {
        respond_error(resp, 500, "internal", "blob list failed", NULL);
        return;
    }
    int64_t cutoff = sf_now_unix() - gc_grace_seconds();
    int64_t scanned = (int64_t)count, orphans = 0, deleted = 0, reclaimed = 0;
    for (size_t i = 0; i < count; i++) {
        sf_blob b = rows[i];
        int64_t live = 0;
        if (sf_blob_recompute_refcount(ctx->store, b.tenant_id, b.id, &live) != SF_OK)
            continue;
        if (live != 0) continue;
        sf_blob cur;
        if (sf_blob_get_by_id(ctx->store, b.tenant_id, b.id, &cur) != SF_OK)
            continue;
        if (!cur.orphaned_at[0]) continue;
        if (sf_unix_from_iso(cur.orphaned_at) > cutoff) continue;  // grace
        orphans++;
        if (!dry_run) {
            blob_delete_everywhere(ctx, &cur);
            if (sf_blob_delete_row(ctx->store, cur.tenant_id, cur.id) == SF_OK) {
                deleted++;
                reclaimed += cur.size_bytes;
            }
        }
    }
    sf_blob_free_all(rows, count);
    char detail[256];
    snprintf(detail, sizeof detail,
             "{\"scanned\":%lld,\"orphans\":%lld,\"deleted\":%lld,"
             "\"bytes_reclaimed\":%lld,\"dry_run\":%s}",
             (long long)scanned, (long long)orphans, (long long)deleted,
             (long long)reclaimed, dry_run ? "true" : "false");
    audit(ctx, scope_tenant, caller, "storage.gc", "", "ok", detail,
          req->remote_ip);
    sf_json *data = sf_json_new_object();
    jnum(data, "scanned", scanned);
    jnum(data, "orphans", orphans);
    jnum(data, "deleted", deleted);
    jnum(data, "bytes_reclaimed", reclaimed);
    jbool(data, "dry_run", dry_run);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_gc_tenant(sf_app_ctx *ctx, const sf_http_request *req,
                        sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (caller.is_operator || strcmp(caller.role, "tenant_admin") != 0) {
        respond_error(resp, 403, "forbidden", "tenant admin only", NULL);
        audit(ctx, caller.is_operator ? -1 : caller.tenant_id, &caller,
              "storage.gc", "", "denied", "{}", req->remote_ip);
        return;
    }
    int dry_run, has_tenant;
    int64_t tenant_filter;
    if (!parse_sweep_body(req, resp, &dry_run, &tenant_filter, &has_tenant)) return;
    run_gc(ctx, req, resp, &caller, caller.tenant_id, dry_run);
}

static void h_gc_admin(sf_app_ctx *ctx, const sf_http_request *req,
                       sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (!require_operator(req, resp, ctx, &caller, "storage.gc")) return;
    int dry_run, has_tenant;
    int64_t tenant_filter;
    if (!parse_sweep_body(req, resp, &dry_run, &tenant_filter, &has_tenant)) return;
    run_gc(ctx, req, resp, &caller, has_tenant ? tenant_filter : -1, dry_run);
}

static void h_admin_verify(sf_app_ctx *ctx, const sf_http_request *req,
                           sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (!require_operator(req, resp, ctx, &caller, "storage.verify")) return;
    int dry_run, has_tenant;
    int64_t tenant_filter;
    if (!parse_sweep_body(req, resp, &dry_run, &tenant_filter, &has_tenant)) return;
    (void)dry_run;
    int64_t scope = has_tenant ? tenant_filter : -1;
    sf_blob *rows = NULL;
    size_t count = 0;
    if (sf_blob_list(ctx->store, scope, &rows, &count) != SF_OK) {
        respond_error(resp, 500, "internal", "blob list failed", NULL);
        return;
    }
    int64_t scanned = (int64_t)count, verified = 0, corrupt = 0;
    for (size_t i = 0; i < count; i++) {
        sf_blob b = rows[i];
        int v = 0;
        sf_adapter_ctx *actx = NULL;
        sf_result r = blob_open_readable(ctx, &b, -1, &actx);
        if (r == SF_OK) {
            sf_blob_verify(ctx->store, actx, &b, &v);
            sf_adapter_close(actx);
        } else if (r == SF_ERR_NOT_FOUND) {
            sf_blob_set_state(ctx->store, b.tenant_id, b.id, "corrupt");
        }
        if (v) verified++;
        else corrupt++;
    }
    sf_blob_free_all(rows, count);
    char detail[200];
    snprintf(detail, sizeof detail,
             "{\"scanned\":%lld,\"verified\":%lld,\"corrupt\":%lld}",
             (long long)scanned, (long long)verified, (long long)corrupt);
    audit(ctx, scope, &caller, "storage.verify", "", "ok", detail, req->remote_ip);
    sf_json *data = sf_json_new_object();
    jnum(data, "scanned", scanned);
    jnum(data, "verified", verified);
    jnum(data, "corrupt", corrupt);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_stats_dedup(sf_app_ctx *ctx, const sf_http_request *req,
                          sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    if (!require_operator(req, resp, ctx, &caller, "stats.dedup")) return;
    // §13.8: aggregates keyed by tenant_id ONLY — no slugs or names
    // anywhere in this response.
    sf_json *scopes = sf_json_new_array();
    int64_t cursor = 0;
    for (;;) {
        sf_tenant *rows = NULL;
        size_t count = 0;
        if (sf_store_list_tenants(ctx->store, cursor, 200, &rows, &count) != SF_OK)
            break;
        for (size_t i = 0; i < count; i++) {
            sf_dedup_stats st;
            memset(&st, 0, sizeof st);
            st.dedup_ratio = 1.0;
            sf_blob_accounting(ctx->store, rows[i].id, &st);
            sf_json *o = sf_json_new_object();
            jnum(o, "tenant_id", rows[i].id);
            jnum(o, "logical_bytes", st.logical_bytes);
            jnum(o, "physical_bytes", st.physical_bytes);
            jnum(o, "bytes_saved", st.bytes_saved);
            jset(o, "dedup_ratio", sf_json_new_number(st.dedup_ratio));
            jnum(o, "blob_count", st.blob_count);
            jnum(o, "reference_count", st.reference_count);
            if (!sf_json_array_append(scopes, o)) sf_json_free(o);
            cursor = rows[i].id;
        }
        sf_tenant_free_all(rows, count);
        if (count < 200) break;
    }
    sf_json *data = sf_json_new_object();
    jset(data, "scopes", scopes);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

// ------------------------------------------------------------ CMS routes
// §13.7. Content lives in the caller's own tenant (any login; the
// operator has no tenant scope — the one exception is search, where
// §13.5 gives the operator an explicit tenant parameter). Every
// mutation is audited with the opaque actor ref (§13.8).

static void cms_actor_ref(const sf_caller *caller, char *buf, size_t cap) {
    snprintf(buf, cap, "login:%lld", (long long)caller->login_id);
}

static sf_json *cms_collection_json(const sf_cms_collection *c) {
    sf_json *o = sf_json_new_object();
    jnum(o, "id", c->id);
    jnum(o, "tenant_id", c->tenant_id);
    if (c->parent_id >= 0) jnum(o, "parent_id", c->parent_id);
    else jnull(o, "parent_id");
    jstr(o, "name", c->name);
    jstr(o, "slug", c->slug);
    jstr(o, "created_at", c->created_at);
    jstr(o, "updated_at", c->updated_at);
    return o;
}

static sf_json *cms_item_json(const sf_cms_item *it) {
    sf_json *o = sf_json_new_object();
    jnum(o, "id", it->id);
    jnum(o, "tenant_id", it->tenant_id);
    if (it->collection_id >= 0) jnum(o, "collection_id", it->collection_id);
    else jnull(o, "collection_id");
    jstr(o, "slug", it->slug);
    jstr(o, "title", it->title ? it->title : "");
    jstr(o, "kind", it->kind);
    jstr(o, "state", it->state);
    sf_json *md = it->metadata_json ? sf_json_parse(it->metadata_json) : NULL;
    if (md && md->type == SFJSON_OBJECT) jset(o, "metadata", md);
    else {
        if (md) sf_json_free(md);
        jset(o, "metadata", sf_json_new_object());
    }
    jstr(o, "created_by", it->created_by ? it->created_by : "");
    jstr(o, "created_at", it->created_at);
    jstr(o, "updated_at", it->updated_at);
    if (it->current_version_id >= 0) {
        sf_json *cv = sf_json_new_object();
        jnum(cv, "version_id", it->current_version_id);
        jnum(cv, "version_no", it->current_version_no);
        jnum(cv, "blob_id", it->current_blob_id);
        jstr(cv, "sha256", it->current_sha256_hex);
        jnum(cv, "size_bytes", it->current_size_bytes);
        jset(o, "current_version", cv);
    } else {
        jnull(o, "current_version");
    }
    return o;
}

static sf_json *cms_version_json(const sf_cms_version *v) {
    sf_json *o = sf_json_new_object();
    jnum(o, "id", v->id);
    jnum(o, "item_id", v->item_id);
    jnum(o, "tenant_id", v->tenant_id);
    jnum(o, "version_no", v->version_no);
    jnum(o, "blob_id", v->blob_id);
    jstr(o, "sha256", v->sha256_hex);
    jnum(o, "size_bytes", v->size_bytes);
    jstr(o, "note", v->note ? v->note : "");
    sf_json *md = v->metadata_json ? sf_json_parse(v->metadata_json) : NULL;
    if (md && md->type == SFJSON_OBJECT) jset(o, "metadata", md);
    else {
        if (md) sf_json_free(md);
        jset(o, "metadata", sf_json_new_object());
    }
    jstr(o, "created_by", v->created_by ? v->created_by : "");
    jstr(o, "created_at", v->created_at);
    return o;
}

static sf_json *cms_ref_json(const sf_cms_ref *rf) {
    sf_json *o = sf_json_new_object();
    jnum(o, "id", rf->id);
    jnum(o, "tenant_id", rf->tenant_id);
    jnum(o, "from_item_id", rf->from_item_id);
    if (rf->to_item_id >= 0) jnum(o, "to_item_id", rf->to_item_id);
    else jnull(o, "to_item_id");
    if (rf->to_blob_id >= 0) jnum(o, "to_blob_id", rf->to_blob_id);
    else jnull(o, "to_blob_id");
    jstr(o, "kind", rf->kind);
    jstr(o, "created_at", rf->created_at);
    return o;
}

// Extract an optional metadata object field as owned JSON text.
// Returns 1 when usable (*present set; *text_out NULL when absent or
// JSON null), 0 with a 400 already written when present but not an
// object or over the 4 KB metadata cap (§4).
static int cms_metadata_field(sf_http_response *resp, const sf_json *body,
                              const char *key, int *present, char **text_out) {
    *present = 0;
    *text_out = NULL;
    const sf_json *node = sf_json_object_get(body, key);
    if (!node || node->type == SFJSON_NULL) return 1;
    if (node->type != SFJSON_OBJECT) {
        respond_error(resp, 400, "validation", "metadata must be a JSON object", NULL);
        return 0;
    }
    char *text = sf_json_stringify(node);
    if (!text) {
        respond_error(resp, 500, "internal", "out of memory", NULL);
        return 0;
    }
    if (strlen(text) > 4096) {
        free(text);
        respond_error(resp, 400, "validation", "metadata exceeds 4 KB", NULL);
        return 0;
    }
    *present = 1;
    *text_out = text;
    return 1;
}

// Optional id field: absent/null -> *value = absent_value; a JSON
// number -> that value; anything else is a 400 already written.
static int cms_id_field(sf_http_response *resp, const sf_json *body,
                        const char *key, int64_t absent_value, int64_t *value) {
    const sf_json *node = sf_json_object_get(body, key);
    *value = absent_value;
    if (!node || node->type == SFJSON_NULL) return 1;
    int64_t v = 0;
    if (!sf_json_get_int64(body, key, &v) || v <= 0) {
        respond_error(resp, 400, "validation", "id fields must be positive integers", NULL);
        return 0;
    }
    *value = v;
    return 1;
}

// Optional ?collection_id= query filter: -1 = any.
static int cms_collection_query(const sf_http_request *req,
                                sf_http_response *resp, int64_t *out) {
    char buf[64];
    *out = -1;
    if (!sf_http_query(req, "collection_id", buf, sizeof buf)) return 1;
    if (strcmp(buf, "null") == 0) return 1;
    char *endp = NULL;
    long long v = strtoll(buf, &endp, 10);
    if (endp == buf || *endp != '\0' || v <= 0) {
        respond_error(resp, 400, "validation",
                      "collection_id must be a positive id", NULL);
        return 0;
    }
    *out = (int64_t)v;
    return 1;
}

// ---- collections

static void h_collections_create(sf_app_ctx *ctx, const sf_http_request *req,
                                 sf_http_response *resp) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "collection.create")) return;
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *name = sf_json_get_string(body, "name");
    const char *slug = sf_json_get_string(body, "slug");
    int64_t parent_id = -1;
    if (!cms_id_field(resp, body, "parent_id", -1, &parent_id)) {
        sf_json_free(body);
        return;
    }
    if (!name || !name[0] || strlen(name) > 256 || !slug_valid(slug)) {
        sf_json_free(body);
        respond_error(resp, 400, "validation",
                      "name (1..256 chars) and a valid slug are required", NULL);
        return;
    }
    char name_buf[257], slug_buf[65];
    snprintf(name_buf, sizeof name_buf, "%s", name);
    snprintf(slug_buf, sizeof slug_buf, "%s", slug);
    sf_json_free(body);
    sf_cms_collection c;
    sf_result r = sf_cms_create_collection(ctx->store, caller.tenant_id,
                                           parent_id, name_buf, slug_buf, &c);
    if (r == SF_ERR_CONFLICT) {
        respond_error(resp, 409, "conflict",
                      "a collection with that slug already exists in this tenant", NULL);
        audit(ctx, caller.tenant_id, &caller, "collection.create", slug_buf,
              "denied", "{\"reason\":\"duplicate_slug\"}", req->remote_ip);
        return;
    }
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "collection:%lld", (long long)c.id);
    audit(ctx, caller.tenant_id, &caller, "collection.create", ref, "ok", "{}",
          req->remote_ip);
    sf_json *data = cms_collection_json(&c);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

static void h_collections_list(sf_app_ctx *ctx, const sf_http_request *req,
                               sf_http_response *resp) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "collection.list")) return;
    int limit;
    int64_t cursor;
    if (!parse_pagination(req, resp, &limit, &cursor)) return;
    sf_cms_collection *rows = NULL;
    size_t count = 0;
    sf_result r = sf_cms_list_collections(ctx->store, caller.tenant_id, cursor,
                                          limit, &rows, &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    int64_t last = 0;
    for (size_t i = 0; i < count; i++) {
        if (!sf_json_array_append(arr, cms_collection_json(&rows[i]))) break;
        last = rows[i].id;
    }
    sf_cms_collection_free_all(rows, count);
    char cbuf[32];
    respond_list(resp, arr, page_cursor(count, limit, last, cbuf, sizeof cbuf));
    sf_json_free(arr);
}

static void h_collection_get(sf_app_ctx *ctx, const sf_http_request *req,
                             sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "collection.get")) return;
    int64_t cid;
    sf_cms_collection c;
    if (!parse_login_id(id_seg, &cid) ||
        sf_cms_get_collection(ctx->store, caller.tenant_id, cid, &c) != SF_OK) {
        respond_error(resp, 404, "not_found", "collection not found", NULL);
        return;
    }
    sf_json *data = cms_collection_json(&c);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_collection_patch(sf_app_ctx *ctx, const sf_http_request *req,
                               sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "collection.update")) return;
    int64_t cid;
    sf_cms_collection c;
    if (!parse_login_id(id_seg, &cid) ||
        sf_cms_get_collection(ctx->store, caller.tenant_id, cid, &c) != SF_OK) {
        respond_error(resp, 404, "not_found", "collection not found", NULL);
        return;
    }
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *name = sf_json_get_string(body, "name");
    const char *slug = sf_json_get_string(body, "slug");
    const sf_json *pnode = sf_json_object_get(body, "parent_id");
    int64_t parent_id = -2;  // keep
    if (pnode && pnode->type == SFJSON_NULL) parent_id = -1;
    else if (pnode && !cms_id_field(resp, body, "parent_id", -2, &parent_id)) {
        sf_json_free(body);
        return;
    }
    if ((name && (!name[0] || strlen(name) > 256)) ||
        (slug && !slug_valid(slug))) {
        sf_json_free(body);
        respond_error(resp, 400, "validation", "invalid name or slug", NULL);
        return;
    }
    char name_buf[257], slug_buf[65];
    if (name) snprintf(name_buf, sizeof name_buf, "%s", name);
    if (slug) snprintf(slug_buf, sizeof slug_buf, "%s", slug);
    sf_result r = sf_cms_update_collection(ctx->store, caller.tenant_id, cid,
                                           name ? name_buf : NULL,
                                           slug ? slug_buf : NULL, parent_id);
    sf_json_free(body);
    if (r == SF_ERR_CONFLICT) {
        respond_error(resp, 409, "conflict",
                      "a collection with that slug already exists in this tenant", NULL);
        return;
    }
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "collection:%lld", (long long)cid);
    audit(ctx, caller.tenant_id, &caller, "collection.update", ref, "ok", "{}",
          req->remote_ip);
    if (sf_cms_get_collection(ctx->store, caller.tenant_id, cid, &c) == SF_OK) {
        sf_json *data = cms_collection_json(&c);
        respond_data(resp, 200, data);
        sf_json_free(data);
    } else {
        respond_result_error(resp, SF_ERR_NOT_FOUND);
    }
}

static void h_collection_delete(sf_app_ctx *ctx, const sf_http_request *req,
                                sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "collection.delete")) return;
    int64_t cid;
    if (!parse_login_id(id_seg, &cid)) {
        respond_error(resp, 404, "not_found", "collection not found", NULL);
        return;
    }
    sf_result r = sf_cms_delete_collection(ctx->store, caller.tenant_id, cid);
    if (r == SF_ERR_CONFLICT) {
        respond_error(resp, 409, "conflict",
                      "collection still has child collections or items", NULL);
        char ref[300];
        snprintf(ref, sizeof ref, "collection:%lld", (long long)cid);
        audit(ctx, caller.tenant_id, &caller, "collection.delete", ref, "denied",
              "{\"reason\":\"not_empty\"}", req->remote_ip);
        return;
    }
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "collection:%lld", (long long)cid);
    audit(ctx, caller.tenant_id, &caller, "collection.delete", ref, "ok", "{}",
          req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "deleted", 1);
    jnum(data, "id", cid);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

// ---- items

static void h_content_create(sf_app_ctx *ctx, const sf_http_request *req,
                             sf_http_response *resp) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.create")) return;
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *slug = sf_json_get_string(body, "slug");
    const char *title = sf_json_get_string(body, "title");
    const char *kind = sf_json_get_string(body, "kind");
    int64_t collection_id = -1, blob_id = -1;
    if (!cms_id_field(resp, body, "collection_id", -1, &collection_id) ||
        !cms_id_field(resp, body, "blob_id", -1, &blob_id)) {
        sf_json_free(body);
        return;
    }
    int md_present = 0;
    char *md_text = NULL;
    if (!cms_metadata_field(resp, body, "metadata", &md_present, &md_text)) {
        sf_json_free(body);
        return;
    }
    if (!slug_valid(slug) || blob_id <= 0 ||
        (kind && strlen(kind) > 64)) {
        free(md_text);
        sf_json_free(body);
        respond_error(resp, 400, "validation",
                      "slug (valid) and blob_id (positive, in your tenant) are required",
                      NULL);
        return;
    }
    char slug_buf[65], kind_buf[65];
    snprintf(slug_buf, sizeof slug_buf, "%s", slug);
    snprintf(kind_buf, sizeof kind_buf, "%s", kind ? kind : "");
    char *title_dup = xstrdup(title ? title : "");
    sf_json_free(body);
    if (!title_dup) {
        free(md_text);
        respond_error(resp, 500, "internal", "out of memory", NULL);
        return;
    }
    char actor[160];
    cms_actor_ref(&caller, actor, sizeof actor);
    sf_cms_item it;
    memset(&it, 0, sizeof it);
    // A cross-tenant blob_id (or collection_id) is a scoped miss in
    // the store: 404, never a reference leak (§13.7).
    sf_result r = sf_cms_create_item(ctx->store, caller.tenant_id, collection_id,
                                     slug_buf, title_dup, kind_buf,
                                     md_text ? md_text : "{}", blob_id, actor,
                                     &it);
    free(title_dup);
    free(md_text);
    if (r == SF_ERR_CONFLICT) {
        respond_error(resp, 409, "conflict",
                      "an item with that slug already exists in this tenant", NULL);
        audit(ctx, caller.tenant_id, &caller, "content.create", slug_buf,
              "denied", "{\"reason\":\"duplicate_slug\"}", req->remote_ip);
        return;
    }
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "content:%lld", (long long)it.id);
    char detail[256];
    snprintf(detail, sizeof detail,
             "{\"slug\":\"%s\",\"blob_id\":%lld,\"version_no\":1}",
             slug_buf, (long long)blob_id);
    audit(ctx, caller.tenant_id, &caller, "content.create", ref, "ok", detail,
          req->remote_ip);
    sf_json *data = cms_item_json(&it);
    sf_cms_item_free(&it);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

// Shared list/search responder: kind/state/collection filters from
// the query string; q non-NULL selects the search semantics.
static void cms_items_query_respond(sf_app_ctx *ctx, const sf_http_request *req,
                                    sf_http_response *resp,
                                    const sf_caller *caller, int64_t scope_tenant,
                                    const char *q) {
    int limit;
    int64_t cursor;
    if (!parse_pagination(req, resp, &limit, &cursor)) return;
    int64_t collection_id;
    if (!cms_collection_query(req, resp, &collection_id)) return;
    char kind[128] = "", state[32] = "";
    int has_kind = sf_http_query(req, "kind", kind, sizeof kind);
    int has_state = sf_http_query(req, "state", state, sizeof state);
    if (has_state && strcmp(state, "draft") != 0 &&
        strcmp(state, "published") != 0 && strcmp(state, "archived") != 0) {
        respond_error(resp, 400, "validation",
                      "state must be draft, published, or archived", NULL);
        return;
    }
    sf_cms_item *rows = NULL;
    size_t count = 0;
    sf_result r = q
        ? sf_cms_search_items(ctx->store, scope_tenant, q, collection_id,
                              has_kind ? kind : NULL, has_state ? state : NULL,
                              cursor, limit, &rows, &count)
        : sf_cms_list_items(ctx->store, scope_tenant, collection_id,
                            has_kind ? kind : NULL, has_state ? state : NULL,
                            cursor, limit, &rows, &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    int64_t last = 0;
    for (size_t i = 0; i < count; i++) {
        if (!sf_json_array_append(arr, cms_item_json(&rows[i]))) break;
        last = rows[i].id;
    }
    sf_cms_item_free_all(rows, count);
    char cbuf[32];
    respond_list(resp, arr, page_cursor(count, limit, last, cbuf, sizeof cbuf));
    sf_json_free(arr);
    (void)caller;
}

static void h_content_list(sf_app_ctx *ctx, const sf_http_request *req,
                           sf_http_response *resp) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.list")) return;
    cms_items_query_respond(ctx, req, resp, &caller, caller.tenant_id, NULL);
}

static void h_content_get(sf_app_ctx *ctx, const sf_http_request *req,
                          sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.get")) return;
    int64_t iid;
    sf_cms_item it;
    memset(&it, 0, sizeof it);
    if (!parse_login_id(id_seg, &iid) ||
        sf_cms_get_item(ctx->store, caller.tenant_id, iid, &it) != SF_OK) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    sf_json *data = cms_item_json(&it);
    sf_cms_item_free(&it);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

static void h_content_patch(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.update")) return;
    int64_t iid;
    sf_cms_item it;
    memset(&it, 0, sizeof it);
    if (!parse_login_id(id_seg, &iid) ||
        sf_cms_get_item(ctx->store, caller.tenant_id, iid, &it) != SF_OK) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    sf_cms_item_free(&it);
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const sf_json *tnode = sf_json_object_get(body, "title");
    const sf_json *knode = sf_json_object_get(body, "kind");
    if ((tnode && tnode->type != SFJSON_STRING) ||
        (knode && knode->type != SFJSON_STRING)) {
        sf_json_free(body);
        respond_error(resp, 400, "validation", "title and kind must be strings", NULL);
        return;
    }
    const char *title = tnode ? sf_json_get_string(body, "title") : NULL;
    const char *kind = knode ? sf_json_get_string(body, "kind") : NULL;
    if (kind && strlen(kind) > 64) {
        sf_json_free(body);
        respond_error(resp, 400, "validation", "kind is too long", NULL);
        return;
    }
    const sf_json *cnode = sf_json_object_get(body, "collection_id");
    int64_t collection_id = -2;  // keep
    if (cnode && cnode->type == SFJSON_NULL) collection_id = -1;
    else if (cnode && !cms_id_field(resp, body, "collection_id", -2,
                                    &collection_id)) {
        sf_json_free(body);
        return;
    }
    int md_present = 0;
    char *md_text = NULL;
    if (!cms_metadata_field(resp, body, "metadata", &md_present, &md_text)) {
        sf_json_free(body);
        return;
    }
    char *title_dup = title ? xstrdup(title) : NULL;
    char kind_buf[65];
    if (kind) snprintf(kind_buf, sizeof kind_buf, "%s", kind);
    sf_json_free(body);
    // Field edits only — this path never creates a version (§13.5).
    sf_result r = sf_cms_update_item(ctx->store, caller.tenant_id, iid,
                                     title_dup, kind ? kind_buf : NULL,
                                     collection_id,
                                     md_present ? md_text : NULL);
    free(title_dup);
    free(md_text);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "content:%lld", (long long)iid);
    audit(ctx, caller.tenant_id, &caller, "content.update", ref, "ok", "{}",
          req->remote_ip);
    memset(&it, 0, sizeof it);
    if (sf_cms_get_item(ctx->store, caller.tenant_id, iid, &it) == SF_OK) {
        sf_json *data = cms_item_json(&it);
        sf_cms_item_free(&it);
        respond_data(resp, 200, data);
        sf_json_free(data);
    } else {
        respond_result_error(resp, SF_ERR_NOT_FOUND);
    }
}

static void h_content_delete(sf_app_ctx *ctx, const sf_http_request *req,
                             sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.delete")) return;
    int64_t iid;
    if (!parse_login_id(id_seg, &iid)) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    char slug_buf[129] = "";
    sf_result r = sf_cms_delete_item(ctx->store, caller.tenant_id, iid,
                                     slug_buf, sizeof slug_buf);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "content:%lld", (long long)iid);
    char detail[256];
    snprintf(detail, sizeof detail, "{\"slug\":\"%s\"}", slug_buf);
    audit(ctx, caller.tenant_id, &caller, "content.delete", ref, "ok", detail,
          req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "deleted", 1);
    jnum(data, "id", iid);
    jstr(data, "slug", slug_buf);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

// ---- versions / rollback / state / downloads

static void h_versions_create(sf_app_ctx *ctx, const sf_http_request *req,
                              sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.version_create"))
        return;
    int64_t iid;
    if (!parse_login_id(id_seg, &iid)) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    int64_t blob_id = -1;
    if (!cms_id_field(resp, body, "blob_id", -1, &blob_id)) {
        sf_json_free(body);
        return;
    }
    const char *note = sf_json_get_string(body, "note");
    int md_present = 0;
    char *md_text = NULL;
    if (!cms_metadata_field(resp, body, "metadata", &md_present, &md_text)) {
        sf_json_free(body);
        return;
    }
    if (blob_id <= 0) {
        free(md_text);
        sf_json_free(body);
        respond_error(resp, 400, "validation",
                      "blob_id (positive, in your tenant) is required", NULL);
        return;
    }
    char *note_dup = xstrdup(note ? note : "");
    sf_json_free(body);
    if (!note_dup) {
        free(md_text);
        respond_error(resp, 500, "internal", "out of memory", NULL);
        return;
    }
    char actor[160];
    cms_actor_ref(&caller, actor, sizeof actor);
    sf_cms_version v;
    memset(&v, 0, sizeof v);
    // The attach primitive is one transaction: version row + blob
    // refcount + current_version_id. A cross-tenant blob or item id
    // is a scoped 404 (§13.7).
    sf_result r = sf_cms_append_version(ctx->store, caller.tenant_id, iid,
                                        blob_id, note_dup,
                                        md_text ? md_text : "{}", actor, &v);
    free(note_dup);
    free(md_text);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "content:%lld", (long long)iid);
    char detail[256];
    snprintf(detail, sizeof detail, "{\"version_no\":%lld,\"blob_id\":%lld}",
             (long long)v.version_no, (long long)blob_id);
    audit(ctx, caller.tenant_id, &caller, "content.version_create", ref, "ok",
          detail, req->remote_ip);
    sf_json *data = cms_version_json(&v);
    sf_cms_version_free(&v);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

static void h_versions_list(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.version_list"))
        return;
    int64_t iid;
    if (!parse_login_id(id_seg, &iid)) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    sf_cms_version *rows = NULL;
    size_t count = 0;
    sf_result r = sf_cms_list_versions(ctx->store, caller.tenant_id, iid,
                                       &rows, &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    for (size_t i = 0; i < count; i++) {
        if (!sf_json_array_append(arr, cms_version_json(&rows[i]))) break;
    }
    sf_cms_version_free_all(rows, count);
    respond_list(resp, arr, NULL);
    sf_json_free(arr);
}

static void h_content_rollback(sf_app_ctx *ctx, const sf_http_request *req,
                               sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.rollback")) return;
    int64_t iid;
    if (!parse_login_id(id_seg, &iid)) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    int64_t target = 0;
    int has = sf_json_get_int64(body, "version_no", &target);
    sf_json_free(body);
    if (!has || target <= 0) {
        respond_error(resp, 400, "validation", "version_no is required", NULL);
        return;
    }
    char actor[160];
    cms_actor_ref(&caller, actor, sizeof actor);
    sf_cms_version v;
    memset(&v, 0, sizeof v);
    sf_result r = sf_cms_rollback(ctx->store, caller.tenant_id, iid, target,
                                  actor, &v);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "content:%lld", (long long)iid);
    char detail[256];
    snprintf(detail, sizeof detail,
             "{\"version_no\":%lld,\"rollback_of\":%lld,\"blob_id\":%lld}",
             (long long)v.version_no, (long long)target, (long long)v.blob_id);
    audit(ctx, caller.tenant_id, &caller, "content.rollback", ref, "ok", detail,
          req->remote_ip);
    sf_json *data = cms_version_json(&v);
    sf_cms_version_free(&v);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

static void h_content_state(sf_app_ctx *ctx, const sf_http_request *req,
                            sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.state")) return;
    int64_t iid;
    if (!parse_login_id(id_seg, &iid)) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    const char *state = sf_json_get_string(body, "state");
    char state_buf[16] = "";
    if (state) snprintf(state_buf, sizeof state_buf, "%s", state);
    sf_json_free(body);
    if (strcmp(state_buf, "draft") != 0 && strcmp(state_buf, "published") != 0 &&
        strcmp(state_buf, "archived") != 0) {
        respond_error(resp, 400, "validation",
                      "state must be draft, published, or archived", NULL);
        return;
    }
    sf_result r = sf_cms_set_item_state(ctx->store, caller.tenant_id, iid,
                                        state_buf);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "content:%lld", (long long)iid);
    char detail[128];
    snprintf(detail, sizeof detail, "{\"state\":\"%s\"}", state_buf);
    audit(ctx, caller.tenant_id, &caller, "content.state", ref, "ok", detail,
          req->remote_ip);
    sf_cms_item it;
    memset(&it, 0, sizeof it);
    if (sf_cms_get_item(ctx->store, caller.tenant_id, iid, &it) == SF_OK) {
        sf_json *data = cms_item_json(&it);
        sf_cms_item_free(&it);
        respond_data(resp, 200, data);
        sf_json_free(data);
    } else {
        respond_result_error(resp, SF_ERR_NOT_FOUND);
    }
}

// Serve one version's bytes through the blob layer (§13.2): a
// corrupt blob refuses with 502 blob_integrity, exactly as the blob
// and object read paths do.
static void cms_serve_download(sf_app_ctx *ctx, sf_http_response *resp,
                               const sf_caller *caller, int64_t blob_id) {
    sf_blob blob;
    if (sf_blob_get_by_id(ctx->store, caller->tenant_id, blob_id, &blob) != SF_OK) {
        respond_error(resp, 404, "not_found", "content bytes not found", NULL);
        return;
    }
    if (strcmp(blob.state, "corrupt") == 0) {
        sf_json *d = sf_json_new_object();
        jnum(d, "blob_id", blob.id);
        jstr(d, "state", "corrupt");
        respond_error(resp, 502, "blob_integrity",
                      "blob failed integrity verification", d);
        sf_json_free(d);
        return;
    }
    uint8_t *data = NULL;
    size_t len = 0;
    sf_result r = blob_read_any(ctx, &blob, -1, &data, &len);
    if (r != SF_OK) {
        free(data);
        if (r == SF_ERR_NOT_FOUND)
            respond_error(resp, 404, "not_found", "content bytes not found", NULL);
        else if (r == SF_BLOB_ERR_CORRUPT) {
            sf_json *d = sf_json_new_object();
            jnum(d, "blob_id", blob.id);
            jstr(d, "state", "corrupt");
            respond_error(resp, 502, "blob_integrity",
                          "blob failed integrity verification", d);
            sf_json_free(d);
        } else {
            respond_error(resp, 502, "backend_unavailable",
                          "storage backend error", NULL);
        }
        return;
    }
    resp->status = 200;
    snprintf(resp->content_type, sizeof resp->content_type,
             "application/octet-stream");
    sf_http_response_set_header(resp, "X-Snowfell-SHA256", blob.sha256_hex);
    sf_http_response_set_body(resp, data, len);
}

static void h_content_download(sf_app_ctx *ctx, const sf_http_request *req,
                               sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.download"))
        return;
    int64_t iid;
    sf_cms_item it;
    memset(&it, 0, sizeof it);
    if (!parse_login_id(id_seg, &iid) ||
        sf_cms_get_item(ctx->store, caller.tenant_id, iid, &it) != SF_OK) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    int64_t blob_id = it.current_blob_id;
    sf_cms_item_free(&it);
    if (blob_id < 0) {
        respond_error(resp, 404, "not_found", "content item has no version", NULL);
        return;
    }
    cms_serve_download(ctx, resp, &caller, blob_id);
}

static void h_version_download(sf_app_ctx *ctx, const sf_http_request *req,
                               sf_http_response *resp, const char *id_seg,
                               const char *no_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.download"))
        return;
    int64_t iid, vno;
    sf_cms_version v;
    memset(&v, 0, sizeof v);
    if (!parse_login_id(id_seg, &iid) || !parse_login_id(no_seg, &vno) ||
        sf_cms_get_version(ctx->store, caller.tenant_id, iid, vno, &v) != SF_OK) {
        respond_error(resp, 404, "not_found", "content version not found", NULL);
        return;
    }
    int64_t blob_id = v.blob_id;
    sf_cms_version_free(&v);
    cms_serve_download(ctx, resp, &caller, blob_id);
}

// ---- refs

static void h_refs_create(sf_app_ctx *ctx, const sf_http_request *req,
                          sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.ref_create"))
        return;
    int64_t iid;
    if (!parse_login_id(id_seg, &iid)) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    sf_json *body = parse_body(resp, req);
    if (!body) return;
    int64_t to_item = -1, to_blob = -1;
    if (!cms_id_field(resp, body, "to_item_id", -1, &to_item) ||
        !cms_id_field(resp, body, "to_blob_id", -1, &to_blob)) {
        sf_json_free(body);
        return;
    }
    const char *kind = sf_json_get_string(body, "kind");
    if ((to_item >= 0) == (to_blob >= 0) || (kind && strlen(kind) > 64)) {
        sf_json_free(body);
        respond_error(resp, 400, "validation",
                      "exactly one of to_item_id / to_blob_id is required",
                      NULL);
        return;
    }
    char kind_buf[65];
    snprintf(kind_buf, sizeof kind_buf, "%s", kind ? kind : "");
    sf_json_free(body);
    sf_cms_ref rf;
    memset(&rf, 0, sizeof rf);
    // The attach primitive honors the exactly-one-target rule in code
    // (and the table CHECK backs it) and bumps a blob target's
    // refcount in the same transaction. Cross-tenant targets 404.
    sf_result r = sf_cms_create_ref(ctx->store, caller.tenant_id, iid, to_item,
                                    to_blob, kind_buf, &rf);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "content:%lld", (long long)iid);
    char detail[256];
    if (to_blob >= 0)
        snprintf(detail, sizeof detail, "{\"ref_id\":%lld,\"to_blob_id\":%lld}",
                 (long long)rf.id, (long long)to_blob);
    else
        snprintf(detail, sizeof detail, "{\"ref_id\":%lld,\"to_item_id\":%lld}",
                 (long long)rf.id, (long long)to_item);
    audit(ctx, caller.tenant_id, &caller, "content.ref_create", ref, "ok",
          detail, req->remote_ip);
    sf_json *data = cms_ref_json(&rf);
    respond_data(resp, 201, data);
    sf_json_free(data);
}

static void h_refs_list(sf_app_ctx *ctx, const sf_http_request *req,
                        sf_http_response *resp, const char *id_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.ref_list"))
        return;
    int64_t iid;
    if (!parse_login_id(id_seg, &iid)) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    sf_cms_ref *rows = NULL;
    size_t count = 0;
    sf_result r = sf_cms_list_refs(ctx->store, caller.tenant_id, iid, &rows,
                                   &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    for (size_t i = 0; i < count; i++) {
        if (!sf_json_array_append(arr, cms_ref_json(&rows[i]))) break;
    }
    sf_cms_ref_free_all(rows, count);
    respond_list(resp, arr, NULL);
    sf_json_free(arr);
}

static void h_ref_delete(sf_app_ctx *ctx, const sf_http_request *req,
                         sf_http_response *resp, const char *id_seg,
                         const char *ref_seg) {
    sf_caller caller;
    if (!require_login_caller(ctx, req, resp, &caller, "content.ref_delete"))
        return;
    int64_t iid;
    if (!parse_login_id(id_seg, &iid)) {
        respond_error(resp, 404, "not_found", "content item not found", NULL);
        return;
    }
    int64_t ref_id = -1;
    if (ref_seg) {
        if (!parse_login_id(ref_seg, &ref_id)) {
            respond_error(resp, 404, "not_found", "content ref not found", NULL);
            return;
        }
    } else {
        // Base-path form: ?ref_id= or a {"ref_id": n} body.
        char buf[64];
        if (sf_http_query(req, "ref_id", buf, sizeof buf)) {
            if (!parse_login_id(buf, &ref_id)) {
                respond_error(resp, 404, "not_found", "content ref not found", NULL);
                return;
            }
        } else if (req->body && req->body_len > 0) {
            sf_json *body = parse_body(resp, req);
            if (!body) return;
            int64_t v = 0;
            int has = sf_json_get_int64(body, "ref_id", &v);
            sf_json_free(body);
            if (!has || v <= 0) {
                respond_error(resp, 400, "validation", "ref_id is required", NULL);
                return;
            }
            ref_id = v;
        } else {
            respond_error(resp, 400, "validation", "ref_id is required", NULL);
            return;
        }
    }
    sf_result r = sf_cms_delete_ref(ctx->store, caller.tenant_id, iid, ref_id);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    char ref[300];
    snprintf(ref, sizeof ref, "content:%lld", (long long)iid);
    char detail[128];
    snprintf(detail, sizeof detail, "{\"ref_id\":%lld}", (long long)ref_id);
    audit(ctx, caller.tenant_id, &caller, "content.ref_delete", ref, "ok",
          detail, req->remote_ip);
    sf_json *data = sf_json_new_object();
    jbool(data, "deleted", 1);
    jnum(data, "ref_id", ref_id);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

// ---- search (§13.5)

static void h_search_content(sf_app_ctx *ctx, const sf_http_request *req,
                             sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    char q[1024] = "";
    sf_http_query(req, "q", q, sizeof q);
    if (caller.is_operator) {
        // §13.5: operator searches name their scope explicitly and
        // are audited; the response still contains only that tenant's
        // rows, resolved from the sealed mapping in-session.
        char tbuf[128] = "";
        if (!sf_http_query(req, "tenant", tbuf, sizeof tbuf) || !tbuf[0]) {
            respond_error(resp, 400, "validation",
                          "operator search requires a tenant parameter", NULL);
            return;
        }
        sf_tenant t;
        int all_digits = 1;
        for (const char *p = tbuf; *p; p++)
            if (!isdigit((unsigned char)*p)) { all_digits = 0; break; }
        sf_result r = all_digits
            ? sf_store_get_tenant(ctx->store, strtoll(tbuf, NULL, 10), &t)
            : sf_store_get_tenant_by_slug(ctx->store, tbuf, &t);
        if (r != SF_OK) {
            respond_error(resp, 404, "not_found", "tenant not found", NULL);
            return;
        }
        audit(ctx, t.id, &caller, "content.search", "", "ok", "{}",
              req->remote_ip);
        cms_items_query_respond(ctx, req, resp, &caller, t.id, q);
        return;
    }
    cms_items_query_respond(ctx, req, resp, &caller, caller.tenant_id, q);
}

// ------------------------------------------------------------- audit route

static void h_audit_list(sf_app_ctx *ctx, const sf_http_request *req,
                         sf_http_response *resp) {
    sf_caller caller;
    if (!require_auth(ctx, req, resp, &caller, 0)) return;
    int64_t filter_tenant;
    if (caller.is_operator) {
        filter_tenant = -1;
        char tbuf[128];
        if (sf_http_query(req, "tenant", tbuf, sizeof tbuf) && tbuf[0]) {
            sf_tenant t;
            int all_digits = 1;
            for (const char *p = tbuf; *p; p++)
                if (!isdigit((unsigned char)*p)) { all_digits = 0; break; }
            sf_result r = all_digits
                ? sf_store_get_tenant(ctx->store, strtoll(tbuf, NULL, 10), &t)
                : sf_store_get_tenant_by_slug(ctx->store, tbuf, &t);
            if (r == SF_OK) filter_tenant = t.id;
            else {
                respond_error(resp, 404, "not_found", "tenant not found", NULL);
                return;
            }
        }
    } else {
        if (strcmp(caller.role, "tenant_admin") != 0) {
            respond_error(resp, 403, "forbidden", "tenant admin or operator only", NULL);
            audit(ctx, caller.tenant_id, &caller, "audit.list", "", "denied", "{}",
                  req->remote_ip);
            return;
        }
        filter_tenant = caller.tenant_id; // forced to own tenant (§8)
    }
    int limit;
    int64_t cursor;
    if (!parse_pagination(req, resp, &limit, &cursor)) return;
    char action[128] = "";
    int has_action = sf_http_query(req, "action", action, sizeof action);
    sf_audit_entry *rows = NULL;
    size_t count = 0;
    sf_result r = sf_store_list_audit(ctx->store, filter_tenant,
                                      has_action ? action : NULL, cursor, limit,
                                      &rows, &count);
    if (r != SF_OK) { respond_result_error(resp, r); return; }
    sf_json *arr = sf_json_new_array();
    int64_t last = 0;
    for (size_t i = 0; i < count; i++) {
        sf_json *o = sf_json_new_object();
        jnum(o, "id", rows[i].id);
        jstr(o, "ts", rows[i].ts);
        if (rows[i].tenant_id < 0) jnull(o, "tenant_id");
        else jnum(o, "tenant_id", rows[i].tenant_id);
        jstr(o, "actor_kind", rows[i].actor_kind);
        jstr(o, "actor_ref", rows[i].actor_ref);
        jstr(o, "action", rows[i].action);
        jstr(o, "object_ref", rows[i].object_ref);
        jstr(o, "result", rows[i].result);
        sf_json *det = rows[i].detail_json ? sf_json_parse(rows[i].detail_json) : NULL;
        if (det && det->type == SFJSON_OBJECT) jset(o, "detail", det);
        else {
            if (det) sf_json_free(det);
            jset(o, "detail", sf_json_new_object());
        }
        if (!sf_json_array_append(arr, o)) sf_json_free(o);
        last = rows[i].id;
    }
    sf_audit_free_all(rows, count);
    char cbuf[32];
    respond_list(resp, arr, page_cursor(count, limit, last, cbuf, sizeof cbuf));
    sf_json_free(arr);
}

// ---------------------------------------------------------------- health

static void h_health(sf_app_ctx *ctx, const sf_http_request *req,
                     sf_http_response *resp) {
    (void)req;
    int64_t tenant_count = 0;
    int64_t cursor = 0;
    for (;;) {
        sf_tenant *rows = NULL;
        size_t count = 0;
        if (sf_store_list_tenants(ctx->store, cursor, 200, &rows, &count) != SF_OK)
            break;
        tenant_count += (int64_t)count;
        if (count > 0) cursor = rows[count - 1].id;
        sf_tenant_free_all(rows, count);
        if (count < 200) break;
    }
    sf_json *data = sf_json_new_object();
    jstr(data, "status", "ok");
    jstr(data, "version", "1");
    jstr(data, "service", "snowfell-storage");
    jnum(data, "uptime_seconds", sf_now_unix() - ctx->start_unix);
    jstr(data, "bind", ctx->bind_label);
    jnum(data, "tenant_count", tenant_count);
    respond_data(resp, 200, data);
    sf_json_free(data);
}

// -------------------------------------------------------------- dispatch

#define SF_MAX_SEGS 12

static int split_path(const char *path, char segs[][256], int max_segs) {
    int n = 0;
    const char *p = path;
    while (*p && n < max_segs) {
        while (*p == '/') p++;
        if (!*p) break;
        const char *start = p;
        while (*p && *p != '/') p++;
        size_t len = (size_t)(p - start);
        if (len >= 256) len = 255;
        memcpy(segs[n], start, len);
        segs[n][len] = '\0';
        n++;
    }
    return n;
}

static void dispatch(void *vctx, const sf_http_request *req,
                     sf_http_response *resp) {
    sf_app_ctx *ctx = (sf_app_ctx *)vctx;
    snprintf(g_actor_ref, sizeof g_actor_ref, "-");
    const char *m = req->method;
    int is_get = strcmp(m, "GET") == 0;
    int is_post = strcmp(m, "POST") == 0;
    int is_put = strcmp(m, "PUT") == 0;
    int is_patch = strcmp(m, "PATCH") == 0;
    int is_delete = strcmp(m, "DELETE") == 0;
    int is_head = strcmp(m, "HEAD") == 0;

    char segs[SF_MAX_SEGS][256];
    int n = split_path(req->path, segs, SF_MAX_SEGS);
    int handled = 1;

    if (n < 1 || strcmp(segs[0], "v1") != 0) {
        handled = 0;
    } else if (n == 2 && strcmp(segs[1], "health") == 0 && is_get) {
        h_health(ctx, req, resp);
    } else if (n >= 2 && strcmp(segs[1], "auth") == 0) {
        if (n == 3 && strcmp(segs[2], "login") == 0 && is_post)
            h_login(ctx, req, resp);
        else if (n == 3 && strcmp(segs[2], "logout") == 0 && is_post)
            h_logout(ctx, req, resp);
        else if (n == 3 && strcmp(segs[2], "me") == 0 && is_get)
            h_me(ctx, req, resp);
        else if (n == 3 && strcmp(segs[2], "password") == 0 && is_post)
            h_password_change(ctx, req, resp);
        else if (n == 3 && strcmp(segs[2], "tokens") == 0 && is_post)
            h_tokens_create(ctx, req, resp);
        else if (n == 3 && strcmp(segs[2], "tokens") == 0 && is_get)
            h_tokens_list(ctx, req, resp);
        else if (n == 4 && strcmp(segs[2], "tokens") == 0 && is_delete)
            h_tokens_delete(ctx, req, resp, segs[3]);
        else if (n == 4 && strcmp(segs[2], "password-reset") == 0 &&
                 strcmp(segs[3], "complete") == 0 && is_post)
            h_reset_complete(ctx, req, resp);
        else handled = 0;
    } else if (n >= 2 && strcmp(segs[1], "tenants") == 0) {
        if (n == 2 && is_post) h_tenants_create(ctx, req, resp);
        else if (n == 2 && is_get) h_tenants_list(ctx, req, resp);
        else if (n == 3 && is_get) h_tenant_get(ctx, req, resp, segs[2]);
        else if (n == 3 && is_patch) h_tenant_patch(ctx, req, resp, segs[2]);
        else if (n == 3 && is_delete) h_tenant_delete(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "usage") == 0 && is_get)
            h_tenant_usage(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "quota") == 0 && is_put)
            h_tenant_quota(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "logins") == 0 && is_post)
            h_logins_create(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "logins") == 0 && is_get)
            h_logins_list(ctx, req, resp, segs[2]);
        else if (n == 5 && strcmp(segs[3], "logins") == 0 && is_get)
            h_login_get(ctx, req, resp, segs[2], segs[4]);
        else if (n == 5 && strcmp(segs[3], "logins") == 0 && is_patch)
            h_login_patch(ctx, req, resp, segs[2], segs[4]);
        else if (n == 5 && strcmp(segs[3], "logins") == 0 && is_delete)
            h_login_delete(ctx, req, resp, segs[2], segs[4]);
        else if (n == 6 && strcmp(segs[3], "logins") == 0 &&
                 strcmp(segs[5], "password") == 0 && is_post)
            h_login_password_set(ctx, req, resp, segs[2], segs[4]);
        else if (n == 6 && strcmp(segs[3], "logins") == 0 &&
                 strcmp(segs[5], "password-resets") == 0 && is_post)
            h_login_reset_issue(ctx, req, resp, segs[2], segs[4]);
        else handled = 0;
    } else if (n >= 2 && strcmp(segs[1], "backends") == 0) {
        if (n == 2 && is_get) h_backends_list(ctx, req, resp);
        else if (n == 2 && is_post) h_backends_create(ctx, req, resp);
        else if (n == 3 && is_patch) h_backend_patch(ctx, req, resp, segs[2]);
        else handled = 0;
    } else if (n >= 2 && strcmp(segs[1], "buckets") == 0) {
        if (n == 2 && is_post) h_buckets_create(ctx, req, resp);
        else if (n == 2 && is_get) h_buckets_list(ctx, req, resp);
        else if (n == 3 && is_get) h_bucket_get(ctx, req, resp, segs[2]);
        else if (n == 3 && is_patch) h_bucket_patch(ctx, req, resp, segs[2]);
        else if (n == 3 && is_delete) h_bucket_delete(ctx, req, resp, segs[2]);
        else if (n >= 4 && strcmp(segs[3], "objects") == 0) {
            if (n == 4 && is_get) {
                h_objects_list(ctx, req, resp, segs[2]);
            } else if (n >= 5 && (is_get || is_head || is_delete)) {
                // Rebuild the key from the remaining segments.
                char key[1024];
                size_t off = 0;
                key[0] = '\0';
                for (int i = 4; i < n; i++) {
                    int w = snprintf(key + off, sizeof key - off, "%s%s",
                                     i > 4 ? "/" : "", segs[i]);
                    if (w < 0) break;
                    off += (size_t)w;
                    if (off >= sizeof key) { off = sizeof key - 1; break; }
                }
                if (is_get) h_object_get(ctx, req, resp, segs[2], key, 0);
                else if (is_head) h_object_get(ctx, req, resp, segs[2], key, 1);
                else h_object_delete(ctx, req, resp, segs[2], key);
            } else handled = 0;
        }
        else handled = 0;
    } else if (n >= 2 && strcmp(segs[1], "blobs") == 0) {
        if (n == 3 && is_get) h_blob_get(ctx, req, resp, segs[2], 0);
        else if (n == 4 && strcmp(segs[3], "meta") == 0 && is_get)
            h_blob_get(ctx, req, resp, segs[2], 1);
        else if (n == 4 && strcmp(segs[3], "verify") == 0 && is_post)
            h_blob_verify(ctx, req, resp, segs[2]);
        else if (n == 3 && is_delete) h_blob_delete(ctx, req, resp, segs[2]);
        else handled = 0;
    } else if (n == 2 && strcmp(segs[1], "gc") == 0 && is_post) {
        h_gc_tenant(ctx, req, resp);
    } else if (n >= 2 && strcmp(segs[1], "admin") == 0) {
        if (n == 3 && strcmp(segs[2], "gc") == 0 && is_post)
            h_gc_admin(ctx, req, resp);
        else if (n == 3 && strcmp(segs[2], "verify") == 0 && is_post)
            h_admin_verify(ctx, req, resp);
        else handled = 0;
    } else if (n == 3 && strcmp(segs[1], "stats") == 0 &&
               strcmp(segs[2], "dedup") == 0 && is_get) {
        h_stats_dedup(ctx, req, resp);
    } else if (n >= 2 && strcmp(segs[1], "collections") == 0) {
        if (n == 2 && is_post) h_collections_create(ctx, req, resp);
        else if (n == 2 && is_get) h_collections_list(ctx, req, resp);
        else if (n == 3 && is_get) h_collection_get(ctx, req, resp, segs[2]);
        else if (n == 3 && is_patch) h_collection_patch(ctx, req, resp, segs[2]);
        else if (n == 3 && is_delete) h_collection_delete(ctx, req, resp, segs[2]);
        else handled = 0;
    } else if (n >= 2 && strcmp(segs[1], "content") == 0) {
        if (n == 2 && is_post) h_content_create(ctx, req, resp);
        else if (n == 2 && is_get) h_content_list(ctx, req, resp);
        else if (n == 3 && is_get) h_content_get(ctx, req, resp, segs[2]);
        else if (n == 3 && is_patch) h_content_patch(ctx, req, resp, segs[2]);
        else if (n == 3 && is_delete) h_content_delete(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "versions") == 0 && is_post)
            h_versions_create(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "versions") == 0 && is_get)
            h_versions_list(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "rollback") == 0 && is_post)
            h_content_rollback(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "state") == 0 && is_post)
            h_content_state(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "download") == 0 && is_get)
            h_content_download(ctx, req, resp, segs[2]);
        else if (n == 6 && strcmp(segs[3], "versions") == 0 &&
                 strcmp(segs[5], "download") == 0 && is_get)
            h_version_download(ctx, req, resp, segs[2], segs[4]);
        else if (n == 4 && strcmp(segs[3], "refs") == 0 && is_post)
            h_refs_create(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "refs") == 0 && is_get)
            h_refs_list(ctx, req, resp, segs[2]);
        else if (n == 4 && strcmp(segs[3], "refs") == 0 && is_delete)
            h_ref_delete(ctx, req, resp, segs[2], NULL);
        else if (n == 5 && strcmp(segs[3], "refs") == 0 && is_delete)
            h_ref_delete(ctx, req, resp, segs[2], segs[4]);
        else handled = 0;
    } else if (n == 3 && strcmp(segs[1], "search") == 0 &&
               strcmp(segs[2], "content") == 0 && is_get) {
        h_search_content(ctx, req, resp);
    } else if (n == 2 && strcmp(segs[1], "audit") == 0 && is_get) {
        h_audit_list(ctx, req, resp);
    } else {
        handled = 0;
    }

    if (!handled) {
        respond_error(resp, 404, "not_found", "route not found", NULL);
    }
    log_line(ctx, req->method, req->path, resp->status);
}

void sf_register_routes(sf_http_server *srv, void *ctx) {
    if (!srv || !ctx) return;
    static const char *methods[] = {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"};
    for (size_t i = 0; i < sizeof methods / sizeof methods[0]; i++)
        sf_http_server_route(srv, methods[i], "/v1/*", dispatch, ctx);
    // Object PUT claims the raw body stream (spooling handler).
    sf_http_server_route_raw(srv, "PUT", "/v1/buckets/", h_object_put_raw, ctx);
    // Blob upload claims POST /v1/blobs (and delegates the
    // /v1/blobs/{id}/verify POST the prefix match also catches).
    sf_http_server_route_raw(srv, "POST", "/v1/blobs", h_blob_raw, ctx);
}
