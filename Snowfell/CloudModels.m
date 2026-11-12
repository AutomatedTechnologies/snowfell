#import "CloudModels.h"

// Snake_case extraction helpers. Every value is type-checked before
// use: a payload field of the wrong shape degrades to the empty/zero
// value rather than raising — the lens renders what the service sent,
// and a malformed row shows as an empty row, never as a crash.
static NSString *CloudStringValue(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value stringValue];
    }
    return @"";
}

static NSString *CloudNullableStringValue(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        return value;
    }
    return nil;
}

static int64_t CloudInt64Value(NSDictionary *dictionary, NSString *key, int64_t fallback) {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value longLongValue];
    }
    if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        return [value longLongValue];
    }
    return fallback;
}

static BOOL CloudBoolValue(NSDictionary *dictionary, NSString *key) {
    id value = dictionary[key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [value isEqualToString:@"true"] || [value isEqualToString:@"1"];
    }
    return NO;
}

@implementation CloudTenant

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary {
    CloudTenant *tenant = [[CloudTenant alloc] init];
    tenant.tenantID = CloudInt64Value(dictionary, @"id", 0);
    tenant.slug = CloudStringValue(dictionary, @"slug");
    tenant.displayName = CloudStringValue(dictionary, @"display_name");
    tenant.state = CloudStringValue(dictionary, @"state");
    tenant.quotaBytes = CloudInt64Value(dictionary, @"quota_bytes", -1);
    tenant.quotaObjects = CloudInt64Value(dictionary, @"quota_objects", -1);
    tenant.quotaBuckets = CloudInt64Value(dictionary, @"quota_buckets", -1);
    tenant.usedBytes = CloudInt64Value(dictionary, @"used_bytes", 0);
    tenant.usedObjects = CloudInt64Value(dictionary, @"used_objects", 0);
    tenant.bucketCount = CloudInt64Value(dictionary, @"bucket_count", 0);
    return tenant;
}

@end

@implementation CloudLogin

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary {
    CloudLogin *login = [[CloudLogin alloc] init];
    login.loginID = CloudInt64Value(dictionary, @"id", 0);
    login.tenantID = CloudInt64Value(dictionary, @"tenant_id", 0);
    login.username = CloudStringValue(dictionary, @"username");
    login.displayName = CloudStringValue(dictionary, @"display_name");
    login.role = CloudStringValue(dictionary, @"role");
    login.state = CloudStringValue(dictionary, @"state");
    login.locked = CloudBoolValue(dictionary, @"locked");
    login.lastLoginAt = CloudNullableStringValue(dictionary, @"last_login_at");
    return login;
}

@end

@implementation CloudBucket

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary {
    CloudBucket *bucket = [[CloudBucket alloc] init];
    bucket.bucketID = CloudInt64Value(dictionary, @"id", 0);
    bucket.tenantID = CloudInt64Value(dictionary, @"tenant_id", 0);
    bucket.name = CloudStringValue(dictionary, @"name");
    bucket.backendID = CloudInt64Value(dictionary, @"backend_id", 0);
    bucket.objectCount = CloudInt64Value(dictionary, @"object_count", 0);
    bucket.totalBytes = CloudInt64Value(dictionary, @"total_bytes", 0);
    bucket.quotaBytes = CloudInt64Value(dictionary, @"quota_bytes", -1);
    return bucket;
}

@end

@implementation CloudObject

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary {
    CloudObject *object = [[CloudObject alloc] init];
    object.objectID = CloudInt64Value(dictionary, @"id", 0);
    object.key = CloudStringValue(dictionary, @"key");
    object.sizeBytes = CloudInt64Value(dictionary, @"size_bytes", 0);
    object.sha256Hex = CloudNullableStringValue(dictionary, @"sha256");
    object.contentType = CloudNullableStringValue(dictionary, @"content_type");
    return object;
}

@end

