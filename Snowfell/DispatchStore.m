#import "DispatchStore.h"
#import "WriteBackQueue.h"
#import <sqlite3.h>

NSString * const DispatchStoreErrorDomain = @"com.detroitautomationacademy.snowfell.DispatchStore";

NSString * const DispatchStateQueued = @"queued";
NSString * const DispatchStateApproved = @"approved";
NSString * const DispatchStateSentToLane = @"sent_to_lane";
NSString * const DispatchStateDone = @"done";
NSString * const DispatchStateFailed = @"failed";
NSString * const DispatchStateCancelled = @"cancelled";

NSArray<NSString *> *DispatchAllStates(void) {
    return @[DispatchStateQueued, DispatchStateApproved, DispatchStateSentToLane,
             DispatchStateDone, DispatchStateFailed, DispatchStateCancelled];
}

@implementation LocalDispatch

- (NSString *)payloadSummary {
    // Describe the payload from the payload: up to three key=value pairs,
    // strings truncated — enough to recognise the row without reopening
    // the composer. The full payload is one tooltip away (payloadJSON).
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSArray<NSString *> *keys = [[self.payload allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *key in keys) {
        id value = self.payload[key];
        NSString *rendered = nil;
        if ([value isKindOfClass:[NSString class]]) {
            rendered = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            rendered = [value stringValue];
        } else if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
            rendered = (data != nil) ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"…";
        }
        if (rendered != nil) {
            if ([rendered length] > 40) {
                rendered = [[rendered substringToIndex:40] stringByAppendingString:@"…"];
            }
            [parts addObject:[NSString stringWithFormat:@"%@=%@", key, rendered]];
        }
        if ([parts count] >= 3) {
            break;
        }
    }
    return ([parts count] > 0) ? [parts componentsJoinedByString:@" · "] : @"(empty payload)";
}

@end

@implementation LocalAuditEntry
@end

@interface DispatchStore () {
    sqlite3 *_db;
}
@property (nonatomic, copy, readwrite) NSString *storePath;
@end

@implementation DispatchStore

+ (NSError *)errorWithCode:(DispatchStoreError)code description:(NSString *)description {
    return [NSError errorWithDomain:DispatchStoreErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

+ (NSString *)defaultStorePath {
    // One writable file for both local stores (see the header): this is
    // WriteBackQueue's path, not a second file.
    return [WriteBackQueue defaultStorePath];
}

+ (NSString *)iso8601Now {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    [formatter setFormatOptions:NSISO8601DateFormatWithInternetDateTime];
    [formatter setTimeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]];
    return [formatter stringFromDate:[NSDate date]];
}

- (instancetype)initWithStorePath:(NSString *)storePath
                            error:(NSError **)error {
    self = [super init];
    if (self) {
        _storePath = [storePath copy];
        NSString *directory = [storePath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        sqlite3 *db = NULL;
        int rc = sqlite3_open_v2([storePath fileSystemRepresentation], &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
        if (rc != SQLITE_OK) {
            NSString *message = (db != NULL) ? [NSString stringWithUTF8String:sqlite3_errmsg(db)]
                                             : @"sqlite3_open_v2 failed";
            if (db != NULL) {
                sqlite3_close(db);
            }
            if (error != NULL) {
                *error = [[self class] errorWithCode:DispatchStoreErrorOpenFailed
                                         description:[NSString stringWithFormat:
                                                      @"Dispatch store could not be opened at %@: %@", storePath, message]];
            }
            return nil;
        }
        _db = db;
        if (![self ensureSchema:error]) {
            sqlite3_close(_db);
            _db = NULL;
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    [self close];
}

- (void)close {
    if (_db != NULL) {
        sqlite3_close(_db);
        _db = NULL;
    }
}

- (BOOL)ensureSchema:(NSError **)error {
    // local_dispatches mirrors sf_dispatches semantics (design §2/§3) in
    // the app's own writable file; local_audit_log is the SHARED table —
    // the same CREATE IF NOT EXISTS WriteBackQueue issues, so whichever
    // store opens first creates it and the other reuses it.
    const char *sql =
        "CREATE TABLE IF NOT EXISTS local_dispatches ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  action_id TEXT NOT NULL,"
        "  payload_json TEXT NOT NULL,"
        "  state TEXT NOT NULL DEFAULT 'queued'"
        "    CHECK (state IN ('queued','approved','sent_to_lane','done','failed','cancelled')),"
        "  created_at TEXT NOT NULL,"
        "  updated_at TEXT NOT NULL,"
        "  result_ref TEXT,"
        "  last_error TEXT"
        ");"
        "CREATE TABLE IF NOT EXISTS local_audit_log ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  ts TEXT NOT NULL,"
        "  actor TEXT NOT NULL,"
        "  action TEXT NOT NULL,"
        "  object_ref TEXT,"
        "  before_json TEXT,"
        "  after_json TEXT"
        ");";
    char *message = NULL;
    if (sqlite3_exec(_db, sql, NULL, NULL, &message) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorSchemaFailed
                                     description:[NSString stringWithFormat:
                                                  @"Dispatch schema failed: %s",
                                                  (message != NULL) ? message : sqlite3_errmsg(_db)]];
        }
        if (message != NULL) {
            sqlite3_free(message);
        }
        return NO;
    }
    return YES;
}

#pragma mark - Helpers

static NSString *DSColumnText(sqlite3_stmt *statement, int column) {
    const unsigned char *text = sqlite3_column_text(statement, column);
    return (text != NULL) ? [NSString stringWithUTF8String:(const char *)text] : @"";
}

static NSString *DSColumnNullableText(sqlite3_stmt *statement, int column) {
    if (sqlite3_column_type(statement, column) == SQLITE_NULL) {
        return nil;
    }
    const unsigned char *text = sqlite3_column_text(statement, column);
    return (text != NULL) ? [NSString stringWithUTF8String:(const char *)text] : nil;
}

- (BOOL)executeUpdate:(const char *)sql
            bindBlock:(void (^)(sqlite3_stmt *statement))bindBlock
                error:(NSError **)error {
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorTransitionFailed
                                     description:[NSString stringWithFormat:
                                                  @"Statement failed: %s", sqlite3_errmsg(_db)]];
        }
        return NO;
    }
    if (bindBlock != nil) {
        bindBlock(statement);
    }
    BOOL ok = (sqlite3_step(statement) == SQLITE_DONE);
    if (!ok && error != NULL) {
        *error = [[self class] errorWithCode:DispatchStoreErrorTransitionFailed
                                 description:[NSString stringWithFormat:
                                              @"Update failed: %s", sqlite3_errmsg(_db)]];
    }
    sqlite3_finalize(statement);
    return ok;
}

