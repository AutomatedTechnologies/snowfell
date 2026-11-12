// sfauth.c — credentials, tokens, lockout, resets, operator bootstrap,
// rate limiting (design record 03 §5). Plaintext secrets exist only in
// caller memory at set/verify/issue time; the store holds PBKDF2
// outputs (passwords) and SHA-256 digests (tokens, resets) only.
// Nothing in this file logs or audits a secret; audit detail carries
// ids and figures only.
#include "sfauth.h"
#include "sfsha256.h"

#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// The auth layer reads/writes the credential, token and reset tables
// through the store's handle: sfstore.h deliberately exposes no
// secret-derived row type, so those tables have exactly one writer —
// this file.
static sqlite3 *db_of(sf_store *s) { return sf_store_db(s); }

static void set_str(char *dst, size_t cap, const char *src) {
    size_t n;
    if (!dst || cap == 0) return;
    if (!src) src = "";
    n = strlen(src);
    if (n >= cap) n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static const char *col_text(sqlite3_stmt *st, int i) {
    const unsigned char *t = sqlite3_column_text(st, i);
    return t ? (const char *)t : "";
}

static sf_result map_sql_rc(int rc) {
    if (rc == SQLITE_CONSTRAINT) return SF_ERR_CONFLICT;
    if (rc == SQLITE_NOMEM) return SF_ERR_NOMEM;
    return SF_ERR_DB;
}

static sf_result step_done(sqlite3_stmt *st) {
    int rc = sqlite3_step(st);
    sf_result r = (rc == SQLITE_DONE) ? SF_OK : map_sql_rc(rc);
    sqlite3_finalize(st);
    return r;
}

static void audit(sf_store *s, int64_t tenant_id, const char *actor_kind,
                  const char *actor_ref, const char *action,
                  const char *object_ref, const char *result,
                  const char *detail_json, const char *ip) {
    (void)sf_store_audit(s, tenant_id, actor_kind, actor_ref, action,
                         object_ref, result, detail_json, ip);
}

// ---- credential row -----------------------------------------------------

typedef struct {
    int     exists;
    uint8_t salt[SF_SALT_LEN];
    uint8_t hash[SF_DERIVED_KEY_LEN];
    int64_t iterations;
    int64_t failed_attempts;
    char    locked_until[32];   // "" when NULL
} sf_cred;

static sf_result load_cred(sqlite3 *db, int64_t login_id, sf_cred *c) {
    sqlite3_stmt *st = NULL;
    const void *blob;
    int blen;
    memset(c, 0, sizeof *c);
    c->iterations = SF_PBKDF2_ITERATIONS;
    if (sqlite3_prepare_v2(db,
            "SELECT password_salt, password_hash, password_iterations, failed_attempts, locked_until FROM cs_credentials WHERE login_id = ? AND kind = 'password'",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, login_id);
    if (sqlite3_step(st) != SQLITE_ROW) {
        sqlite3_finalize(st);
        return SF_OK;   // c->exists == 0
    }
    c->exists = 1;
    blob = sqlite3_column_blob(st, 0);
    blen = sqlite3_column_bytes(st, 0);
    if (blob && blen == SF_SALT_LEN) memcpy(c->salt, blob, SF_SALT_LEN);
    blob = sqlite3_column_blob(st, 1);
    blen = sqlite3_column_bytes(st, 1);
    if (blob && blen == SF_DERIVED_KEY_LEN) memcpy(c->hash, blob, SF_DERIVED_KEY_LEN);
    if (sqlite3_column_type(st, 2) != SQLITE_NULL)
        c->iterations = sqlite3_column_int64(st, 2);
    c->failed_attempts = sqlite3_column_int64(st, 3);
    if (sqlite3_column_type(st, 4) != SQLITE_NULL)
        set_str(c->locked_until, sizeof c->locked_until, col_text(st, 4));
    sqlite3_finalize(st);
    return SF_OK;
}

// ---- passwords ------------------------------------------------------------

sf_result sf_auth_set_password(sf_store *s, int64_t tenant_id, int64_t login_id,
                               const char *new_password) {
    sf_login login;
    sqlite3_stmt *st = NULL;
    uint8_t salt[SF_SALT_LEN];
    uint8_t hash[SF_DERIVED_KEY_LEN];
    sf_time now;
    sf_result r;
    char ref[64];

    if (!s || !new_password || !new_password[0]) return SF_ERR_VALIDATION;
    r = sf_store_get_login(s, tenant_id, login_id, &login);
    if (r != SF_OK) return r;   // SF_ERR_NOT_FOUND when cross-tenant
    if (sf_random_bytes(salt, sizeof salt) != 0) return SF_ERR_IO;
    sf_pbkdf2_sha256(new_password, strlen(new_password), salt, sizeof salt,
                     SF_PBKDF2_ITERATIONS, hash, sizeof hash);
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db_of(s),
            "INSERT OR REPLACE INTO cs_credentials (login_id, kind, password_salt, password_hash, password_iterations, password_changed_at, failed_attempts, locked_until, created_at, updated_at) VALUES (?, 'password', ?, ?, ?, ?, 0, NULL, ?, ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, login_id);
    sqlite3_bind_blob(st, 2, salt, SF_SALT_LEN, SQLITE_TRANSIENT);
    sqlite3_bind_blob(st, 3, hash, SF_DERIVED_KEY_LEN, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 4, SF_PBKDF2_ITERATIONS);
    sqlite3_bind_text(st, 5, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 6, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 7, now, -1, SQLITE_TRANSIENT);
    r = step_done(st);
    if (r == SF_OK) {
        snprintf(ref, sizeof ref, "login:%lld", (long long)login_id);
        audit(s, tenant_id, "system", ref, "login.password_set", ref, "ok",
              "{}", NULL);
    }
    return r;
}

sf_result sf_auth_verify_password(sf_store *s, const char *tenant_slug,
                                  const char *username, const char *password,
                                  const char *ip, sf_login *login_out,
                                  sf_tenant *tenant_out) {
    sf_tenant tenant;
    sqlite3_stmt *st = NULL;
    sqlite3 *db;
    sf_cred cred;
    sf_login login;
    int64_t login_id = -1;
    char login_state[16];
    uint8_t derived[SF_DERIVED_KEY_LEN];
    sf_time now;
    sf_result r;
    char detail[192];

    if (!s || !tenant_slug || !username || !password) return SF_ERR_VALIDATION;
    db = db_of(s);

    // Unknown tenant == unknown login == wrong password: SF_ERR_AUTH.
    r = sf_store_get_tenant_by_slug(s, tenant_slug, &tenant);
    if (r != SF_OK) {
        snprintf(detail, sizeof detail,
                 "{\"tenant\":\"%s\",\"username\":\"%s\"}", tenant_slug, username);
        audit(s, -1, "system", username, "auth.login", tenant_slug, "denied",
              detail, ip);
        return SF_ERR_AUTH;
    }
    if (tenant_out) *tenant_out = tenant;
    if (strcmp(tenant.state, "active") != 0) {
        audit(s, tenant.id, "system", username, "auth.login", tenant_slug,
              "denied", "{\"reason\":\"tenant_state\"}", ip);
        return SF_ERR_TENANT_STATE;
    }

    if (sqlite3_prepare_v2(db,
            "SELECT id, state FROM cs_logins WHERE tenant_id = ? AND username = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant.id);
    sqlite3_bind_text(st, 2, username, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) {
        login_id = sqlite3_column_int64(st, 0);
        set_str(login_state, sizeof login_state, col_text(st, 1));
    }
    sqlite3_finalize(st); st = NULL;
    if (login_id < 0) {
        snprintf(detail, sizeof detail, "{\"username\":\"%s\"}", username);
        audit(s, tenant.id, "system", username, "auth.login", tenant_slug,
              "denied", detail, ip);
        return SF_ERR_AUTH;
    }
    if (strcmp(login_state, "active") != 0) {
        audit(s, tenant.id, "login", username, "auth.login", tenant_slug,
              "denied", "{\"reason\":\"login_disabled\"}", ip);
        return SF_ERR_TENANT_STATE;
    }

    r = load_cred(db, login_id, &cred);
    if (r != SF_OK) return r;
    if (!cred.exists) {
        audit(s, tenant.id, "login", username, "auth.login", tenant_slug,
              "denied", "{\"reason\":\"no_credential\"}", ip);
        return SF_ERR_AUTH;
    }

    sf_now_iso(now);
    // Lock check BEFORE the password compare: a lock in force refuses
    // even the correct password.
    if (cred.locked_until[0] && strcmp(cred.locked_until, now) > 0) {
        audit(s, tenant.id, "login", username, "auth.login", tenant_slug,
              "denied", "{\"reason\":\"locked\"}", ip);
        return SF_ERR_LOCKED;
    }
    if (cred.locked_until[0]) {
        // Lock expired: clear it and the counter before comparing.
        if (sqlite3_prepare_v2(db,
                "UPDATE cs_credentials SET failed_attempts = 0, locked_until = NULL, updated_at = ? WHERE login_id = ? AND kind = 'password'",
                -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
        sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 2, login_id);
        r = step_done(st); st = NULL;
        if (r != SF_OK) return r;
        cred.failed_attempts = 0;
        cred.locked_until[0] = '\0';
    }

    sf_pbkdf2_sha256(password, strlen(password), cred.salt, SF_SALT_LEN,
                     (uint32_t)cred.iterations, derived, sizeof derived);
    if (sf_ct_equal(derived, cred.hash, SF_DERIVED_KEY_LEN) != 0) {
        int64_t failed = cred.failed_attempts + 1;
        char locked_until[32];
        const char *lu = NULL;
        if (failed >= SF_LOCK_THRESHOLD) {
            sf_iso_from_unix(sf_now_unix() + (int64_t)SF_LOCK_MINUTES * 60,
                             locked_until);
            lu = locked_until;
        }
        if (sqlite3_prepare_v2(db,
                "UPDATE cs_credentials SET failed_attempts = ?, locked_until = ?, updated_at = ? WHERE login_id = ? AND kind = 'password'",
                -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
        sqlite3_bind_int64(st, 1, failed);
        if (lu) sqlite3_bind_text(st, 2, lu, -1, SQLITE_TRANSIENT);
        else sqlite3_bind_null(st, 2);
        sqlite3_bind_text(st, 3, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 4, login_id);
        r = step_done(st); st = NULL;
        if (r != SF_OK) return r;
        snprintf(detail, sizeof detail, "{\"failed_attempts\":%lld}",
                 (long long)failed);
        audit(s, tenant.id, "login", username, "auth.login", tenant_slug,
              "denied", detail, ip);
        return SF_ERR_AUTH;
    }

    // Success: reset the counter, clear any lock, stamp last_login_at.
    if (sqlite3_prepare_v2(db,
            "UPDATE cs_credentials SET failed_attempts = 0, locked_until = NULL, updated_at = ? WHERE login_id = ? AND kind = 'password'",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, login_id);
    r = step_done(st); st = NULL;
    if (r != SF_OK) return r;
    if (sqlite3_prepare_v2(db,
            "UPDATE cs_logins SET last_login_at = ?, updated_at = ? WHERE id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 3, login_id);
    r = step_done(st); st = NULL;
    if (r != SF_OK) return r;

    audit(s, tenant.id, "login", username, "auth.login", tenant_slug, "ok",
          "{}", ip);
    if (login_out) {
        r = sf_store_get_login(s, tenant.id, login_id, &login);
        if (r == SF_OK) *login_out = login;
        return r;
    }
    return SF_OK;
}

// ---- tokens ---------------------------------------------------------------

// Generate a fresh token: plaintext (base64url of 32 random bytes) in
// `plain`, its SHA-256 digest in `digest`.
static sf_result gen_token(char *plain, size_t cap, uint8_t digest[32]) {
    uint8_t raw[SF_TOKEN_BYTES];
    if (cap < sf_b64url_encoded_len(SF_TOKEN_BYTES) + 1) return SF_ERR_TOO_LARGE;
    if (sf_random_bytes(raw, sizeof raw) != 0) return SF_ERR_IO;
    sf_b64url_encode(raw, sizeof raw, plain);
    sf_sha256(plain, strlen(plain), digest);
    return SF_OK;
}

static int64_t kind_default_ttl(const char *kind) {
    if (strcmp(kind, "session") == 0) return SF_SESSION_TTL_SECONDS;
    if (strcmp(kind, "api") == 0) return SF_API_TOKEN_TTL_SECONDS;
    return 0;   // operator: none
}

static sf_result issue_token_impl(sf_store *s, int64_t tenant_id, int64_t login_id,
                                  const char *kind, const char *label,
                                  int64_t ttl_seconds,
                                  char *token_out, size_t token_out_cap,
                                  int64_t *token_id_out, sf_time expires_out) {
    sqlite3 *db = db_of(s);
    sqlite3_stmt *st = NULL;
    uint8_t digest[32];
    sf_time now;
    char expires[32];
    int has_expires = 0;
    sf_result r;
    int attempt;

    if (!kind || (strcmp(kind, "session") != 0 && strcmp(kind, "api") != 0 &&
                  strcmp(kind, "operator") != 0))
        return SF_ERR_VALIDATION;
    if (!token_out || token_out_cap == 0) return SF_ERR_VALIDATION;
    if (strcmp(kind, "operator") != 0) {
        sf_login login;
        r = sf_store_get_login(s, tenant_id, login_id, &login);
        if (r != SF_OK) return r;
    }
    if (ttl_seconds <= 0) ttl_seconds = kind_default_ttl(kind);
    sf_now_iso(now);
    if (ttl_seconds > 0) {
        sf_iso_from_unix(sf_now_unix() + ttl_seconds, expires);
        has_expires = 1;
    }

    for (attempt = 0; attempt < 5; attempt++) {
        r = gen_token(token_out, token_out_cap, digest);
        if (r != SF_OK) return r;
        if (sqlite3_prepare_v2(db,
                "INSERT INTO cs_tokens (tenant_id, login_id, kind, token_sha256, label, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
        if (tenant_id > 0) sqlite3_bind_int64(st, 1, tenant_id);
        else sqlite3_bind_null(st, 1);
        if (login_id > 0) sqlite3_bind_int64(st, 2, login_id);
        else sqlite3_bind_null(st, 2);
        sqlite3_bind_text(st, 3, kind, -1, SQLITE_TRANSIENT);
        sqlite3_bind_blob(st, 4, digest, 32, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 5, label ? label : "", -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 6, now, -1, SQLITE_TRANSIENT);
        if (has_expires) sqlite3_bind_text(st, 7, expires, -1, SQLITE_TRANSIENT);
        else sqlite3_bind_null(st, 7);
        r = step_done(st); st = NULL;
        if (r == SF_ERR_CONFLICT) continue;   // digest collision: re-roll
        if (r != SF_OK) return r;
        if (token_id_out) *token_id_out = sqlite3_last_insert_rowid(db);
        if (expires_out) set_str(expires_out, 32, has_expires ? expires : "");
        return SF_OK;
    }
    return SF_ERR_CONFLICT;
}

sf_result sf_auth_issue_token(sf_store *s, int64_t tenant_id, int64_t login_id,
                              const char *kind, const char *label,
                              int64_t ttl_seconds,
                              char *token_out, size_t token_out_cap,
                              int64_t *token_id_out, sf_time expires_out) {
    sf_result r;
    char detail[128];
    if (!s) return SF_ERR_VALIDATION;
    r = issue_token_impl(s, tenant_id, login_id, kind, label, ttl_seconds,
                         token_out, token_out_cap, token_id_out, expires_out);
    if (r == SF_OK && token_id_out) {
        snprintf(detail, sizeof detail, "{\"token_id\":%lld,\"kind\":\"%s\"}",
                 (long long)*token_id_out, kind ? kind : "");
        audit(s, tenant_id > 0 ? tenant_id : -1, "system", "",
              "auth.token_issue", "", "ok", detail, NULL);
    }
    return r;
}

// Token row lite, fetched by digest (resolve/revoke_presented) or id.
typedef struct {
    int     exists;
    int64_t id;
    int64_t tenant_id;    // -1 when NULL (operator)
    int64_t login_id;     // -1 when NULL (operator)
    char    kind[16];
    uint8_t digest[32];
    char    expires_at[32];
    char    revoked_at[32];
} sf_token_row;

static sf_result load_token_by_digest(sqlite3 *db, const uint8_t digest[32],
                                      sf_token_row *t) {
    sqlite3_stmt *st = NULL;
    const void *blob;
    int blen;
    memset(t, 0, sizeof *t);
    t->tenant_id = -1; t->login_id = -1;
    if (sqlite3_prepare_v2(db,
            "SELECT id, tenant_id, login_id, kind, token_sha256, expires_at, revoked_at FROM cs_tokens WHERE token_sha256 = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_blob(st, 1, digest, 32, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) {
        t->exists = 1;
        t->id = sqlite3_column_int64(st, 0);
        if (sqlite3_column_type(st, 1) != SQLITE_NULL) t->tenant_id = sqlite3_column_int64(st, 1);
        if (sqlite3_column_type(st, 2) != SQLITE_NULL) t->login_id = sqlite3_column_int64(st, 2);
        set_str(t->kind, sizeof t->kind, col_text(st, 3));
        blob = sqlite3_column_blob(st, 4);
        blen = sqlite3_column_bytes(st, 4);
        if (blob && blen == 32) memcpy(t->digest, blob, 32);
        if (sqlite3_column_type(st, 5) != SQLITE_NULL)
            set_str(t->expires_at, sizeof t->expires_at, col_text(st, 5));
        if (sqlite3_column_type(st, 6) != SQLITE_NULL)
            set_str(t->revoked_at, sizeof t->revoked_at, col_text(st, 6));
    }
    sqlite3_finalize(st);
    return SF_OK;
}

static sf_result load_token_by_id(sqlite3 *db, int64_t token_id, sf_token_row *t) {
    sqlite3_stmt *st = NULL;
    memset(t, 0, sizeof *t);
    t->tenant_id = -1; t->login_id = -1;
    if (sqlite3_prepare_v2(db,
            "SELECT id, tenant_id, login_id, kind, expires_at, revoked_at FROM cs_tokens WHERE id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, token_id);
    if (sqlite3_step(st) == SQLITE_ROW) {
        t->exists = 1;
        t->id = sqlite3_column_int64(st, 0);
        if (sqlite3_column_type(st, 1) != SQLITE_NULL) t->tenant_id = sqlite3_column_int64(st, 1);
        if (sqlite3_column_type(st, 2) != SQLITE_NULL) t->login_id = sqlite3_column_int64(st, 2);
        set_str(t->kind, sizeof t->kind, col_text(st, 3));
        if (sqlite3_column_type(st, 4) != SQLITE_NULL)
            set_str(t->expires_at, sizeof t->expires_at, col_text(st, 4));
        if (sqlite3_column_type(st, 5) != SQLITE_NULL)
            set_str(t->revoked_at, sizeof t->revoked_at, col_text(st, 5));
    }
    sqlite3_finalize(st);
    return SF_OK;
}

static sf_result revoke_token_row(sqlite3 *db, int64_t token_id) {
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db,
            "UPDATE cs_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, token_id);
    return step_done(st);
}

// Once-only first-operator-auth hook state (design §5.5).
static int g_operator_auth_happened = 0;
static int g_operator_auth_reported = 0;

int sf_auth_note_operator_authenticated(void) {
    if (g_operator_auth_happened && !g_operator_auth_reported) {
        g_operator_auth_reported = 1;
        return 1;
    }
    return 0;
}

sf_result sf_auth_resolve_token(sf_store *s, const char *presented, sf_caller *out) {
    uint8_t digest[32];
    sf_token_row t;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r;

    if (!s || !presented || !presented[0] || !out) return SF_ERR_AUTH;
    memset(out, 0, sizeof *out);
    out->tenant_id = -1;
    out->login_id = -1;
    // Hash the presented token; compare digests in constant time.
    sf_sha256(presented, strlen(presented), digest);
    r = load_token_by_digest(db_of(s), digest, &t);
    if (r != SF_OK) return r;
    if (!t.exists) return SF_ERR_AUTH;
    if (sf_ct_equal(digest, t.digest, 32) != 0) return SF_ERR_AUTH;
    if (t.revoked_at[0]) return SF_ERR_AUTH;
    sf_now_iso(now);
    if (t.expires_at[0] && strcmp(t.expires_at, now) <= 0) return SF_ERR_AUTH;

    out->token_id = t.id;
    out->is_operator = (strcmp(t.kind, "operator") == 0) ? 1 : 0;
    if (out->is_operator) {
        set_str(out->role, sizeof out->role, "operator");
        g_operator_auth_happened = 1;
    } else {
        sf_login login;
        sf_tenant tenant;
        r = sf_store_get_login(s, t.tenant_id, t.login_id, &login);
        if (r != SF_OK) return SF_ERR_AUTH;
        r = sf_store_get_tenant(s, t.tenant_id, &tenant);
        if (r != SF_OK) return SF_ERR_AUTH;
        out->tenant_id = t.tenant_id;
        out->login_id = t.login_id;
        set_str(out->role, sizeof out->role, login.role);
        set_str(out->username, sizeof out->username, login.username);
        set_str(out->tenant_slug, sizeof out->tenant_slug, tenant.slug);
    }

    // Touch last_used_at (best-effort: a failed touch never fails auth).
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_tokens SET last_used_at = ? WHERE id = ?",
            -1, &st, NULL) == SQLITE_OK) {
        sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(st, 2, t.id);
        (void)step_done(st);
    }
    return SF_OK;
}

sf_result sf_auth_revoke_token(sf_store *s, const sf_caller *scope,
                               int64_t token_id) {
    sf_token_row t;
    sf_result r;
    char detail[96];
    if (!s || !scope) return SF_ERR_FORBIDDEN;
    r = load_token_by_id(db_of(s), token_id, &t);
    if (r != SF_OK) return r;
    if (!t.exists) return SF_ERR_NOT_FOUND;
    if (!scope->is_operator) {
        // A login-scope caller revokes only its own tokens.
        if (scope->login_id != t.login_id || scope->tenant_id != t.tenant_id)
            return SF_ERR_FORBIDDEN;
    }
    r = revoke_token_row(db_of(s), token_id);
    if (r == SF_OK) {
        snprintf(detail, sizeof detail, "{\"token_id\":%lld}", (long long)token_id);
        audit(s, t.tenant_id, scope->is_operator ? "operator" : "login",
              scope->username, "auth.token_revoke", "", "ok", detail, NULL);
    }
    return r;
}

sf_result sf_auth_revoke_presented(sf_store *s, const char *presented) {
    uint8_t digest[32];
    sf_token_row t;
    sf_result r;
    if (!s || !presented || !presented[0]) return SF_ERR_AUTH;
    sf_sha256(presented, strlen(presented), digest);
    r = load_token_by_digest(db_of(s), digest, &t);
    if (r != SF_OK) return r;
    if (!t.exists || sf_ct_equal(digest, t.digest, 32) != 0) return SF_ERR_AUTH;
    return revoke_token_row(db_of(s), t.id);
}

sf_result sf_auth_revoke_login_tokens(sf_store *s, int64_t tenant_id,
                                      int64_t login_id, const char *kind) {
    sf_login login;
    sqlite3_stmt *st = NULL;
    sf_time now;
    sf_result r = sf_store_get_login(s, tenant_id, login_id, &login);
    if (r != SF_OK) return r;
    sf_now_iso(now);
    if (sqlite3_prepare_v2(db_of(s),
            "UPDATE cs_tokens SET revoked_at = ? WHERE tenant_id = ? AND login_id = ? AND revoked_at IS NULL AND (? IS NULL OR kind = ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, tenant_id);
    sqlite3_bind_int64(st, 3, login_id);
    if (kind) {
        sqlite3_bind_text(st, 4, kind, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(st, 5, kind, -1, SQLITE_TRANSIENT);
    } else {
        sqlite3_bind_null(st, 4);
        sqlite3_bind_null(st, 5);
    }
    return step_done(st);
}

sf_result sf_auth_list_tokens(sf_store *s, int64_t tenant_id, int64_t login_id,
                              sf_token_info **out_rows, size_t *out_count) {
    sqlite3_stmt *st = NULL;
    sf_token_info *rows = NULL;
    size_t count = 0, cap = 0;
    int rc;
    if (!s || !out_rows || !out_count) return SF_ERR_VALIDATION;
    *out_rows = NULL; *out_count = 0;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT id, kind, label, created_at, expires_at, revoked_at, last_used_at FROM cs_tokens WHERE tenant_id = ? AND login_id = ? ORDER BY id ASC",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, tenant_id);
    sqlite3_bind_int64(st, 2, login_id);
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        sf_token_info *ti;
        if (count == cap) {
            size_t ncap = cap ? cap * 2 : 8;
            sf_token_info *nr = (sf_token_info *)realloc(rows, ncap * sizeof *nr);
            if (!nr) { free(rows); sqlite3_finalize(st); return SF_ERR_NOMEM; }
            rows = nr; cap = ncap;
        }
        ti = &rows[count++];
        memset(ti, 0, sizeof *ti);
        ti->id = sqlite3_column_int64(st, 0);
        set_str(ti->kind, sizeof ti->kind, col_text(st, 1));
        set_str(ti->label, sizeof ti->label, col_text(st, 2));
        set_str(ti->created_at, sizeof ti->created_at, col_text(st, 3));
        if (sqlite3_column_type(st, 4) != SQLITE_NULL)
            set_str(ti->expires_at, sizeof ti->expires_at, col_text(st, 4));
        if (sqlite3_column_type(st, 5) != SQLITE_NULL)
            set_str(ti->revoked_at, sizeof ti->revoked_at, col_text(st, 5));
        if (sqlite3_column_type(st, 6) != SQLITE_NULL)
            set_str(ti->last_used_at, sizeof ti->last_used_at, col_text(st, 6));
    }
    sqlite3_finalize(st);
    if (rc != SQLITE_DONE) { free(rows); return map_sql_rc(rc); }
    *out_rows = rows;
    *out_count = count;
    return SF_OK;
}

void sf_token_info_free_all(sf_token_info *rows, size_t count) {
    (void)count;
    free(rows);
}

// ---- password resets --------------------------------------------------------

sf_result sf_auth_issue_reset(sf_store *s, int64_t tenant_id, int64_t login_id,
                              const char *actor_ref, const char *ip,
                              char *token_out, size_t token_out_cap) {
    sf_login login;
    sqlite3 *db;
    sqlite3_stmt *st = NULL;
    uint8_t digest[32];
    sf_time now;
    char expires[32];
    sf_result r;
    char detail[96];

    if (!s || !token_out) return SF_ERR_VALIDATION;
    r = sf_store_get_login(s, tenant_id, login_id, &login);
    if (r != SF_OK) return r;
    db = db_of(s);
    r = gen_token(token_out, token_out_cap, digest);
    if (r != SF_OK) return r;
    sf_now_iso(now);
    sf_iso_from_unix(sf_now_unix() + SF_RESET_TTL_SECONDS, expires);

    // A new issue invalidates every prior unused reset for the login.
    if (sqlite3_prepare_v2(db,
            "DELETE FROM cs_password_resets WHERE login_id = ? AND used_at IS NULL",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, login_id);
    r = step_done(st); st = NULL;
    if (r != SF_OK) return r;

    if (sqlite3_prepare_v2(db,
            "INSERT INTO cs_password_resets (login_id, token_sha256, created_by, created_at, expires_at) VALUES (?, ?, ?, ?, ?)",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, login_id);
    sqlite3_bind_blob(st, 2, digest, 32, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, actor_ref ? actor_ref : "", -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 4, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 5, expires, -1, SQLITE_TRANSIENT);
    r = step_done(st); st = NULL;
    if (r == SF_OK) {
        snprintf(detail, sizeof detail, "{\"login_id\":%lld}", (long long)login_id);
        audit(s, tenant_id, "login", actor_ref ? actor_ref : "",
              "auth.reset_issue", "", "ok", detail, ip);
    }
    return r;
}

sf_result sf_auth_complete_reset(sf_store *s, const char *presented_token,
                                 const char *new_password, const char *ip) {
    uint8_t digest[32];
    sqlite3 *db;
    sqlite3_stmt *st = NULL;
    int64_t reset_id = -1, login_id = -1, tenant_id = -1;
    char expires[32] = "";
    int used = 0;
    sf_time now;
    sf_result r;
    char detail[96];

    if (!s || !presented_token || !presented_token[0] ||
        !new_password || !new_password[0]) return SF_ERR_VALIDATION;
    db = db_of(s);
    sf_sha256(presented_token, strlen(presented_token), digest);
    if (sqlite3_prepare_v2(db,
            "SELECT r.id, r.login_id, l.tenant_id, r.expires_at, r.used_at, r.token_sha256 FROM cs_password_resets r JOIN cs_logins l ON l.id = r.login_id WHERE r.token_sha256 = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_blob(st, 1, digest, 32, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) {
        const void *blob = sqlite3_column_blob(st, 5);
        int blen = sqlite3_column_bytes(st, 5);
        uint8_t stored[32];
        memset(stored, 0, sizeof stored);
        if (blob && blen == 32) memcpy(stored, blob, 32);
        if (sf_ct_equal(digest, stored, 32) == 0) {
            reset_id = sqlite3_column_int64(st, 0);
            login_id = sqlite3_column_int64(st, 1);
            tenant_id = sqlite3_column_int64(st, 2);
            set_str(expires, sizeof expires, col_text(st, 3));
            used = (sqlite3_column_type(st, 4) != SQLITE_NULL);
        }
    }
    sqlite3_finalize(st); st = NULL;
    // Unknown, already used, and expired are indistinguishable: SF_ERR_AUTH.
    sf_now_iso(now);
    if (reset_id < 0 || used || (expires[0] && strcmp(expires, now) <= 0)) {
        audit(s, tenant_id > 0 ? tenant_id : -1, "system", "",
              "auth.reset_complete", "", "denied", "{}", ip);
        return SF_ERR_AUTH;
    }

    // Set the password (also clears lockout), then consume the reset,
    // revoke the login's sessions, and drop its other resets — one
    // logical act; each step is a single prepared statement.
    r = sf_auth_set_password(s, tenant_id, login_id, new_password);
    if (r != SF_OK) return r;

    if (sqlite3_prepare_v2(db,
            "UPDATE cs_password_resets SET used_at = ? WHERE id = ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_text(st, 1, now, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(st, 2, reset_id);
    r = step_done(st); st = NULL;
    if (r != SF_OK) return r;

    r = sf_auth_revoke_login_tokens(s, tenant_id, login_id, "session");
    if (r != SF_OK) return r;

    if (sqlite3_prepare_v2(db,
            "DELETE FROM cs_password_resets WHERE login_id = ? AND used_at IS NULL AND id <> ?",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    sqlite3_bind_int64(st, 1, login_id);
    sqlite3_bind_int64(st, 2, reset_id);
    r = step_done(st); st = NULL;
    if (r != SF_OK) return r;

    snprintf(detail, sizeof detail, "{\"login_id\":%lld}", (long long)login_id);
    audit(s, tenant_id, "system", "", "auth.reset_complete", "", "ok",
          detail, ip);
    return SF_OK;
}

// ---- operator bootstrap -----------------------------------------------------

sf_result sf_auth_bootstrap_operator(sf_store *s, char *token_out, size_t cap) {
    sqlite3_stmt *st = NULL;
    int64_t n = 0;
    sf_result r;
    if (!s || !token_out) return SF_ERR_VALIDATION;
    if (sqlite3_prepare_v2(db_of(s),
            "SELECT COUNT(*) FROM cs_tokens WHERE kind = 'operator'",
            -1, &st, NULL) != SQLITE_OK) return SF_ERR_DB;
    if (sqlite3_step(st) == SQLITE_ROW) n = sqlite3_column_int64(st, 0);
    sqlite3_finalize(st);
    if (n > 0) return SF_ERR_CONFLICT;   // token_out untouched
    r = issue_token_impl(s, -1, -1, "operator", "bootstrap", 0,
                         token_out, cap, NULL, NULL);
    if (r == SF_OK)
        audit(s, -1, "system", "", "auth.operator_bootstrap", "", "ok",
              "{}", NULL);
    return r;
}

// ---- rate limiting ------------------------------------------------------------
// Fixed-window counters (the design's "token bucket" realized as a
// fixed window — chosen over a sliding token bucket for O(1) state and
// an exact Retry-After: the window end). Windows are 60 s, aligned to
// the unix minute. Volatile by design (design §5.3): a restart clears
// every bucket; the durable abuse control is the DB lockout above.

typedef struct {
    char    key[192];
    int64_t window;      // window start (unix seconds)
    int     count;
    int     used;
} sf_rl_str_entry;

typedef struct {
    int64_t token_id;
    int64_t window;
    int     count;
    int     used;
} sf_rl_api_entry;

#define SF_RL_STR_SLOTS 256
#define SF_RL_API_SLOTS 512
static sf_rl_str_entry g_rl_login_user[SF_RL_STR_SLOTS];
static sf_rl_str_entry g_rl_login_ip[SF_RL_STR_SLOTS];
static sf_rl_api_entry g_rl_api[SF_RL_API_SLOTS];

static sf_rl_str_entry *rl_str_slot(sf_rl_str_entry *tab, size_t n,
                                    const char *key, int64_t window) {
    size_t i, empty = n, oldest = 0;
    int64_t oldest_window = INT64_MAX;
    for (i = 0; i < n; i++) {
        if (tab[i].used && strcmp(tab[i].key, key) == 0) {
            if (tab[i].window != window) { tab[i].window = window; tab[i].count = 0; }
            return &tab[i];
        }
        if (!tab[i].used && empty == n) empty = i;
        if (tab[i].used && tab[i].window < oldest_window) {
            oldest = i; oldest_window = tab[i].window;
        }
    }
    if (empty == n) empty = oldest;   // evict the stalest window
    tab[empty].used = 1;
    set_str(tab[empty].key, sizeof tab[empty].key, key);
    tab[empty].window = window;
    tab[empty].count = 0;
    return &tab[empty];
}

static sf_rl_api_entry *rl_api_slot(int64_t token_id, int64_t window) {
    size_t i, empty = SF_RL_API_SLOTS, oldest = 0;
    int64_t oldest_window = INT64_MAX;
    for (i = 0; i < SF_RL_API_SLOTS; i++) {
        if (g_rl_api[i].used && g_rl_api[i].token_id == token_id) {
            if (g_rl_api[i].window != window) {
                g_rl_api[i].window = window; g_rl_api[i].count = 0;
            }
            return &g_rl_api[i];
        }
        if (!g_rl_api[i].used && empty == SF_RL_API_SLOTS) empty = i;
        if (g_rl_api[i].used && g_rl_api[i].window < oldest_window) {
            oldest = i; oldest_window = g_rl_api[i].window;
        }
    }
    if (empty == SF_RL_API_SLOTS) empty = oldest;
    g_rl_api[empty].used = 1;
    g_rl_api[empty].token_id = token_id;
    g_rl_api[empty].window = window;
    g_rl_api[empty].count = 0;
    return &g_rl_api[empty];
}

int sf_rate_allow_login(const char *ip, const char *tenant_slug,
                        const char *username, int *retry_after) {
    int64_t now = sf_now_unix();
    int64_t window = now - (now % 60);
    int retry = (int)(window + 60 - now);
    char key[192];
    sf_rl_str_entry *by_user, *by_ip;
    if (retry_after) *retry_after = 0;
    if (retry <= 0) retry = 1;
    snprintf(key, sizeof key, "%s\n%s", tenant_slug ? tenant_slug : "",
             username ? username : "");
    by_user = rl_str_slot(g_rl_login_user, SF_RL_STR_SLOTS, key, window);
    by_ip = rl_str_slot(g_rl_login_ip, SF_RL_STR_SLOTS, ip ? ip : "", window);
    if (by_user->count >= 10 || by_ip->count >= 30) {
        if (retry_after) *retry_after = retry;
        return 0;
    }
    by_user->count++;
    by_ip->count++;
    return 1;
}

int sf_rate_allow_api(int64_t token_id, int *retry_after) {
    int64_t now = sf_now_unix();
    int64_t window = now - (now % 60);
    int retry = (int)(window + 60 - now);
    sf_rl_api_entry *e;
    if (retry_after) *retry_after = 0;
    if (retry <= 0) retry = 1;
    e = rl_api_slot(token_id, window);
    if (e->count >= 600) {
        if (retry_after) *retry_after = retry;
        return 0;
    }
    e->count++;
    return 1;
}
