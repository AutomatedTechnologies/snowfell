// sfauth.h — credentials, tokens, lockout, rate limiting, resets.
// Design record 03 §5. Secrets cross this API as plaintext exactly
// once (at set/verify time, in memory); only digests and PBKDF2
// outputs are ever stored. Nothing here logs a secret.
#ifndef SFAUTH_H
#define SFAUTH_H

#include "sfcommon.h"
#include "sfstore.h"

#define SF_TOKEN_BYTES 32          // 256-bit tokens
#define SF_LOCK_THRESHOLD 5        // consecutive failures before lock
#define SF_LOCK_MINUTES 15
#define SF_SESSION_TTL_SECONDS 43200       // 12 h
#define SF_API_TOKEN_TTL_SECONDS 2592000   // 30 d
#define SF_RESET_TTL_SECONDS 3600          // 1 h

// The authenticated caller, resolved from a bearer token.
typedef struct {
    int     is_operator;         // 1 = operator token (tenant scope = all)
    int64_t tenant_id;           // -1 when is_operator
    int64_t login_id;            // -1 when is_operator
    int64_t token_id;
    char    role[16];            // tenant_admin | tenant_user | operator
    char    username[65];        // "" for operator
    char    tenant_slug[65];     // "" for operator
} sf_caller;

// Set (or replace) a login's password credential. Salt is generated
// here; iterations = SF_PBKDF2_ITERATIONS. Also clears lockout state
// and stamps password_changed_at. Tenant scope is enforced by the
// caller's route layer; this function re-verifies the login belongs
// to tenant_id (SF_ERR_NOT_FOUND otherwise).
sf_result sf_auth_set_password(sf_store *s, int64_t tenant_id, int64_t login_id,
                               const char *new_password);

// Verify a password against a login's tenant+username. Outcomes:
//   SF_OK             — caller may proceed; failed counter reset
//   SF_ERR_AUTH       — wrong password (or no such login: identical)
//   SF_ERR_LOCKED     — lock in force (even for the right password)
//   SF_ERR_TENANT_STATE — tenant suspended/closed or login disabled
// On SF_OK, *login_out carries the login row. Failure counters and
// last_login_at are maintained here. ip is for audit.
sf_result sf_auth_verify_password(sf_store *s, const char *tenant_slug,
                                  const char *username, const char *password,
                                  const char *ip, sf_login *login_out,
                                  sf_tenant *tenant_out);

// Issue a token. Plaintext is returned in token_out (caller copies it
// into the response and forgets it); only SHA-256(plaintext) is stored.
// kind: "session" | "api" | "operator". label may be "".
// ttl_seconds <= 0 = kind default (never for operator: pass 0 = none).
sf_result sf_auth_issue_token(sf_store *s, int64_t tenant_id, int64_t login_id,
                              const char *kind, const char *label,
                              int64_t ttl_seconds,
                              char *token_out, size_t token_out_cap,
                              int64_t *token_id_out, sf_time expires_out);

// Resolve a presented bearer token to a caller. SF_ERR_AUTH covers
// unknown, revoked, and expired uniformly. Touches last_used_at.
sf_result sf_auth_resolve_token(sf_store *s, const char *presented, sf_caller *out);

// Revoke: one token by id (scoped: a login can only revoke its own;
// operator any), the presented token itself, or all of a login's
// tokens of a kind (kind NULL = all kinds).
sf_result sf_auth_revoke_token(sf_store *s, const sf_caller *scope,
                               int64_t token_id);
sf_result sf_auth_revoke_presented(sf_store *s, const char *presented);
sf_result sf_auth_revoke_login_tokens(sf_store *s, int64_t tenant_id,
                                      int64_t login_id, const char *kind);

// List a login's tokens (id, kind, label, created/expires/revoked —
// never the digest, never plaintext).
typedef struct {
    int64_t id;
    char kind[16];
    char label[129];
    sf_time created_at, expires_at, revoked_at, last_used_at;
} sf_token_info;
sf_result sf_auth_list_tokens(sf_store *s, int64_t tenant_id, int64_t login_id,
                              sf_token_info **out_rows, size_t *out_count);
void sf_token_info_free_all(sf_token_info *rows, size_t count);

// Password resets (design §5.4). Issue returns plaintext once.
sf_result sf_auth_issue_reset(sf_store *s, int64_t tenant_id, int64_t login_id,
                              const char *actor_ref, const char *ip,
                              char *token_out, size_t token_out_cap);
// Complete: valid + unused + unexpired -> set password, stamp used,
// revoke the login's sessions and other outstanding resets.
sf_result sf_auth_complete_reset(sf_store *s, const char *presented_token,
                                 const char *new_password, const char *ip);

// Operator bootstrap (design §5.5): if no operator token exists,
// create one and return its plaintext via token_out (the service
// entry point writes it to the 0600 bootstrap file). If one exists,
// returns SF_ERR_CONFLICT and token_out is untouched.
// On the first successful operator resolve, the service entry point
// deletes the bootstrap file (sf_auth_note_operator_authenticated is
// the hook: returns 1 exactly once, when the first operator token
// authentication happens).
sf_result sf_auth_bootstrap_operator(sf_store *s, char *token_out, size_t cap);
int sf_auth_note_operator_authenticated(void);

// Rate limiting (design §5.3): in-memory token buckets.
// sf_rate_allow_login(ip, tenant_slug, username) — 10/min per
// (tenant,username), 30/min per ip. sf_rate_allow_api(token_id) —
// 600/min. Return 1 = allowed, 0 = limited. *retry_after seconds.
int sf_rate_allow_login(const char *ip, const char *tenant_slug,
                        const char *username, int *retry_after);
int sf_rate_allow_api(int64_t token_id, int *retry_after);

#endif // SFAUTH_H