- (nullable NSString *)jsonStringForObject:(id)object {
    if (object == nil) {
        return nil;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (data == nil) {
        return nil;
    }
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (BOOL)recordAuditAction:(NSString *)action
               objectRef:(NSString *)objectRef
                  before:(NSDictionary *)before
                   after:(NSDictionary *)after
                   error:(NSError **)error {
    NSString *beforeJSON = [self jsonStringForObject:before];
    NSString *afterJSON = [self jsonStringForObject:after];
    NSString *timestamp = [[self class] iso8601Now];
    return [self executeUpdate:"INSERT INTO local_audit_log (ts, actor, action, object_ref, before_json, after_json) VALUES (?, 'Snowfell (local user)', ?, ?, ?, ?)"
                     bindBlock:^(sqlite3_stmt *statement) {
                         sqlite3_bind_text(statement, 1, [timestamp UTF8String], -1, SQLITE_TRANSIENT);
                         sqlite3_bind_text(statement, 2, [action UTF8String], -1, SQLITE_TRANSIENT);
                         if (objectRef != nil) {
                             sqlite3_bind_text(statement, 3, [objectRef UTF8String], -1, SQLITE_TRANSIENT);
                         } else {
                             sqlite3_bind_null(statement, 3);
                         }
                         if (beforeJSON != nil) {
                             sqlite3_bind_text(statement, 4, [beforeJSON UTF8String], -1, SQLITE_TRANSIENT);
                         } else {
                             sqlite3_bind_null(statement, 4);
                         }
                         if (afterJSON != nil) {
                             sqlite3_bind_text(statement, 5, [afterJSON UTF8String], -1, SQLITE_TRANSIENT);
                         } else {
                             sqlite3_bind_null(statement, 5);
                         }
                     }
                         error:error];
}

#pragma mark - Enqueue

- (int64_t)enqueueDispatchWithActionID:(NSString *)actionID
                               payload:(NSDictionary *)payload
                                 error:(NSError **)error {
    NSString *payloadJSON = [self jsonStringForObject:payload];
    if (payloadJSON == nil) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorEnqueueFailed
                                     description:@"Payload could not be serialized to JSON; nothing was queued."];
        }
        return -1;
    }
    NSString *now = [[self class] iso8601Now];
    const char *sql =
        "INSERT INTO local_dispatches (action_id, payload_json, state, created_at, updated_at, result_ref, last_error) "
        "VALUES (?, ?, 'queued', ?, ?, NULL, NULL)";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorEnqueueFailed
                                     description:[NSString stringWithFormat:
                                                  @"Enqueue prepare failed: %s", sqlite3_errmsg(_db)]];
        }
        return -1;
    }
    sqlite3_bind_text(statement, 1, [actionID UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 2, [payloadJSON UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 3, [now UTF8String], -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(statement, 4, [now UTF8String], -1, SQLITE_TRANSIENT);
    BOOL ok = (sqlite3_step(statement) == SQLITE_DONE);
    sqlite3_finalize(statement);
    if (!ok) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorEnqueueFailed
                                     description:[NSString stringWithFormat:
                                                  @"Enqueue failed: %s", sqlite3_errmsg(_db)]];
        }
        return -1;
    }
    int64_t dispatchID = sqlite3_last_insert_rowid(_db);
    // Design §3: every dispatch is audited — the enqueue itself included.
    [self recordAuditAction:@"dispatch.enqueue"
                 objectRef:[NSString stringWithFormat:@"local_dispatches:%lld", dispatchID]
                    before:nil
                     after:@{@"action_id": actionID,
                             @"payload": payload,
                             @"state": DispatchStateQueued}
                     error:NULL];
    return dispatchID;
}

