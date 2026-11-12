// sfauth_test.c — end-to-end assertions for sfstore + sfauth
// (SF-T12c). Builds a temp store and exercises the contract behaviors
// from sfauth.h / sfstore.h / design record 03 §5. Prints PASS/FAIL
// per case and a final verdict; exits non-zero on any failure.
// Fixture passwords are throwaway constants in this source only and
// are never printed.
#include "sfauth.h"
#include "sfsha256.h"

#include <sqlite3.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int g_pass = 0, g_fail = 0;

#define CHECK(name, cond) do { \
    if (cond) { g_pass++; printf("PASS %s\n", name); } \
    else { g_fail++; printf("FAIL %s\n", name); } \
} while (0)

#define PW_ALICE_1 "fixture-alice-first"
#define PW_ALICE_2 "fixture-alice-second"
#define PW_CAROL   "fixture-carol-pass"
#define PW_BOB     "fixture-bob-pass"
#define PW_DAVE    "fixture-dave-pass"
#define PW_WRONG   "fixture-not-the-password"

static const char *DB_PATH = "/tmp/sfauth_test_cloud.db";

int main(void) {
    sf_store *s;
    sf_tenant ta, tb;
    sf_backend be;
    sf_login alice, bob, carol, dave, tmp_login;
    sf_tenant tmp_tenant;
    sf_bucket bucket, got_bucket;
    sf_object obj;
    char op_token[128];
    char op_token2[128];
    sf_caller caller, op_caller, bob_caller;
    char tok[128], tok2[128], tok3[128];
    int64_t tok_id = 0, tok2_id = 0;
    sf_time exp;
    sf_token_info *tinfos = NULL;
    size_t tinf_count = 0;
    char reset_tok[128], reset_tok2[128];
    uint8_t hash[32];
    int64_t ub = 0, uo = 0, ubc = 0;
    sf_audit_entry *audit_rows = NULL;
    size_t audit_count = 0;
    int i, ok;

    remove(DB_PATH);
    s = sf_store_open(DB_PATH);
    CHECK("store_open_bootstraps", s != NULL);
    if (!s) { printf("VERDICT FAIL (no store)\n"); return 1; }

    // Reopen proves the version check accepts an existing DB.
    {
        sf_store *s2 = NULL;
        sf_store_close(s);
        s2 = sf_store_open(DB_PATH);
        CHECK("store_reopen_existing", s2 != NULL);
        s = s2;
        if (!s) { printf("VERDICT FAIL (reopen)\n"); return 1; }
    }

    // ---- operator bootstrap: once only --------------------------------
    memset(op_token, 0, sizeof op_token);
    CHECK("bootstrap_operator_first",
          sf_auth_bootstrap_operator(s, op_token, sizeof op_token) == SF_OK &&
          op_token[0] != '\0');
    memset(op_token2, 'X', sizeof op_token2);
    CHECK("bootstrap_operator_second_conflict",
          sf_auth_bootstrap_operator(s, op_token2, sizeof op_token2) == SF_ERR_CONFLICT &&
          op_token2[0] == 'X');   // untouched on conflict

    // ---- tenants / backend / logins ------------------------------------
    CHECK("create_tenant_a",
          sf_store_create_tenant(s, "alpha", "Alpha", -1, -1, -1, "", &ta) == SF_OK);
    CHECK("create_tenant_b",
          sf_store_create_tenant(s, "beta", "Beta", -1, -1, -1, "", &tb) == SF_OK);
    CHECK("create_tenant_dup_slug_conflict",
          sf_store_create_tenant(s, "alpha", "Again", -1, -1, -1, "", &tmp_tenant) == SF_ERR_CONFLICT);
    CHECK("create_backend",
          sf_store_create_backend(s, "fs1", "filesystem", "{}", "", &be) == SF_OK);
    sf_backend_free(&be);

    CHECK("create_login_alice",
          sf_store_create_login(s, ta.id, "alice", "Alice A", "tenant_admin", &alice) == SF_OK);
    CHECK("create_login_bob_other_tenant",
          sf_store_create_login(s, tb.id, "bob", "Bob B", "tenant_admin", &bob) == SF_OK);
    CHECK("create_login_carol",
          sf_store_create_login(s, ta.id, "carol", "Carol C", "tenant_user", &carol) == SF_OK);
    CHECK("create_login_dave",
          sf_store_create_login(s, ta.id, "dave", "Dave D", "tenant_user", &dave) == SF_OK);
    CHECK("create_login_dup_conflict",
          sf_store_create_login(s, ta.id, "alice", "Dup", "tenant_user", &tmp_login) == SF_ERR_CONFLICT);

    // ---- cross-tenant store scoping -------------------------------------
    CHECK("cross_tenant_get_login_not_found",
          sf_store_get_login(s, ta.id, bob.id, &tmp_login) == SF_ERR_NOT_FOUND);
    CHECK("cross_tenant_get_login_reverse",
          sf_store_get_login(s, tb.id, alice.id, &tmp_login) == SF_ERR_NOT_FOUND);

    // ---- passwords: set + verify -----------------------------------------
    CHECK("set_password_alice",
          sf_auth_set_password(s, ta.id, alice.id, PW_ALICE_1) == SF_OK);
    CHECK("set_password_cross_tenant_not_found",
          sf_auth_set_password(s, tb.id, alice.id, PW_ALICE_1) == SF_ERR_NOT_FOUND);
    CHECK("set_password_carol",
          sf_auth_set_password(s, ta.id, carol.id, PW_CAROL) == SF_OK);
    CHECK("set_password_bob",
          sf_auth_set_password(s, tb.id, bob.id, PW_BOB) == SF_OK);
    CHECK("set_password_dave",
          sf_auth_set_password(s, ta.id, dave.id, PW_DAVE) == SF_OK);

    CHECK("verify_right",
          sf_auth_verify_password(s, "alpha", "alice", PW_ALICE_1, "127.0.0.1",
                                  &tmp_login, &tmp_tenant) == SF_OK &&
          tmp_login.id == alice.id && tmp_login.last_login_at[0] != '\0');
    CHECK("verify_wrong_is_auth",
          sf_auth_verify_password(s, "alpha", "alice", PW_WRONG, "127.0.0.1",
                                  NULL, NULL) == SF_ERR_AUTH);
    CHECK("verify_unknown_user_is_auth",
          sf_auth_verify_password(s, "alpha", "nosuch", PW_ALICE_1, "127.0.0.1",
                                  NULL, NULL) == SF_ERR_AUTH);
    CHECK("verify_unknown_tenant_is_auth",
          sf_auth_verify_password(s, "nosuchtenant", "alice", PW_ALICE_1, "127.0.0.1",
                                  NULL, NULL) == SF_ERR_AUTH);

    // ---- tokens: issue / resolve / operator hook --------------------------
    CHECK("issue_session_token",
          sf_auth_issue_token(s, ta.id, alice.id, "session", "test", 0,
                              tok, sizeof tok, &tok_id, exp) == SF_OK &&
          tok[0] != '\0' && tok_id > 0 && exp[0] != '\0');
    CHECK("resolve_session_token",
          sf_auth_resolve_token(s, tok, &caller) == SF_OK &&
          caller.is_operator == 0 && caller.tenant_id == ta.id &&
          caller.login_id == alice.id && caller.token_id == tok_id &&
          strcmp(caller.role, "tenant_admin") == 0 &&
          strcmp(caller.username, "alice") == 0 &&
          strcmp(caller.tenant_slug, "alpha") == 0);
    CHECK("resolve_garbage_token_is_auth",
          sf_auth_resolve_token(s, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", &caller) == SF_ERR_AUTH);

    CHECK("resolve_operator_token",
          sf_auth_resolve_token(s, op_token, &op_caller) == SF_OK &&
          op_caller.is_operator == 1 && op_caller.tenant_id == -1 &&
          strcmp(op_caller.role, "operator") == 0);
    CHECK("operator_auth_hook_fires_once",
          sf_auth_note_operator_authenticated() == 1 &&
          sf_auth_note_operator_authenticated() == 0);

    // List: no digests in the struct by construction; ids/labels present.
    CHECK("list_tokens",
          sf_auth_list_tokens(s, ta.id, alice.id, &tinfos, &tinf_count) == SF_OK &&
          tinf_count >= 1 && tinfos[0].id == tok_id);
    sf_token_info_free_all(tinfos, tinf_count); tinfos = NULL;

    // Revoke scope: bob (another login) cannot revoke alice's token.
    bob_caller.is_operator = 0;
    bob_caller.tenant_id = tb.id;
    bob_caller.login_id = bob.id;
    bob_caller.token_id = 0;
    memset(bob_caller.role, 0, sizeof bob_caller.role);
    strcpy(bob_caller.role, "tenant_admin");
    memset(bob_caller.username, 0, sizeof bob_caller.username);
    strcpy(bob_caller.username, "bob");
    CHECK("revoke_other_logins_token_forbidden",
          sf_auth_revoke_token(s, &bob_caller, tok_id) == SF_ERR_FORBIDDEN);
    CHECK("token_still_valid_after_forbidden_revoke",
          sf_auth_resolve_token(s, tok, &caller) == SF_OK);
    CHECK("revoke_own_token_ok",
          sf_auth_revoke_token(s, &caller, tok_id) == SF_OK);
    CHECK("resolve_revoked_is_auth",
          sf_auth_resolve_token(s, tok, &caller) == SF_ERR_AUTH);

    // Expiry: issue with a short TTL, then force the stored expiry into
    // the past via the raw handle (schema-test seam) and re-resolve.
    CHECK("issue_short_ttl_token",
          sf_auth_issue_token(s, ta.id, alice.id, "api", "short", 3600,
                              tok2, sizeof tok2, &tok2_id, exp) == SF_OK);
    CHECK("resolve_before_expiry",
          sf_auth_resolve_token(s, tok2, &caller) == SF_OK);
    {
        sqlite3 *db = sf_store_db(s);
        sqlite3_stmt *st = NULL;
        int urc = sqlite3_prepare_v2(db,
            "UPDATE cs_tokens SET expires_at = '2000-01-01T00:00:00Z' WHERE id = ?",
            -1, &st, NULL);
        if (urc == SQLITE_OK) {
            sqlite3_bind_int64(st, 1, tok2_id);
            sqlite3_step(st);
        }
        if (st) sqlite3_finalize(st);
        CHECK("force_expiry_update", urc == SQLITE_OK);
    }
    CHECK("resolve_expired_is_auth",
          sf_auth_resolve_token(s, tok2, &caller) == SF_ERR_AUTH);

    // revoke_presented (logout path)
    CHECK("issue_token_for_presented_revoke",
          sf_auth_issue_token(s, ta.id, alice.id, "session", "", 0,
                              tok3, sizeof tok3, NULL, exp) == SF_OK);
    CHECK("revoke_presented_ok",
          sf_auth_revoke_presented(s, tok3) == SF_OK);
    CHECK("resolve_after_presented_revoke_is_auth",
          sf_auth_resolve_token(s, tok3, &caller) == SF_ERR_AUTH);

    // ---- lockout: 5 failures, correct password refused while locked -------
    ok = 1;
    for (i = 0; i < SF_LOCK_THRESHOLD; i++) {
        if (sf_auth_verify_password(s, "alpha", "carol", PW_WRONG, "127.0.0.1",
                                    NULL, NULL) != SF_ERR_AUTH) ok = 0;
    }
    CHECK("lockout_five_failures_all_auth", ok);
    CHECK("lockout_correct_password_refused",
          sf_auth_verify_password(s, "alpha", "carol", PW_CAROL, "127.0.0.1",
                                  NULL, NULL) == SF_ERR_LOCKED);
    CHECK("login_reports_locked",
          sf_store_get_login(s, ta.id, carol.id, &tmp_login) == SF_OK &&
          tmp_login.locked == 1);
    // set_password clears the lockout.
    CHECK("set_password_clears_lockout",
          sf_auth_set_password(s, ta.id, carol.id, PW_CAROL) == SF_OK &&
          sf_auth_verify_password(s, "alpha", "carol", PW_CAROL, "127.0.0.1",
                                  NULL, NULL) == SF_OK);

    // ---- disabled login / suspended tenant ---------------------------------
    CHECK("disable_login",
          sf_store_update_login(s, ta.id, dave.id, NULL, NULL, "disabled") == SF_OK);
    CHECK("verify_disabled_is_tenant_state",
          sf_auth_verify_password(s, "alpha", "dave", PW_DAVE, "127.0.0.1",
                                  NULL, NULL) == SF_ERR_TENANT_STATE);
    CHECK("suspend_tenant",
          sf_store_update_tenant(s, tb.id, NULL, "suspended", NULL) == SF_OK);
    CHECK("verify_suspended_is_tenant_state",
          sf_auth_verify_password(s, "beta", "bob", PW_BOB, "127.0.0.1",
                                  NULL, NULL) == SF_ERR_TENANT_STATE);
    CHECK("reactivate_tenant",
          sf_store_update_tenant(s, tb.id, NULL, "active", NULL) == SF_OK &&
          sf_auth_verify_password(s, "beta", "bob", PW_BOB, "127.0.0.1",
                                  NULL, NULL) == SF_OK);

    // ---- password reset: issue / complete / replay --------------------------
    // A live session issued before the reset must die at completion.
    CHECK("issue_session_before_reset",
          sf_auth_issue_token(s, ta.id, alice.id, "session", "pre-reset", 0,
                              tok, sizeof tok, &tok_id, exp) == SF_OK);
    CHECK("issue_reset",
          sf_auth_issue_reset(s, ta.id, alice.id, "admin:alice", "127.0.0.1",
                              reset_tok, sizeof reset_tok) == SF_OK &&
          reset_tok[0] != '\0');
    CHECK("issue_reset_second_invalidates_first",
          sf_auth_issue_reset(s, ta.id, alice.id, "admin:alice", "127.0.0.1",
                              reset_tok2, sizeof reset_tok2) == SF_OK);
    CHECK("complete_with_invalidated_token_is_auth",
          sf_auth_complete_reset(s, reset_tok, PW_ALICE_2, "127.0.0.1") == SF_ERR_AUTH);
    CHECK("complete_with_garbage_token_is_auth",
          sf_auth_complete_reset(s, "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                                 PW_ALICE_2, "127.0.0.1") == SF_ERR_AUTH);
    CHECK("complete_reset_ok",
          sf_auth_complete_reset(s, reset_tok2, PW_ALICE_2, "127.0.0.1") == SF_OK);
    CHECK("reset_replay_refused",
          sf_auth_complete_reset(s, reset_tok2, PW_ALICE_2, "127.0.0.1") == SF_ERR_AUTH);
    CHECK("verify_new_password_after_reset",
          sf_auth_verify_password(s, "alpha", "alice", PW_ALICE_2, "127.0.0.1",
                                  NULL, NULL) == SF_OK);
    CHECK("verify_old_password_after_reset_is_auth",
          sf_auth_verify_password(s, "alpha", "alice", PW_ALICE_1, "127.0.0.1",
                                  NULL, NULL) == SF_ERR_AUTH);
    CHECK("session_revoked_by_reset_completion",
          sf_auth_resolve_token(s, tok, &caller) == SF_ERR_AUTH);

    // ---- buckets + objects: counters exact under insert/replace/delete -----
    CHECK("create_backend2_for_bucket",
          sf_store_create_backend(s, "fs2", "filesystem", "{}", "", &be) == SF_OK);
    CHECK("create_bucket",
          sf_store_create_bucket(s, ta.id, "docs", be.id, -1, &bucket) == SF_OK &&
          bucket.object_count == 0 && bucket.total_bytes == 0);
    {
        int64_t be_id = be.id;
        sf_backend_free(&be);
        CHECK("cross_tenant_get_bucket_not_found",
              sf_store_get_bucket_by_id(s, tb.id, bucket.id, &got_bucket) == SF_ERR_NOT_FOUND);
        CHECK("cross_tenant_get_bucket_by_name_not_found",
              sf_store_get_bucket_by_name(s, tb.id, "docs", &got_bucket) == SF_ERR_NOT_FOUND);
        (void)be_id;
    }
    memset(hash, 0xAB, sizeof hash);
    CHECK("put_object_insert",
          sf_store_put_object(s, ta.id, bucket.id, "a.txt", 100, hash,
                              "text/plain", "{}", &obj) == SF_OK && obj.id > 0);
    sf_object_free(&obj);
    CHECK("counters_after_insert",
          sf_store_get_bucket_by_id(s, ta.id, bucket.id, &got_bucket) == SF_OK &&
          got_bucket.object_count == 1 && got_bucket.total_bytes == 100);
    CHECK("put_object_replace",
          sf_store_put_object(s, ta.id, bucket.id, "a.txt", 250, hash,
                              "text/plain", "{}", &obj) == SF_OK);
    sf_object_free(&obj);
    CHECK("counters_after_replace",
          sf_store_get_bucket_by_id(s, ta.id, bucket.id, &got_bucket) == SF_OK &&
          got_bucket.object_count == 1 && got_bucket.total_bytes == 250);
    CHECK("put_object_second",
          sf_store_put_object(s, ta.id, bucket.id, "b.txt", 50, hash,
                              "text/plain", NULL, &obj) == SF_OK);
    sf_object_free(&obj);
    CHECK("counters_after_second_insert",
          sf_store_get_bucket_by_id(s, ta.id, bucket.id, &got_bucket) == SF_OK &&
          got_bucket.object_count == 2 && got_bucket.total_bytes == 300);
    CHECK("get_object_cross_tenant_not_found",
          sf_store_get_object(s, tb.id, bucket.id, "a.txt", &obj) == SF_ERR_NOT_FOUND);
    CHECK("delete_object",
          sf_store_delete_object(s, ta.id, bucket.id, "a.txt") == SF_OK);
    CHECK("counters_after_delete",
          sf_store_get_bucket_by_id(s, ta.id, bucket.id, &got_bucket) == SF_OK &&
          got_bucket.object_count == 1 && got_bucket.total_bytes == 50);
    CHECK("delete_missing_object_not_found",
          sf_store_delete_object(s, ta.id, bucket.id, "a.txt") == SF_ERR_NOT_FOUND);
    CHECK("tenant_usage_matches_counters",
          sf_store_tenant_usage(s, ta.id, &ub, &uo, &ubc) == SF_OK &&
          ub == 50 && uo == 1 && ubc == 1);

    // ---- audit rows -----------------------------------------------------------
    CHECK("audit_write",
          sf_store_audit(s, ta.id, "login", "alice", "test.probe", "bucket:docs",
                         "ok", "{\"n\":1}", "127.0.0.1") == SF_OK);
    CHECK("audit_list_scoped_finds_rows",
          sf_store_list_audit(s, ta.id, "test.probe", 0, 10,
                              &audit_rows, &audit_count) == SF_OK &&
          audit_count == 1 && strcmp(audit_rows[0].action, "test.probe") == 0);
    sf_audit_free_all(audit_rows, audit_count); audit_rows = NULL;
    CHECK("audit_auth_rows_written",
          sf_store_list_audit(s, ta.id, "auth.login", 0, 0,
                              &audit_rows, &audit_count) == SF_OK &&
          audit_count >= 3);
    sf_audit_free_all(audit_rows, audit_count); audit_rows = NULL;
    CHECK("audit_cross_tenant_empty",
          sf_store_list_audit(s, tb.id, "test.probe", 0, 10,
                              &audit_rows, &audit_count) == SF_OK &&
          audit_count == 0);
    sf_audit_free_all(audit_rows, audit_count); audit_rows = NULL;

    // ---- rate limiting (fixed window; unique keys isolate this case) ---------
    {
        int ra = 0, allowed = 0;
        for (i = 0; i < 10; i++)
            if (sf_rate_allow_login("203.0.113.9", "rltenant", "rluser", &ra)) allowed++;
        CHECK("rate_login_allows_10_per_user", allowed == 10);
        CHECK("rate_login_11th_limited_with_retry_after",
              sf_rate_allow_login("203.0.113.9", "rltenant", "rluser", &ra) == 0 &&
              ra >= 1 && ra <= 60);
    }
    {
        int ra = 0, allowed = 0;
        for (i = 0; i < 600; i++)
            if (sf_rate_allow_api(987654321LL, &ra)) allowed++;
        CHECK("rate_api_allows_600", allowed == 600);
        CHECK("rate_api_601st_limited",
              sf_rate_allow_api(987654321LL, &ra) == 0 && ra >= 1 && ra <= 60);
    }

    sf_store_close(s);
    remove(DB_PATH);
    printf("VERDICT %s (%d passed, %d failed)\n",
           g_fail == 0 ? "PASS" : "FAIL", g_pass, g_fail);
    return g_fail == 0 ? 0 : 1;
}