@implementation CloudAuditEntry

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary {
    CloudAuditEntry *entry = [[CloudAuditEntry alloc] init];
    entry.auditID = CloudInt64Value(dictionary, @"id", 0);
    entry.ts = CloudStringValue(dictionary, @"ts");
    entry.actorRef = CloudStringValue(dictionary, @"actor_ref");
    entry.action = CloudStringValue(dictionary, @"action");
    entry.objectRef = CloudNullableStringValue(dictionary, @"object_ref");
    entry.result = CloudStringValue(dictionary, @"result");
    return entry;
}

@end

@implementation CloudCollection

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary {
    CloudCollection *collection = [[CloudCollection alloc] init];
    collection.collectionID = CloudInt64Value(dictionary, @"id", 0);
    // parent_id is NULL at the root; NSNull is neither NSNumber nor
    // NSString to the helper, so root reads as the 0 fallback.
    collection.parentID = CloudInt64Value(dictionary, @"parent_id", 0);
    collection.name = CloudStringValue(dictionary, @"name");
    collection.slug = CloudStringValue(dictionary, @"slug");
    return collection;
}

@end

@implementation CloudContentItem

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary {
    CloudContentItem *item = [[CloudContentItem alloc] init];
    item.contentID = CloudInt64Value(dictionary, @"id", 0);
    item.slug = CloudStringValue(dictionary, @"slug");
    item.title = CloudStringValue(dictionary, @"title");
    item.kind = CloudStringValue(dictionary, @"kind");
    item.state = CloudStringValue(dictionary, @"state");
    item.collectionID = CloudInt64Value(dictionary, @"collection_id", 0);
    item.currentVersionNo = CloudInt64Value(dictionary, @"current_version_no", 0);
    item.currentSha256Hex = CloudNullableStringValue(dictionary, @"current_sha256");
    item.currentSizeBytes = CloudInt64Value(dictionary, @"current_size_bytes", 0);
    // The summary may also ride as a nested current_version object
    // (the version row's own shape); flat keys win when both appear.
    id nested = dictionary[@"current_version"];
    if ([nested isKindOfClass:[NSDictionary class]]) {
        if (item.currentVersionNo == 0) {
            item.currentVersionNo = CloudInt64Value(nested, @"version_no", 0);
        }
        if (item.currentSha256Hex == nil) {
            item.currentSha256Hex = CloudNullableStringValue(nested, @"sha256");
        }
        if (item.currentSizeBytes == 0) {
            item.currentSizeBytes = CloudInt64Value(nested, @"size_bytes", 0);
        }
    }
    item.updatedAt = CloudStringValue(dictionary, @"updated_at");
    return item;
}

@end

@implementation CloudContentVersion

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary {
    CloudContentVersion *version = [[CloudContentVersion alloc] init];
    version.versionNo = CloudInt64Value(dictionary, @"version_no", 0);
    version.blobID = CloudInt64Value(dictionary, @"blob_id", 0);
    version.sha256Hex = CloudNullableStringValue(dictionary, @"sha256");
    version.sizeBytes = CloudInt64Value(dictionary, @"size_bytes", 0);
    version.note = CloudNullableStringValue(dictionary, @"note");
    version.createdAt = CloudStringValue(dictionary, @"created_at");
    return version;
}

@end

@implementation CloudServiceHealth

+ (instancetype)fromJSONDictionary:(NSDictionary *)dictionary {
    CloudServiceHealth *health = [[CloudServiceHealth alloc] init];
    health.version = CloudStringValue(dictionary, @"version");
    health.bind = CloudStringValue(dictionary, @"bind");
    health.port = (NSInteger)CloudInt64Value(dictionary, @"port", 0);
    health.tenantCount = (NSInteger)CloudInt64Value(dictionary, @"tenant_count", 0);
    health.uptimeSeconds = CloudInt64Value(dictionary, @"uptime_seconds", 0);
    return health;
}

@end