- (int64_t)enqueueDispatchWithActionID:(NSString *)actionID
                           incidentKey:(NSString *)incidentKey
                          extraPayload:(NSDictionary *)extraPayload
                                 error:(NSError **)error {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    [payload setObject:incidentKey forKey:@"incident_key"];
    if (extraPayload != nil) {
        [payload addEntriesFromDictionary:extraPayload];
    }
    return [self enqueueDispatchWithActionID:actionID payload:payload error:error];
}

#pragma mark - Listing

- (NSArray<LocalDispatch *> *)dispatchesWhere:(NSString *)whereClause
                                        error:(NSError **)error {
    NSString *sql = [NSString stringWithFormat:
                     @"SELECT id, action_id, payload_json, state, created_at, updated_at, result_ref, last_error "
                     @"FROM local_dispatches %@ ORDER BY id ASC", whereClause];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorQueryFailed
                                     description:[NSString stringWithFormat:
                                                  @"Dispatch query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<LocalDispatch *> *rows = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        LocalDispatch *dispatch = [[LocalDispatch alloc] init];
        dispatch.dispatchID = sqlite3_column_int64(statement, 0);
        dispatch.actionID = DSColumnText(statement, 1);
        dispatch.payloadJSON = DSColumnText(statement, 2);
        dispatch.state = DSColumnText(statement, 3);
        dispatch.createdAt = DSColumnText(statement, 4);
        dispatch.updatedAt = DSColumnText(statement, 5);
        dispatch.resultRef = DSColumnNullableText(statement, 6);
        dispatch.lastError = DSColumnNullableText(statement, 7);
        id parsed = [NSJSONSerialization JSONObjectWithData:[dispatch.payloadJSON dataUsingEncoding:NSUTF8StringEncoding]
                                                    options:0
                                                      error:NULL];
        dispatch.payload = [parsed isKindOfClass:[NSDictionary class]] ? parsed : @{};
        [rows addObject:dispatch];
    }
    sqlite3_finalize(statement);
    return rows;
}

- (NSArray<LocalDispatch *> *)allDispatchesWithError:(NSError **)error {
    return [self dispatchesWhere:@"" error:error];
}

- (NSArray<LocalDispatch *> *)dispatchesWithState:(NSString *)state
                                            error:(NSError **)error {
    // The state value is validated against the six-state set before it is
    // ever interpolated — callers pass one of the DispatchState* values.
    if (![DispatchAllStates() containsObject:state]) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorInvalidTransition
                                     description:[NSString stringWithFormat:@"Unknown dispatch state: %@", state]];
        }
        return nil;
    }
    return [self dispatchesWhere:[NSString stringWithFormat:@"WHERE state = '%@'", state] error:error];
}

