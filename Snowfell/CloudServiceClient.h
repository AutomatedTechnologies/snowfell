// CloudServiceClient — the REST client for the SnowfellStorageService
// API (SF-T12f; cloud storage design record 03, §8 routes, §9 app
// integration).
//
// THE THIRD SANCTIONED NSURLSession FILE — a deliberate exception,
// named here as §9 names it. The app's other two are
// GitHubProjectsClient (SF-T4; inert, flag-locked, the GitHub write
// path) and SnapshotSync (SF-T6; read-only public GET of the published
// snapshot). This one exists because the V12 Storage lens is BY DESIGN
// a pure REST client of the service it administers (dogfooding, §0:
// the console holds no second, privileged path to the data — no SQL,
// never opens cloud.db). A third file is the cost of that doctrine,
// taken deliberately, not by drift.
//
// LOOPBACK ONLY — the hard rule. The base URL is built in exactly one
// place (+baseURL) and is literally http://127.0.0.1:<port>, the port
// from NSUserDefaults key SnowfellCloudPort (default 8471, the §2.1
// service default). No method accepts a host, a scheme, or a full URL;
// every request URL is assembled from the loopback base + a path this
// class composes, and the assembled URL's host is re-verified as
// 127.0.0.1 before the task resumes — any code path that could produce
// a non-loopback host is a defect, and this class refuses it in code
// (CloudServiceClientErrorNonLoopbackRefused), mirroring §9.
//
// OPERATOR TOKEN CUSTODY (D4 discipline, §5.5). The operator token is
// a macOS Keychain generic-password item, service
// "com.detroitautomationacademy.snowfell.cloud-operator", account
// "operator". It is read (SecItemCopyMatching) at CALL TIME, inside
// the single request builder, used to set that request's Authorization
// header, and released when the builder returns. It is kept in NO
// property or ivar, never written to a file or database, never logged.
// +hasOperatorToken is an attributes-only probe (the secret bytes never
// materialize). -saveOperatorToken:error: is the one write path: the
// Storage lens's pairing pane hands it the token the owner pasted once
// (§5.5 bootstrap) and it lands via SecItemAdd / SecItemUpdate.
//
// ERRORS. Every failure surfaces as NSError in this client's own
// domain. An API error envelope (§8: {"error": {"code", "message",
// "detail"}}) completes with CloudServiceClientErrorAPI and the API's
// snake_case code preserved verbatim in userInfo under
// CloudServiceErrorCodeKey (figures in "detail" ride along under
// CloudServiceErrorDetailKey) — envelope≠payload: the service's codes
// and numbers reach the UI uncompressed. HTTP status rides under
// CloudServiceHTTPStatusKey where one exists.
//
// PAGINATION, stated: list calls request ?limit=200 (the §8 maximum)
// — console scale, one page. Following meta.next_cursor is a seam,
// not silently half-done: a list longer than 200 rows is a service
// state this console does not yet page through, and the lens's counts
// make a full page visible as a full page.
//
// OPERATOR TENANT SCOPING, stated: bucket/object routes in §8 are
// credential-scoped (a login sees its own tenant). The operator's
// console scope follows the §8 audit route's own convention — the
// ?tenant=<id> query parameter the service honors for operator
// callers (audit: ?tenant= is in §8 verbatim). Login-scoped callers
// never arise here: this client only ever presents the operator token.
//
// SF-T12j adds the §13.7 CMS surface (collections, content, versions,
// rollback, state), the §13.6 dedup block accessor, and the §13.3 GC
// sweep — built to the design contract; downloads and blob upload
// are deliberately NOT calls here (see the CMS section note below).
#import <Foundation/Foundation.h>

@class CloudTenant;
@class CloudLogin;
@class CloudBucket;
@class CloudObject;
@class CloudAuditEntry;
@class CloudCollection;
@class CloudContentItem;
@class CloudContentVersion;
@class CloudServiceHealth;

NS_ASSUME_NONNULL_BEGIN

extern NSString * const CloudServiceClientErrorDomain;
extern NSString * const CloudServicePortDefaultsKey;        // @"SnowfellCloudPort"
extern NSString * const CloudOperatorKeychainService;       // @"com.detroitautomationacademy.snowfell.cloud-operator"
extern NSString * const CloudOperatorKeychainAccount;       // @"operator"
extern NSString * const CloudServiceErrorCodeKey;           // userInfo: the §8 API error code
extern NSString * const CloudServiceErrorDetailKey;         // userInfo: the §8 error detail figures
extern NSString * const CloudServiceHTTPStatusKey;          // userInfo: NSNumber HTTP status

