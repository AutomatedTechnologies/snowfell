// CloudModels — the V12 Storage lens value objects (SF-T12f; cloud
// storage design record 03, §9): one class per resource the
// SnowfellStorageService REST API (§8) returns — tenant, login,
// bucket, object, audit entry, and the health payload. SF-T12j adds
// the §13.5 CMS resources the lens's Content section renders —
// collection, content item, content version. Estate model
// pattern, same as IncidentModels / SFAction / DeployTarget: copy
// properties, no logic beyond the +fromJSONDictionary: factory that
// maps the API's snake_case keys onto the properties. No SQL, no
// network, no credential material of any kind exists in these types —
// login rows carry state and lock facts only, exactly as §5.2's read
// responses do (never credential material).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CloudTenant : NSObject

@property (nonatomic, assign) int64_t tenantID;          // cs_tenants.id
@property (nonatomic, copy) NSString *slug;              // unique, URL-safe handle
@property (nonatomic, copy) NSString *displayName;       // display_name
@property (nonatomic, copy) NSString *state;             // active | suspended | closed (data)
// Quota policy (§7.4): -1 = service default applies.
@property (nonatomic, assign) int64_t quotaBytes;        // quota_bytes
@property (nonatomic, assign) int64_t quotaObjects;      // quota_objects
@property (nonatomic, assign) int64_t quotaBuckets;      // quota_buckets
// Usage figures (the /usage SUM over buckets, §7.4): 0 when the
// payload that produced this object carried none (list/get rows).
@property (nonatomic, assign) int64_t usedBytes;         // used_bytes
@property (nonatomic, assign) int64_t usedObjects;       // used_objects
@property (nonatomic, assign) int64_t bucketCount;       // bucket_count

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary;

@end

@interface CloudLogin : NSObject

@property (nonatomic, assign) int64_t loginID;           // cs_logins.id
@property (nonatomic, assign) int64_t tenantID;          // cs_logins.tenant_id
@property (nonatomic, copy) NSString *username;          // unique per tenant
@property (nonatomic, copy) NSString *displayName;       // display_name
@property (nonatomic, copy) NSString *role;              // tenant_admin | tenant_user (data)
@property (nonatomic, copy) NSString *state;             // active | disabled (data)
@property (nonatomic, assign) BOOL locked;               // a §5.3 lock is in force now
@property (nonatomic, copy, nullable) NSString *lastLoginAt;  // last_login_at, ISO 8601 UTC

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary;

@end

@interface CloudBucket : NSObject

@property (nonatomic, assign) int64_t bucketID;          // cs_buckets.id
@property (nonatomic, assign) int64_t tenantID;          // cs_buckets.tenant_id
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) int64_t backendID;         // cs_buckets.backend_id
@property (nonatomic, assign) int64_t objectCount;       // maintained transactionally (§7.4)
@property (nonatomic, assign) int64_t totalBytes;        // total_bytes
@property (nonatomic, assign) int64_t quotaBytes;        // per-bucket cap; -1 = none

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary;

@end

@interface CloudObject : NSObject

@property (nonatomic, assign) int64_t objectID;          // cs_objects.id
@property (nonatomic, copy) NSString *key;               // logical key (§7.2 grammar)
@property (nonatomic, assign) int64_t sizeBytes;         // size_bytes
@property (nonatomic, copy, nullable) NSString *sha256Hex;    // sha256, hex text
@property (nonatomic, copy, nullable) NSString *contentType;  // content_type

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary;

@end

@interface CloudAuditEntry : NSObject

@property (nonatomic, assign) int64_t auditID;           // cs_audit_log.id
@property (nonatomic, copy) NSString *ts;                // ISO 8601 UTC
@property (nonatomic, copy) NSString *actorRef;          // actor_ref (operator | login ref)
@property (nonatomic, copy) NSString *action;            // e.g. "object.put"
@property (nonatomic, copy, nullable) NSString *objectRef;    // object_ref
@property (nonatomic, copy) NSString *result;            // ok | denied | error (data)

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary;

@end

@interface CloudCollection : NSObject

@property (nonatomic, assign) int64_t collectionID;      // cs_collections.id
@property (nonatomic, assign) int64_t parentID;          // parent_id; 0 = root (NULL in the store)
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *slug;              // unique per tenant (§13.5)

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary;

@end

@interface CloudContentItem : NSObject

@property (nonatomic, assign) int64_t contentID;         // cs_content_items.id
@property (nonatomic, copy) NSString *slug;              // unique per tenant (§13.5)
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *kind;              // tenant-facing label (data, §13.5)
@property (nonatomic, copy) NSString *state;             // draft | published | archived (data)
@property (nonatomic, assign) int64_t collectionID;      // collection_id; 0 = root (NULL)
// Current-version summary (§13.7 GET item: item + current version):
@property (nonatomic, assign) int64_t currentVersionNo;  // current_version_no
@property (nonatomic, copy, nullable) NSString *currentSha256Hex;  // current version's blob digest, hex
@property (nonatomic, assign) int64_t currentSizeBytes;  // current_size_bytes
@property (nonatomic, copy) NSString *updatedAt;         // updated_at, ISO 8601 UTC

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary;

@end

@interface CloudContentVersion : NSObject

@property (nonatomic, assign) int64_t versionNo;         // version_no (append-only history, §13.5)
@property (nonatomic, assign) int64_t blobID;            // blob_id — the payload reference
@property (nonatomic, copy, nullable) NSString *sha256Hex;    // the blob's sha256, hex text
@property (nonatomic, assign) int64_t sizeBytes;         // size_bytes (the blob's size)
@property (nonatomic, copy, nullable) NSString *note;         // note (rollback versions record the rollback)
@property (nonatomic, copy) NSString *createdAt;         // created_at, ISO 8601 UTC

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary;

@end

@interface CloudServiceHealth : NSObject

@property (nonatomic, copy) NSString *version;           // service version (GET /v1/health)
@property (nonatomic, copy) NSString *bind;              // the listener's bind address, as served
@property (nonatomic, assign) NSInteger port;            // the listener's port, as served
@property (nonatomic, assign) NSInteger tenantCount;     // tenant_count — a figure, no identities (§8)
@property (nonatomic, assign) int64_t uptimeSeconds;     // uptime_seconds

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary;

@end

NS_ASSUME_NONNULL_END