- (NSInteger)queuedCount {
    sqlite3_stmt *statement = NULL;
    NSInteger count = 0;
    if (sqlite3_prepare_v2(_db, "SELECT COUNT(*) FROM local_dispatches WHERE state = 'queued'",
                           -1, &statement, NULL) == SQLITE_OK) {
        if (sqlite3_step(statement) == SQLITE_ROW) {
            count = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return count;
}

#pragma mark - State transitions

- (nullable LocalDispatch *)dispatchWithID:(int64_t)dispatchID {
    NSArray<LocalDispatch *> *rows = [self dispatchesWhere:
                                      [NSString stringWithFormat:@"WHERE id = %lld", dispatchID]
                                                     error:NULL];
    return ([rows count] > 0) ? rows[0] : nil;
}

- (BOOL)transitionDispatch:(int64_t)dispatchID
                   toState:(NSString *)state
                 resultRef:(NSString *)resultRef
                     error:(NSError **)error {
    if (![DispatchAllStates() containsObject:state]) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorInvalidTransition
                                     description:[NSString stringWithFormat:@"Unknown dispatch state: %@", state]];
        }
        return NO;
    }
    LocalDispatch *before = [self dispatchWithID:dispatchID];
    if (before == nil) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorInvalidTransition
                                     description:[NSString stringWithFormat:@"No local dispatch with id %lld.", dispatchID]];
        }
        return NO;
    }
    NSString *now = [[self class] iso8601Now];
    BOOL ok = [self executeUpdate:"UPDATE local_dispatches SET state = ?, updated_at = ?, result_ref = COALESCE(?, result_ref) WHERE id = ?"
                        bindBlock:^(sqlite3_stmt *statement) {
                            sqlite3_bind_text(statement, 1, [state UTF8String], -1, SQLITE_TRANSIENT);
                            sqlite3_bind_text(statement, 2, [now UTF8String], -1, SQLITE_TRANSIENT);
                            if (resultRef != nil) {
                                sqlite3_bind_text(statement, 3, [resultRef UTF8String], -1, SQLITE_TRANSIENT);
                            } else {
                                sqlite3_bind_null(statement, 3);
                            }
                            sqlite3_bind_int64(statement, 4, dispatchID);
                        }
                            error:error];
    if (!ok) {
        return NO;
    }
    [self recordAuditAction:@"dispatch.transition"
                 objectRef:[NSString stringWithFormat:@"local_dispatches:%lld", dispatchID]
                    before:@{@"state": before.state}
                     after:@{@"state": state,
                             @"result_ref": (resultRef != nil) ? resultRef : [NSNull null]}
                     error:NULL];
    return YES;
}

- (BOOL)cancelDispatch:(int64_t)dispatchID error:(NSError **)error {
    LocalDispatch *before = [self dispatchWithID:dispatchID];
    if (before == nil) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorInvalidTransition
                                     description:[NSString stringWithFormat:@"No local dispatch with id %lld.", dispatchID]];
        }
        return NO;
    }
    if (![before.state isEqualToString:DispatchStateQueued]) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorInvalidTransition
                                     description:[NSString stringWithFormat:
                                                  @"Dispatch %lld is %@ — only a queued dispatch can be cancelled; a row past queued may already be held by the estate consumer.",
                                                  dispatchID, before.state]];
        }
        return NO;
    }
    NSString *now = [[self class] iso8601Now];
    BOOL ok = [self executeUpdate:"UPDATE local_dispatches SET state = 'cancelled', updated_at = ? WHERE id = ? AND state = 'queued'"
                        bindBlock:^(sqlite3_stmt *statement) {
                            sqlite3_bind_text(statement, 1, [now UTF8String], -1, SQLITE_TRANSIENT);
                            sqlite3_bind_int64(statement, 2, dispatchID);
                        }
                            error:error];
    if (!ok) {
        return NO;
    }
    [self recordAuditAction:@"dispatch.cancel"
                 objectRef:[NSString stringWithFormat:@"local_dispatches:%lld", dispatchID]
                    before:@{@"state": DispatchStateQueued}
                     after:@{@"state": DispatchStateCancelled}
                     error:NULL];
    return YES;
}

#pragma mark - Audit listing

- (NSArray<LocalAuditEntry *> *)dispatchAuditEntriesWithError:(NSError **)error {
    const char *sql =
        "SELECT id, ts, actor, action, object_ref, before_json, after_json "
        "FROM local_audit_log WHERE action LIKE 'dispatch.%' ORDER BY id ASC";
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &statement, NULL) != SQLITE_OK) {
        if (error != NULL) {
            *error = [[self class] errorWithCode:DispatchStoreErrorQueryFailed
                                     description:[NSString stringWithFormat:
                                                  @"Audit query failed: %s", sqlite3_errmsg(_db)]];
        }
        return nil;
    }
    NSMutableArray<LocalAuditEntry *> *entries = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        LocalAuditEntry *entry = [[LocalAuditEntry alloc] init];
        entry.auditID = sqlite3_column_int64(statement, 0);
        entry.ts = DSColumnText(statement, 1);
        entry.actor = DSColumnText(statement, 2);
        entry.action = DSColumnText(statement, 3);
        entry.objectRef = DSColumnNullableText(statement, 4);
        entry.beforeJSON = DSColumnNullableText(statement, 5);
        entry.afterJSON = DSColumnNullableText(statement, 6);
        [entries addObject:entry];
    }
    sqlite3_finalize(statement);
    return entries;
}

@end