typedef NS_ENUM(NSInteger, CloudServiceClientError) {
    CloudServiceClientErrorTransport = 1,
    CloudServiceClientErrorHTTP = 2,
    CloudServiceClientErrorAPI = 3,                  // §8 error envelope; code in userInfo
    CloudServiceClientErrorMalformedResponse = 4,
    CloudServiceClientErrorNotConfigured = 5,        // no operator token in the Keychain
    CloudServiceClientErrorKeychainFailed = 6,
    CloudServiceClientErrorNonLoopbackRefused = 7,   // the loopback hard rule, enforced
    CloudServiceClientErrorInvalidArgument = 8,
};

@interface CloudServiceClient : NSObject

// The configured port: NSUserDefaults SnowfellCloudPort, default 8471.
// Out-of-range stored values fall back to the default — a corrupt
// preference can never widen the base URL into something else.
+ (NSInteger)configuredPort;

// THE base URL — the only URL origin in this class:
// http://127.0.0.1:<configuredPort>. Never any other host or scheme.
+ (NSURL *)baseURL;

// Attributes-only Keychain probe: is an operator token stored? The
// secret bytes never materialize for this check (§5.5 pairing state).
+ (BOOL)hasOperatorToken;

// The pairing write (§5.5): stores the token as the Keychain item
// (service CloudOperatorKeychainService, account "operator") via
// SecItemAdd, or SecItemUpdate when the item already exists. Returns
// NO + error on failure. The token is not retained by this class.
- (BOOL)saveOperatorToken:(NSString *)token error:(NSError **)error;

#pragma mark - Health (§8: public)

// GET /v1/health — no auth. The lens's service state line is built
// from this and nothing else (a stopped service is this call failing).
- (void)fetchHealthWithCompletion:(void (^)(CloudServiceHealth * _Nullable health,
                                            NSError * _Nullable error))completion;

#pragma mark - Tenants (operator)

- (void)fetchTenantsWithCompletion:(void (^)(NSArray<CloudTenant *> * _Nullable tenants,
                                             NSError * _Nullable error))completion;

- (void)fetchTenantWithID:(int64_t)tenantID
               completion:(void (^)(CloudTenant * _Nullable tenant,
                                    NSError * _Nullable error))completion;

// POST /v1/tenants {slug, display_name}. 409 conflict surfaces as an
// API error with code "conflict" in userInfo.
- (void)createTenantWithSlug:(NSString *)slug
                 displayName:(NSString *)displayName
                  completion:(void (^)(CloudTenant * _Nullable tenant,
                                       NSError * _Nullable error))completion;

// PATCH /v1/tenants/{tid} — fields is the JSON-ready patch dictionary
// (display_name / state / contact_note keys, §4). DELETE is tenant
// CLOSE (§8: state transition, never a hard delete with data).
- (void)patchTenantWithID:(int64_t)tenantID
                   fields:(NSDictionary *)fields
               completion:(void (^)(CloudTenant * _Nullable tenant,
                                    NSError * _Nullable error))completion;

- (void)closeTenantWithID:(int64_t)tenantID
               completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

// GET /v1/tenants/{tid}/usage — quota vs used, per bucket (§8). No
// model class: the payload is returned as the decoded data dictionary
// verbatim (figures uncompressed) for the lens to render.
- (void)fetchUsageForTenantID:(int64_t)tenantID
                   completion:(void (^)(NSDictionary * _Nullable usage,
                                        NSError * _Nullable error))completion;

#pragma mark - Logins (operator for any tenant; §5.2 CRUD)

- (void)fetchLoginsForTenantID:(int64_t)tenantID
                    completion:(void (^)(NSArray<CloudLogin *> * _Nullable logins,
                                         NSError * _Nullable error))completion;

// POST /v1/tenants/{tid}/logins — the initial password is set in the
// same call (§5.2), hashed by the service immediately, never echoed.
- (void)createLoginForTenantID:(int64_t)tenantID
                      username:(NSString *)username
                   displayName:(NSString *)displayName
                          role:(NSString *)role
                      password:(NSString *)password
                    completion:(void (^)(CloudLogin * _Nullable login,
                                         NSError * _Nullable error))completion;

// PATCH …/logins/{lid} — display_name / role / state (§5.2; username
// is immutable). Disabling revokes the login's sessions server-side.
- (void)patchLoginForTenantID:(int64_t)tenantID
                      loginID:(int64_t)loginID
                       fields:(NSDictionary *)fields
                   completion:(void (^)(CloudLogin * _Nullable login,
                                        NSError * _Nullable error))completion;

// DELETE …/logins/{lid} — hard delete (§5.2); the service refuses
// (409) for the tenant's last active admin.
- (void)deleteLoginForTenantID:(int64_t)tenantID
                       loginID:(int64_t)loginID
                    completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

// POST …/logins/{lid}/password {new_password} — admin set (§5.2):
// audited server-side as login.password_set_by_admin and revokes the
// login's existing sessions.
- (void)setPasswordForTenantID:(int64_t)tenantID
                       loginID:(int64_t)loginID
                   newPassword:(NSString *)newPassword
                    completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

// POST …/logins/{lid}/password-resets — issues a reset token (§5.4).
// The plaintext token is returned ONCE, in this completion; the admin
// delivers it out of band. It is never stored by this class.
- (void)issuePasswordResetForTenantID:(int64_t)tenantID
                              loginID:(int64_t)loginID
                           completion:(void (^)(NSString * _Nullable resetToken,
                                                NSError * _Nullable error))completion;

#pragma mark - Backends (operator)

// GET /v1/backends — registration rows as decoded dictionaries
// verbatim (id / name / kind / state / secret_ref — a NAME, never a
// value, §4). The lens needs names + ids for the bucket-create picker.
- (void)fetchBackendsWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable backends,
                                              NSError * _Nullable error))completion;

#pragma mark - Buckets & objects (operator scope via ?tenant=, see header)

- (void)fetchBucketsForTenantID:(int64_t)tenantID
                     completion:(void (^)(NSArray<CloudBucket *> * _Nullable buckets,
                                          NSError * _Nullable error))completion;

// POST /v1/buckets {name, backend_id?} — backendID <= 0 omits the key
// (the service binds its default: first active backend, §8).
- (void)createBucketForTenantID:(int64_t)tenantID
                           name:(NSString *)name
                      backendID:(int64_t)backendID
                     completion:(void (^)(CloudBucket * _Nullable bucket,
                                          NSError * _Nullable error))completion;

// DELETE /v1/buckets/{name} — the service refuses (409) a non-empty
// bucket (§8).
- (void)deleteBucketForTenantID:(int64_t)tenantID
                           name:(NSString *)name
                     completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

// GET /v1/buckets/{name}/objects — metadata rows only (§8 list route);
// object BYTES are never fetched by this console.
- (void)fetchObjectsForTenantID:(int64_t)tenantID
                     bucketName:(NSString *)bucketName
                     completion:(void (^)(NSArray<CloudObject *> * _Nullable objects,
                                          NSError * _Nullable error))completion;

- (void)deleteObjectForTenantID:(int64_t)tenantID
                     bucketName:(NSString *)bucketName
                            key:(NSString *)key
                     completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

#pragma mark - Audit (operator; §8 ?tenant= scope)

// GET /v1/audit?tenant={tid}&limit=100 — the tenant's audit tail,
// id-ordered as served. tenantID <= 0 omits the scope (all tenants).
- (void)fetchAuditForTenantID:(int64_t)tenantID
                   completion:(void (^)(NSArray<CloudAuditEntry *> * _Nullable entries,
                                        NSError * _Nullable error))completion;

#pragma mark - CMS: collections, content, versions (§13.7; SF-T12j)

// The §13.5 content model over the same loopback + Keychain-token
// discipline as every call above — no new transport, no new custody.
// Collection/content routes are credential-scoped in §13.7 ("any
// login (own tenant)"), so the operator's scope rides the same
// ?tenant=<id> convention as the bucket/object routes (see header).
//
// WHAT IS DELIBERATELY NOT HERE, stated:
// - Downloads (GET /v1/content/{id}/download and the per-version
//   form) are NOT client calls: the lens v1 handles no file bytes —
//   it manages structure and references, exactly as it lists object
//   metadata without fetching object bytes (§8 list discipline).
// - Blob upload (POST /v1/blobs) is NOT a lens call either: payload
//   bytes enter through the API's own callers; the lens creates
//   content and versions by REFERENCING an already-uploaded blob id
//   (§13.7 create/version bodies carry blob_id, never bytes).

- (void)fetchCollectionsForTenantID:(int64_t)tenantID
                         completion:(void (^)(NSArray<CloudCollection *> * _Nullable collections,
                                              NSError * _Nullable error))completion;

// POST /v1/collections {name, slug, parent_id?} — parentID <= 0 omits
// the key (a root collection). A duplicate slug in the tenant is 409.
- (void)createCollectionForTenantID:(int64_t)tenantID
                               name:(NSString *)name
                               slug:(NSString *)slug
                           parentID:(int64_t)parentID
                         completion:(void (^)(CloudCollection * _Nullable collection,
                                              NSError * _Nullable error))completion;

// DELETE /v1/collections/{id} — the service refuses (409) while items
// or child collections remain (§13.7).
- (void)deleteCollectionForTenantID:(int64_t)tenantID
                       collectionID:(int64_t)collectionID
                         completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

// GET /v1/content — the tenant's items with their current-version
// summaries. Filters ride as query parameters when set: collectionID
// > 0 → collection_id, non-empty kind/state → kind/state. A non-empty
// query switches the path to GET /v1/search/content, the §13.5 route
// that defines q (substring over title, slug, metadata text) alongside
// the same filters.
- (void)fetchContentForTenantID:(int64_t)tenantID
                   collectionID:(int64_t)collectionID
                           kind:(nullable NSString *)kind
                          state:(nullable NSString *)state
                          query:(nullable NSString *)query
                     completion:(void (^)(NSArray<CloudContentItem *> * _Nullable items,
                                          NSError * _Nullable error))completion;

// GET /v1/content/{id} — one item + its current version summary.
- (void)fetchContentItemForTenantID:(int64_t)tenantID
                          contentID:(int64_t)contentID
                         completion:(void (^)(CloudContentItem * _Nullable item,
                                              NSError * _Nullable error))completion;

// POST /v1/content {slug, title, kind, collection_id?, blob_id} —
// item + version 1 in one transaction (§13.7). The blob must already
// exist in the tenant's scope (uploaded via the API, never via this
// lens — see the section note above).
- (void)createContentForTenantID:(int64_t)tenantID
                            slug:(NSString *)slug
                           title:(NSString *)title
                            kind:(NSString *)kind
                    collectionID:(int64_t)collectionID
                          blobID:(int64_t)blobID
                      completion:(void (^)(CloudContentItem * _Nullable item,
                                           NSError * _Nullable error))completion;

// PATCH /v1/content/{id} — field edits only (title / collection_id /
// kind / metadata keys, §13.5): they never create a version.
- (void)patchContentForTenantID:(int64_t)tenantID
                      contentID:(int64_t)contentID
                         fields:(NSDictionary *)fields
                     completion:(void (^)(CloudContentItem * _Nullable item,
                                          NSError * _Nullable error))completion;

// DELETE /v1/content/{id} — deletes the item and its versions and
// drops their blob references (refcount/GC rules apply, §13.5).
- (void)deleteContentForTenantID:(int64_t)tenantID
                       contentID:(int64_t)contentID
                      completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

// GET /v1/content/{id}/versions — full history, newest first (§13.7).
- (void)fetchVersionsForTenantID:(int64_t)tenantID
                       contentID:(int64_t)contentID
                      completion:(void (^)(NSArray<CloudContentVersion *> * _Nullable versions,
                                           NSError * _Nullable error))completion;

// POST /v1/content/{id}/versions {blob_id, note?} — appends the next
// version referencing an already-uploaded blob (§13.5: payload
// changes always create versions; history is append-only).
- (void)createVersionForTenantID:(int64_t)tenantID
                       contentID:(int64_t)contentID
                          blobID:(int64_t)blobID
                            note:(nullable NSString *)note
                      completion:(void (^)(CloudContentVersion * _Nullable version,
                                           NSError * _Nullable error))completion;

// POST /v1/content/{id}/rollback {version_no} — creates a NEW version
// whose blob is the target version's (dedup makes it free, §13.5);
// history records the rollback, it is never rewritten. Completes
// with the new version row.
- (void)rollbackContentForTenantID:(int64_t)tenantID
                         contentID:(int64_t)contentID
                       toVersionNo:(int64_t)versionNo
                        completion:(void (^)(CloudContentVersion * _Nullable version,
                                             NSError * _Nullable error))completion;

// POST /v1/content/{id}/state {state} — draft | published | archived,
// through the state route so the transition audits distinctly (§13.5).
- (void)setStateForContentForTenantID:(int64_t)tenantID
                            contentID:(int64_t)contentID
                                state:(NSString *)state
                           completion:(void (^)(CloudContentItem * _Nullable item,
                                                NSError * _Nullable error))completion;

#pragma mark - Dedup accounting + GC (§13.6 / §13.3; SF-T12j)

// The dedup block of GET /v1/tenants/{tid}/usage (§13.6), returned as
// the decoded dictionary verbatim — same discipline as usage itself:
// logical_bytes / physical_bytes / bytes_saved / dedup_ratio /
// blob_count / reference_count, figures uncompressed.
- (void)fetchDedupForTenantID:(int64_t)tenantID
                   completion:(void (^)(NSDictionary * _Nullable dedup,
                                        NSError * _Nullable error))completion;

// POST /v1/admin/gc {tenant_id, dry_run} — the operator GC sweep
// scoped to the named tenant (§13.3: /v1/gc is the tenant_admin
// session route and refuses operator callers; /v1/admin/gc is the
// operator route, any scope). The sweep recomputes refcounts and
// reclaims blobs orphaned past the grace period; the response is
// aggregates only — {scanned, orphans, deleted, bytes_reclaimed,
// dry_run} — returned verbatim (§13.8).
- (void)runGCForTenantID:(int64_t)tenantID
                  dryRun:(BOOL)dryRun
              completion:(void (^)(NSDictionary * _Nullable result,
                                   NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
